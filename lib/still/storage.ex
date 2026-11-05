defmodule Still.Storage do
  @moduledoc "Local folder settings and verified SQLite backups for the active writing database."

  alias Still.Repo
  alias Still.Writing.{CollectionLock, Files}
  @state_key "still_storage_v1"

  def status, do: with_state(&status_for/1)

  @doc "The explicitly chosen local root for writing files; the live database remains local."
  def collection_location do
    with_state(fn state ->
      db = Path.expand(Repo.config()[:database])
      folder_result = if state.folder, do: validate_folder(state.folder), else: :ok

      folder_result =
        if (folder_result == :ok and state.folder) && inside?(db, state.folder),
          do: {:error, "Choose a writing folder outside Still's live database location."},
          else: folder_result

      folder_error =
        case folder_result do
          {:error, message} -> message
          :ok -> nil
        end

      %{
        configured: state.folder != nil,
        available: state.folder != nil and folder_result == :ok and not state.corrupt?,
        folder: state.folder,
        scope:
          if(state.folder,
            do: Still.Writing.Files.collection_scope(state.folder),
            else: local_scope({db, nil})
          ),
        draft_scope: local_scope({db, :local_poem_draft}),
        error: state.error || folder_error
      }
    end)
  end

  defp local_scope(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.encode16(case: :lower)
  end

  def set_folder(path) when is_binary(path) do
    with_state(fn state ->
      case validate_folder(path) do
        :ok ->
          expanded = resolve_path(path)
          db = Path.expand(Repo.config()[:database])

          if inside?(db, expanded) do
            {:error, "Choose a writing folder outside Still's live database location."}
          else
            next =
              if state.folder == expanded do
                %{state | error: nil, corrupt?: false}
              else
                %{
                  state
                  | folder: expanded,
                    last_backup: nil,
                    fingerprint: nil,
                    error: nil,
                    corrupt?: false
                }
              end

            case safe_persist(next) do
              :ok -> {:ok, status_for(next)}
              {:error, reason} -> {:error, "Could not save backup settings: #{reason}"}
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def set_folder(_), do: {:error, "Choose an existing folder using an absolute path."}

  def clear_folder do
    with_state(fn state ->
      next = %{
        state
        | folder: nil,
          last_backup: nil,
          fingerprint: nil,
          error: nil,
          corrupt?: false
      }

      case safe_persist(next) do
        :ok -> {:ok, status_for(next)}
        {:error, reason} -> {:error, "Could not save backup settings: #{reason}"}
      end
    end)
  end

  def backup do
    with_state(fn state ->
      cond do
        state.corrupt? -> {:error, state.error}
        is_nil(state.folder) -> {:error, "Choose a backup folder first."}
        true -> do_backup(state, state.folder)
      end
    end)
  end

  @doc "Refresh the verified backup when a settled collection has changed."
  def backup_if_needed do
    # File operations acquire this lock before reading storage settings.
    CollectionLock.with_lock(Repo.config()[:database], fn ->
      with_state(fn state ->
        with %{folder: folder, corrupt?: false} when is_binary(folder) <- state,
             :ok <- validate_folder(folder),
             false <- inside?(Path.expand(Repo.config()[:database]), folder),
             false <- Files.pending_save?(Files.collection_scope(folder)) do
          case verify_proof(state) do
            {false, _} -> :unchanged
            {true, _} -> do_backup(state, folder)
          end
        else
          _ -> :skipped
        end
      end)
    end)
  end

  @doc "Verifies a chosen backup and publishes it to a new local SQLite path without replacing the active database."
  def restore_backup(backup_path, destination_path, writing_folder) do
    if inside?(destination_path, writing_folder),
      do: {:error, "Choose a local restore destination outside the writing folder."},
      else: restore_backup(backup_path, destination_path)
  end

  def restore_backup(backup_path, destination_path)
      when is_binary(backup_path) and is_binary(destination_path) do
    with_state(fn state ->
      backup_path = Path.expand(backup_path)
      destination = Path.expand(destination_path)

      active_db =
        if Process.whereis(Repo),
          do: Path.expand(Repo.config()[:database]),
          else: nil

      cond do
        Path.type(destination_path) != :absolute ->
          {:error, "Choose an absolute local destination path."}

        destination == active_db ->
          {:error,
           "Restore to a separate local SQLite file; the active database will not be replaced."}

        state.folder && inside?(destination, state.folder) ->
          {:error, "Choose a restore destination outside the writing folder."}

        symlink?(backup_path) or not File.regular?(backup_path) ->
          {:error, "The selected backup is unavailable."}

        File.exists?(destination) or symlink?(destination) ->
          {:error, "The restore destination already exists; choose a new path."}

        true ->
          publish_restore(backup_path, destination)
      end
    end)
  end

  def restore_backup(_, _),
    do: {:error, "Choose a backup file and an absolute local destination path."}

  defp publish_restore(source, destination) do
    try do
      unless still_schema?(source), do: raise("The selected file is not a Still database backup.")
      :ok = check_snapshot(source)
      proof = logical_fingerprint(source)
      directory = Path.dirname(destination)
      unless File.dir?(directory), do: raise("The restore destination folder must already exist.")

      temp =
        Path.join(
          directory,
          ".still-restore-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}.partial"
        )

      :ok = copy_exclusive!(source, temp)

      try do
        :ok = File.chmod(temp, 0o600)
        :ok = check_snapshot(temp)
        ^proof = logical_fingerprint(temp)
        :ok = sync_file(temp)
        publish_new_file!(temp, destination, "restore destination")
        sync_directory(directory)
        {:ok, destination}
      after
        File.rm(temp)
      end
    rescue
      error -> {:error, "Could not restore the verified backup: #{Exception.message(error)}"}
    end
  end

  defp inside?(path, root) do
    path = resolve_path(path)
    root = resolve_path(root)
    path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/")
  end

  defp resolve_path(path) do
    resolve_components(
      Path.split(Path.expand(path)) |> Enum.reject(&(&1 == "/")),
      "/",
      MapSet.new(),
      0
    )
  end

  defp resolve_components([], current, _seen, _depth), do: Path.expand(current)

  defp resolve_components([component | rest], current, seen, depth) when depth < 64 do
    candidate = Path.join(current, component)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        if MapSet.member?(seen, candidate) do
          Path.expand(Path.join(candidate, Path.join(rest)))
        else
          case File.read_link(candidate) do
            {:ok, target} ->
              target =
                if Path.type(target) == :absolute,
                  do: target,
                  else: Path.join(current, target)

              remaining = Path.split(Path.expand(target)) |> Enum.reject(&(&1 == "/"))
              resolve_components(remaining ++ rest, "/", MapSet.put(seen, candidate), depth + 1)

            _ ->
              resolve_components(rest, candidate, seen, depth)
          end
        end

      _ ->
        resolve_components(rest, candidate, seen, depth)
    end
  end

  defp resolve_components(rest, current, _seen, _depth),
    do: Path.expand(Path.join(current, Path.join(rest)))

  defp symlink?(path), do: match?({:ok, %{type: :symlink}}, File.lstat(path))

  defp sync_file(path) do
    {:ok, handle} = File.open(path, [:read, :write, :binary])

    try do
      :file.sync(handle)
    after
      File.close(handle)
    end
  end

  defp copy_exclusive!(source, destination) do
    {:ok, input} = File.open(source, [:read, :binary])

    try do
      case File.open(destination, [:write, :exclusive, :binary]) do
        {:ok, output} ->
          copy_to_created_file!(input, output, destination)

        {:error, :eexist} ->
          raise "The restore staging file appeared during preparation; it was left untouched."

        {:error, reason} ->
          raise "Could not create restore staging file: #{:file.format_error(reason)}"
      end
    after
      File.close(input)
    end
  end

  defp copy_to_created_file!(input, output, destination) do
    try do
      try do
        :ok = copy_stream(input, output)
        :file.sync(output)
      after
        File.close(output)
      end
    rescue
      error ->
        File.rm(destination)
        reraise error, __STACKTRACE__
    end
  end

  defp copy_stream(input, output) do
    case IO.binread(input, 65_536) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}

      chunk ->
        :ok = IO.binwrite(output, chunk)
        copy_stream(input, output)
    end
  end

  def open_folder do
    with_state(fn state ->
      cond do
        state.corrupt? ->
          {:error, state.error}

        is_nil(state.folder) ->
          {:error, "Choose a backup folder first."}

        true ->
          folder = state.folder

          case validate_folder(folder) do
            :ok -> launch_folder(folder)
            {:error, reason} -> {:error, reason}
          end
      end
    end)
  end

  defp launch_folder(folder) do
    opener =
      case :os.type() do
        {:unix, :darwin} -> "/usr/bin/open"
        {:unix, _} -> System.find_executable("xdg-open")
        _ -> nil
      end

    if opener do
      try do
        case System.cmd(opener, [folder], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, String.trim(output) |> empty_error(folder)}
        end
      rescue
        error -> {:error, "Could not open the folder here: #{Exception.message(error)}"}
      end
    else
      {:error, "Open #{folder} on the computer running Still."}
    end
  end

  defp empty_error("", folder), do: "Open #{folder} on the computer running Still."
  defp empty_error(message, _folder), do: "Could not open the folder here: #{message}"

  defp do_backup(state, folder) do
    db = Path.expand(Repo.config()[:database])

    case {validate_folder(folder), inside?(db, folder)} do
      {:ok, true} ->
        {:error, "Choose a writing folder outside Still's live database location."}

      {:ok, false} ->
        final = Path.join(folder, "still-backup.sqlite3")
        token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        snapshot = Path.join(folder, ".still-backup-#{token}.partial")
        collection_id = Still.Writing.Files.collection_scope(folder)

        cond do
          symlink?(final) ->
            {:error,
             "The existing backup path is a symbolic link; move it aside before backing up."}

          File.exists?(final) and not File.regular?(final) ->
            {:error,
             "The existing backup path is not an ordinary file; move it aside before backing up."}

          File.exists?(final) and not recognized_backup?(final, collection_id) ->
            {:error,
             "The existing backup belongs to another collection or is not a Still backup. Restore that collection backup before replacing it, or move the file aside."}

          true ->
            try do
              {:ok, db} =
                Exqlite.start_link(
                  database: Repo.config()[:database],
                  mode: :readwrite,
                  busy_timeout: 5_000
                )

              try do
                Exqlite.query!(db, "VACUUM INTO ?", [snapshot])
              after
                GenServer.stop(db)
              end

              :ok = File.chmod(snapshot, 0o600)
              :ok = sync_file(snapshot)
              :ok = check_snapshot(snapshot)
              fingerprint = logical_fingerprint(snapshot)
              :ok = replace_backup(snapshot, final, collection_id)
              sync_directory(folder)
              timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

              next = %{
                state
                | last_backup: %{path: final, at: timestamp},
                  fingerprint: fingerprint,
                  error: nil
              }

              case safe_persist(next) do
                :ok ->
                  {:ok, status_for(next)}

                {:error, reason} ->
                  {:error,
                   "Backup completed, but its success record could not be saved: #{reason}"}
              end
            rescue
              error ->
                File.rm(snapshot)
                {:error, Exception.message(error)}
            catch
              kind, reason ->
                File.rm(snapshot)
                {:error, "Backup failed: #{inspect({kind, reason})}"}
            end
        end

      {{:error, reason}, _} ->
        {:error, reason}
    end
  end

  defp replace_backup(staging, final, collection_id) do
    if File.exists?(final) do
      # Recheck lineage immediately before the atomic replacement.
      unless not symlink?(final) and File.regular?(final) and
               recognized_backup?(final, collection_id) do
        raise "The existing backup changed or belongs to another collection; it was left untouched."
      end

      File.rename!(staging, final)
    else
      publish_new_file!(staging, final, "backup file")
    end
  end

  defp recognized_backup?(path, collection_id) do
    with {:ok, <<"SQLite format 3", 0, _::binary>>} <- read_header(path),
         :ok <- check_snapshot(path),
         true <- still_schema?(path),
         true <- contains_collection?(path, collection_id) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp still_schema?(path) do
    {:ok, db} = Exqlite.start_link(database: path, mode: :readonly)

    try do
      tables =
        sqlite_rows(db, "SELECT name FROM sqlite_master WHERE type = 'table'")
        |> List.flatten()
        |> MapSet.new()

      required_columns = %{
        "entries" => ~w(id body lock_version origin source),
        "versions" => ~w(id entry_id body),
        "room_states" => ~w(id recent light letters),
        "collection_folders" => ~w(id root),
        "notebooks" => ~w(id key label),
        "schema_migrations" => []
      }

      Enum.all?(required_columns, fn {table, required} ->
        if MapSet.member?(tables, table) do
          columns =
            sqlite_rows(db, "PRAGMA table_info(#{quote_identifier(table)})")
            |> Enum.map(fn [_index, name | _rest] -> name end)
            |> MapSet.new()

          Enum.all?(required, &MapSet.member?(columns, &1))
        else
          false
        end
      end)
    after
      GenServer.stop(db)
    end
  end

  defp contains_collection?(path, collection_id) do
    {:ok, db} = Exqlite.start_link(database: path, mode: :readonly)

    try do
      sqlite_rows(db, "SELECT id FROM collection_folders WHERE id = ?", [collection_id]) == [
        [collection_id]
      ]
    after
      GenServer.stop(db)
    end
  end

  defp publish_new_file!(staging, final, label) do
    case File.ln(staging, final) do
      :ok ->
        File.rm!(staging)
        :ok

      {:error, :eexist} ->
        raise "The #{label} appeared during publication; it was left untouched."

      {:error, reason} ->
        raise "Could not publish #{label}: #{:file.format_error(reason)}"
    end
  end

  defp read_header(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, IO.binread(file, 16)}
        after
          File.close(file)
        end

      error ->
        error
    end
  end

  defp status_for(state) do
    folder_result = if state.folder, do: validate_folder(state.folder), else: :ok
    available = state.folder != nil and folder_result == :ok
    {changed, proof_error} = verify_proof(state)

    folder_error =
      case folder_result do
        {:error, reason} -> reason
        :ok -> nil
      end

    %{
      configured: state.folder != nil,
      folder: state.folder,
      available: available,
      last_backup: state.last_backup,
      changed: changed or state.corrupt?,
      error: state.error || folder_error || proof_error
    }
  end

  defp validate_folder(path) do
    cond do
      Path.type(path) != :absolute ->
        {:error, "The backup folder path must be absolute."}

      not File.dir?(path) ->
        {:error,
         "The backup folder is unavailable. Reconnect its drive or choose an existing folder."}

      true ->
        case File.stat(path) do
          {:ok, %{type: :directory, access: :read_write}} ->
            :ok

          {:ok, %{type: :directory}} ->
            {:error,
             "The backup folder is not writable. Check its permissions or choose another folder."}

          _ ->
            {:error, "The backup folder is unavailable."}
        end
    end
  end

  defp logical_fingerprint(path) do
    {:ok, db} = Exqlite.start_link(database: path, mode: :readonly, busy_timeout: 5_000)

    try do
      Exqlite.query!(db, "BEGIN")

      schema =
        sqlite_rows(
          db,
          "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
        )

      tables = for ["table", name, _table, _sql] <- schema, do: name

      rows =
        Enum.map(tables, fn table ->
          {table, sqlite_rows(db, "SELECT * FROM #{quote_identifier(table)} ORDER BY rowid")}
        end)

      Exqlite.query!(db, "COMMIT")

      :crypto.hash(:sha256, :erlang.term_to_binary({schema, rows}, [:deterministic]))
      |> Base.encode16(case: :lower)
    after
      GenServer.stop(db)
    end
  end

  defp verify_proof(%{last_backup: nil}), do: {true, nil}

  defp verify_proof(%{fingerprint: nil}),
    do: {true, "Backup proof is unavailable; make a new backup."}

  defp verify_proof(%{last_backup: backup, fingerprint: expected}) do
    try do
      if not File.regular?(backup.path) do
        {true, "The last backup file is missing; make a new backup."}
      else
        :ok = check_snapshot(backup.path)
        actual_backup = logical_fingerprint(backup.path)
        current = logical_fingerprint(Repo.config()[:database])
        changed = actual_backup != expected or current != expected

        {changed,
         if(actual_backup != expected,
           do: "The last backup no longer matches its saved proof.",
           else: nil
         )}
      end
    rescue
      error -> {true, "Could not verify the last backup: #{Exception.message(error)}"}
    end
  end

  defp check_snapshot(path) do
    {:ok, db} = Exqlite.start_link(database: path, mode: :readonly)

    try do
      case sqlite_rows(db, "PRAGMA integrity_check") do
        [["ok"]] -> :ok
        result -> raise "Backup integrity check failed: #{inspect(result)}"
      end
    after
      GenServer.stop(db)
    end
  end

  defp sqlite_rows(db, sql), do: Exqlite.query!(db, sql).rows
  defp sqlite_rows(db, sql, params), do: Exqlite.query!(db, sql, params).rows

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, handle} ->
        try do
          case :file.sync(handle) do
            :ok ->
              :ok

            {:error, reason} when reason in [:eisdir, :einval, :eopnotsupp] ->
              :ok

            {:error, reason} ->
              raise "Could not sync backup folder: #{:file.format_error(reason)}"
          end
        after
          :file.close(handle)
        end

      {:error, reason} when reason in [:eisdir, :einval, :eopnotsupp] ->
        :ok

      {:error, reason} ->
        raise "Could not open backup folder for syncing: #{:file.format_error(reason)}"
    end
  end

  defp quote_identifier(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""

  defp with_state(fun) do
    path = state_path()
    :global.trans({{__MODULE__, path}, self()}, fn -> fun.(load_state(path)) end)
  end

  defp load_state(path) do
    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, %{"still_storage_v1" => state}} when is_map(state) ->
            if valid_state?(state),
              do: normalize(state),
              else:
                corrupt_state(
                  "Backup settings are invalid. Choose or clear the folder to repair them."
                )

          _ ->
            corrupt_state(
              "Backup settings could not be read. Choose or clear the folder to repair them."
            )
        end

      {:error, :enoent} ->
        empty_state()

      {:error, reason} ->
        corrupt_state("Backup settings could not be read: #{:file.format_error(reason)}")
    end
  end

  defp valid_state?(state) do
    folder = state["folder"]
    backup = state["last_backup"]
    fingerprint = state["fingerprint"]
    error = state["error"]
    valid_folder = is_nil(folder) or (is_binary(folder) and Path.type(folder) == :absolute)

    valid_proof =
      (is_nil(backup) and is_nil(fingerprint)) or
        (is_map(backup) and is_binary(backup["path"]) and Path.type(backup["path"]) == :absolute and
           is_binary(backup["at"]) and is_binary(fingerprint) and
           String.match?(fingerprint, ~r/\A[0-9a-f]{64}\z/))

    valid_folder and valid_proof and (is_nil(error) or is_binary(error))
  end

  defp normalize(state),
    do: %{
      folder: state["folder"],
      last_backup: normalize_backup(state["last_backup"]),
      fingerprint: state["fingerprint"],
      error: state["error"],
      corrupt?: false
    }

  defp normalize_backup(nil), do: nil
  defp normalize_backup(backup), do: %{path: backup["path"], at: backup["at"]}

  defp empty_state,
    do: %{folder: nil, last_backup: nil, fingerprint: nil, error: nil, corrupt?: false}

  defp corrupt_state(reason),
    do: %{folder: nil, last_backup: nil, fingerprint: nil, error: reason, corrupt?: true}

  defp safe_persist(state) do
    try do
      persist(state)
      :ok
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp persist(state) do
    path = state_path()
    directory = Path.dirname(path)
    File.mkdir_p!(directory)
    temp = path <> ".partial-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"

    data = %{
      folder: state.folder,
      last_backup: state.last_backup,
      fingerprint: state.fingerprint,
      error: state.error
    }

    payload = Jason.encode!(%{@state_key => data})

    try do
      {:ok, file} = File.open(temp, [:write, :exclusive, :binary])

      try do
        :ok = IO.binwrite(file, payload)
        :ok = :file.sync(file)
      after
        File.close(file)
      end

      File.chmod!(temp, 0o600)
      File.rename!(temp, path)
      sync_directory(directory)
    after
      File.rm(temp)
    end
  end

  defp state_path do
    configured =
      Application.get_env(:still, :storage_state_directory) ||
        System.get_env("STILL_LOCAL_STATE_DIRECTORY")

    base = configured || Path.join(System.user_home!(), ".config/still")

    db =
      Repo.config()[:database]
      |> Path.expand()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join(base, "storage-#{db}.json")
  end
end

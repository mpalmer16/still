defmodule Still.Storage do
  @moduledoc "Local folder settings and verified SQLite backups for the active writing database."

  alias Still.Repo
  @state_key "still_storage_v1"

  def status, do: with_state(&status_for/1)

  def set_folder(path) when is_binary(path) do
    with_state(fn state ->
      case validate_folder(path) do
        :ok ->
          expanded = Path.expand(path)

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
    case validate_folder(folder) do
      :ok ->
        token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        stem = "still-backup-#{DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")}-#{token}"
        staging = Path.join(folder, ".#{stem}.partial")
        final_dir = Path.join(folder, stem)
        snapshot = Path.join(staging, "still.db")
        final = Path.join(final_dir, "still.db")

        case File.mkdir(staging) do
          :ok ->
            try do
              :ok = File.chmod(staging, 0o700)

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
              {:ok, handle} = File.open(snapshot, [:read, :write, :binary])
              :ok = :file.sync(handle)
              :ok = File.close(handle)
              :ok = check_snapshot(snapshot)
              fingerprint = logical_fingerprint(snapshot)
              sync_directory(staging)
              :ok = File.rename(staging, final_dir)
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
                File.rm_rf(staging)
                {:error, Exception.message(error)}
            catch
              kind, reason ->
                File.rm_rf(staging)
                {:error, "Backup failed: #{inspect({kind, reason})}"}
            end

          {:error, reason} ->
            {:error,
             "Could not create a backup in the selected folder: #{:file.format_error(reason)}. Check available space and folder permissions."}
        end

      {:error, reason} ->
        {:error, reason}
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

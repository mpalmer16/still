defmodule Still.Poems do
  @moduledoc """
  File-backed poems in the currently selected Still collection.

  A collection lock left by a crashed process is never removed automatically. Close all Still
  instances before manually removing `.still-poems-lock` from the selected collection folder.
  """

  @marker ".still-poems.json"
  @marker_contents Jason.encode!(%{"format" => "still-poems-v1"}, pretty: true) <> "\n"
  @metadata "metadata.json"
  @journal ".save-journal.json"

  def new(location),
    do: %{
      id: Ecto.UUID.generate(),
      title: nil,
      body: "",
      token: nil,
      created_at: nil,
      updated_at: nil,
      path: nil,
      scope: if(is_map(location), do: location[:scope] || location["scope"], else: nil)
    }

  def list(location) do
    with_location(location, fn root, scope ->
      case poems_root(root, false) do
        :missing ->
          {:ok, []}

        {:ok, poems} ->
          with {:ok, ids} <- File.ls(poems),
               {:ok, entries} <- read_entries(poems, ids) do
            {:ok,
             Enum.map(entries, &Map.put(&1, :scope, scope))
             |> Enum.sort_by(&{&1.updated_at || "", &1.id}, :desc)}
          else
            {:error, reason} -> {:error, explain(reason)}
          end

        error ->
          normalize_error(error)
      end
    end)
  end

  def get(location, id) do
    with_location(location, fn root, scope ->
      case read_poem(root, id) do
        {:ok, poem} -> {:ok, Map.put(poem, :scope, scope)}
        error -> error
      end
    end)
  end

  def revisions(location, id) do
    with_location(location, fn root, _scope ->
      with {:ok, poem} <- read_poem(root, id),
           {:ok, dir} <- poem_dir(root, id),
           :ok <- safe_dir(Path.join(dir, "revisions")),
           {:ok, names} <- File.ls(Path.join(dir, "revisions")) do
        names
        |> Enum.filter(&valid_revision_name?/1)
        |> Enum.sort(:desc)
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          case read_revision(Path.join([dir, "revisions", name]), poem.id) do
            {:ok, rev} -> {:cont, {:ok, [rev | acc]}}
            error -> {:halt, error}
          end
        end)
      else
        {:error, reason} when reason == :enoent -> {:ok, []}
        error -> normalize_error(error)
      end
    end)
  end

  def save(location, existing, attrs) when is_map(existing) and is_map(attrs) do
    with {:ok, body} <- valid_text(Map.get(attrs, :body)),
         {:ok, title} <- valid_title(Map.get(attrs, :title)) do
      with_location(location, fn root, scope ->
        id = Map.get(existing, :id)

        if is_binary(id) do
          do_save(root, scope, existing, id, body, title)
        else
          {:error, "This poem has no valid identifier."}
        end
      end)
    end
  end

  def save(_, _, _), do: {:error, "The poem could not be saved because its data is invalid."}

  defp do_save(root, scope, existing, id, body, title) do
    if is_binary(existing[:scope]) and existing.scope != scope do
      {:error, "The active collection changed. Reopen the poem before continuing."}
    else
      if is_nil(existing[:token]) do
        case create_poem(root, id, body, title) do
          {:ok, poem} -> {:ok, Map.put(poem, :scope, scope)}
          error -> error
        end
      else
        with {:ok, current} <- read_poem(root, id),
             true <- is_binary(existing[:token]) and existing[:token] == current.token,
             {:ok, poems} <- poems_root(root, true),
             {:ok, dir} <- poem_dir(root, id),
             {:ok, current_text} <- File.read(current.path),
             {:ok, metadata_bytes} <- File.read(Path.join(dir, @metadata)) do
          if current_text == body and current.title == title do
            {:ok, Map.put(current, :scope, scope)}
          else
            now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
            filename = Path.basename(current.path)

            next_metadata = %{
              "id" => id,
              "title" => title,
              "created_at" => current.created_at,
              "updated_at" => now,
              "filename" => filename
            }

            next_meta_bytes = Jason.encode!(next_metadata, pretty: true) <> "\n"

            with :ok <-
                   write_revision(dir, id,
                     title: current.title,
                     body: current_text,
                     created_at: now
                   ),
                 :ok <- token_still_current(root, id, current.token),
                 :ok <-
                   write_journal(
                     dir,
                     current_text,
                     metadata_bytes,
                     filename,
                     body,
                     next_meta_bytes
                   ),
                 :ok <- token_still_current(root, id, current.token),
                 :ok <- atomic_write(current.path, body),
                 :ok <- atomic_write(Path.join(dir, @metadata), next_meta_bytes),
                 :ok <- File.rm(Path.join(dir, @journal)),
                 :ok <- sync_dir(dir) do
              _ = poems

              case read_poem(root, id) do
                {:ok, poem} -> {:ok, Map.put(poem, :scope, scope)}
                error -> error
              end
            else
              {:error, reason} -> {:error, explain(reason)}
            end
          end
        else
          false ->
            {:error, "This poem changed on disk since it was opened. Reopen it before saving."}

          {:error, reason} ->
            {:error, explain(reason)}
        end
      end
    end
  end

  defp create_poem(root, id, body, title) do
    with true <- valid_id?(id),
         {:ok, poems} <- poems_root(root, true),
         false <- File.exists?(Path.join(poems, id)),
         now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
         staging = Path.join(poems, ".#{id}.partial-#{System.unique_integer([:positive])}"),
         :ok <- File.mkdir(staging),
         :ok <- File.chmod(staging, 0o700),
         :ok <- File.mkdir(Path.join(staging, "revisions")),
         :ok <- File.chmod(Path.join(staging, "revisions"), 0o700),
         :ok <- atomic_write(Path.join(staging, "poem.txt"), body),
         metadata =
           Jason.encode!(
             %{
               "id" => id,
               "title" => title,
               "created_at" => now,
               "updated_at" => now,
               "filename" => "poem.txt"
             },
             pretty: true
           ) <> "\n",
         :ok <- atomic_write(Path.join(staging, @metadata), metadata),
         :ok <- File.rename(staging, Path.join(poems, id)),
         :ok <- sync_dir(poems) do
      read_poem(root, id)
    else
      false -> {:error, "This poem identifier already exists. Reopen it before saving."}
      {:error, reason} -> {:error, explain(reason)}
      _ -> {:error, "This poem could not be created safely."}
    end
  end

  defp read_entries(poems, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case read_poem_dir(poems, id) do
        {:ok, poem} ->
          with {:ok, dir} <- poem_dir_from_poems(poems, id),
               :ok <- recover(dir, poem),
               {:ok, latest} <- read_poem_dir(poems, id) do
            {:cont, {:ok, [latest | acc]}}
          else
            {:error, reason} -> {:halt, {:error, explain(reason)}}
          end

        {:skip, _} ->
          {:cont, {:ok, acc}}

        error ->
          {:halt, normalize_error(error)}
      end
    end)
  end

  defp poem_dir_from_poems(poems, id) do
    path = Path.join(poems, id)
    with true <- valid_id?(id), :ok <- safe_dir(path), do: {:ok, path}
  end

  defp read_poem(root, id) do
    with true <- valid_id?(id),
         {:ok, poems} <- poems_root(root, false),
         {:ok, poem} <- read_poem_dir(poems, id),
         {:ok, dir} <- poem_dir(root, id),
         :ok <- recover(dir, poem) do
      read_poem_dir(poems, id)
    else
      false -> {:error, "This poem identifier is invalid."}
      :missing -> {:error, "This collection has no saved poems yet."}
      {:skip, _} -> {:error, "This poem could not be found in the selected collection."}
      {:error, reason} -> {:error, explain(reason)}
    end
  end

  defp token_still_current(root, id, expected) do
    with {:ok, poems} <- poems_root(root, false),
         {:ok, current} <- read_poem_dir(poems, id),
         true <- current.token == expected do
      :ok
    else
      false ->
        {:error,
         "This poem changed on disk during the save. Its files and recovery journal were preserved."}

      {:error, reason} ->
        {:error, explain(reason)}

      _ ->
        {:error,
         "This poem changed on disk during the save. Its files and recovery journal were preserved."}
    end
  end

  defp read_poem_dir(poems, id) do
    if not valid_id?(id) do
      {:skip, :invalid}
    else
      dir = Path.join(poems, id)

      with :ok <- safe_dir(dir),
           :ok <- safe_file(Path.join(dir, @metadata)),
           {:ok, meta_bytes} <- File.read(Path.join(dir, @metadata)),
           {:ok, meta} when is_map(meta) <- Jason.decode(meta_bytes),
           true <- meta["id"] == id,
           true <- valid_metadata?(meta),
           {:ok, names} <- File.ls(dir),
           files = Enum.filter(names, &String.ends_with?(&1, ".txt")),
           true <- length(files) == 1,
           filename = hd(files),
           :ok <- safe_file(Path.join(dir, filename)),
           {:ok, body} <- File.read(Path.join(dir, filename)),
           {:ok, _} <- valid_text(body) do
        token = digest(meta_bytes <> <<0>> <> filename <> <<0>> <> body)

        {:ok,
         %{
           id: id,
           title: meta["title"],
           body: body,
           token: token,
           created_at: meta["created_at"],
           updated_at: meta["updated_at"],
           path: Path.join(dir, filename)
         }}
      else
        {:error, :enoent} ->
          {:error, "Poem folder #{id} is incomplete; its files were left untouched."}

        false ->
          {:error, "Poem folder #{id} has invalid metadata or more than one text file."}

        {:error, reason} ->
          {:error, explain(reason)}

        _ ->
          {:error, "Poem folder #{id} is damaged. Its files were left untouched."}
      end
    end
  end

  defp poems_root(root, create?) do
    path = Path.join(root, "poems")

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case safe_file(Path.join(path, @marker)) do
          :ok ->
            case File.read(Path.join(path, @marker)) do
              {:ok, marker} ->
                case Jason.decode(marker) do
                  {:ok, %{"format" => "still-poems-v1"}} ->
                    {:ok, path}

                  _ ->
                    {:error,
                     "The poems folder has an unknown format; its files were left untouched."}
                end

              {:error, :enoent} ->
                {:error,
                 "The poems folder has no Still format marker; its files were left untouched."}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :enoent} ->
            {:error,
             "The poems folder has no Still format marker; its files were left untouched."}

          error ->
            error
        end

      {:ok, _} ->
        {:error, "The poems folder is not a safe directory."}

      {:error, :enoent} when create? ->
        with :ok <- File.mkdir(path),
             :ok <- File.chmod(path, 0o700),
             :ok <- atomic_write(Path.join(path, @marker), @marker_contents),
             do: {:ok, path}

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poem_dir(root, id) do
    with {:ok, poems} <- poems_root(root, false) do
      path = Path.join(poems, id)

      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          {:ok, path}

        {:ok, _} ->
          {:error, "The poem folder is not a safe directory."}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp write_revision(dir, id, fields) do
    revisions = Path.join(dir, "revisions")
    rev_id = Ecto.UUID.generate()
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()
    name = "#{timestamp}-#{rev_id}"
    staging = Path.join(revisions, ".#{name}.partial-#{Ecto.UUID.generate()}")
    published = Path.join(revisions, name)

    result =
      with :ok <- ensure_safe_dir(revisions),
           :ok <- File.mkdir(staging),
           :ok <- File.chmod(staging, 0o700),
           :ok <- atomic_write(Path.join(staging, "poem.txt"), fields[:body]),
           metadata =
             Jason.encode!(
               %{
                 "id" => id,
                 "revision_id" => rev_id,
                 "title" => fields[:title],
                 "created_at" => fields[:created_at],
                 "filename" => "poem.txt"
               },
               pretty: true
             ) <> "\n",
           :ok <- atomic_write(Path.join(staging, @metadata), metadata),
           :ok <- sync_dir(staging),
           :ok <- File.rename(staging, published),
           :ok <- sync_dir(revisions) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm_rf(staging)
        {:error, reason}
    end
  end

  defp read_revision(path, id) do
    with :ok <- safe_dir(path),
         :ok <- safe_file(Path.join(path, @metadata)),
         :ok <- safe_file(Path.join(path, "poem.txt")),
         {:ok, bytes} <- File.read(Path.join(path, @metadata)),
         {:ok, rev} when is_map(rev) <- Jason.decode(bytes),
         true <- rev["id"] == id,
         true <- rev["revision_id"] == revision_id(Path.basename(path)),
         true <- rev["filename"] == "poem.txt",
         true <- valid_revision_title?(rev["title"]),
         true <- valid_time?(rev["created_at"]),
         {:ok, body} <- File.read(Path.join(path, "poem.txt")),
         {:ok, _} <- valid_text(body) do
      {:ok,
       %{
         id: rev["revision_id"],
         title: rev["title"],
         body: body,
         created_at: rev["created_at"]
       }}
    else
      _ -> {:error, "A saved poem revision is damaged; its files were left untouched."}
    end
  end

  defp valid_revision_name?(name), do: is_binary(name) and not is_nil(revision_id(name))

  defp revision_id(name) do
    case String.split(name, "-", parts: 2) do
      [timestamp, id] when timestamp != "" ->
        if String.match?(timestamp, ~r/^\d+$/) and Ecto.UUID.cast(id) != :error, do: id

      _ ->
        nil
    end
  end

  defp valid_revision_title?(nil), do: true

  defp valid_revision_title?(title),
    do: is_binary(title) and String.valid?(title) and not String.contains?(title, <<0>>)

  defp write_journal(dir, old_body, old_meta, filename, body, meta) do
    data = %{
      "filename" => filename,
      "old_body" => Base.encode64(old_body),
      "old_metadata" => Base.encode64(old_meta),
      "new_body" => Base.encode64(body),
      "new_metadata" => Base.encode64(meta)
    }

    atomic_write(Path.join(dir, @journal), Jason.encode!(data) <> "\n")
  end

  defp recover(dir, poem) do
    path = Path.join(dir, @journal)

    case safe_file(path) do
      {:error, :enoent} ->
        :ok

      :ok ->
        with {:ok, bytes} <- File.read(path) do
          with {:ok, j} when is_map(j) <- Jason.decode(bytes),
               filename when is_binary(filename) <- j["filename"],
               true <- Path.basename(filename) == filename and String.ends_with?(filename, ".txt"),
               :ok <- safe_file(Path.join(dir, filename)),
               :ok <- safe_file(Path.join(dir, @metadata)),
               {:ok, current_body} <- File.read(Path.join(dir, filename)),
               {:ok, current_meta} <- File.read(Path.join(dir, @metadata)),
               {:ok, old_body} <- Base.decode64(j["old_body"]),
               {:ok, old_meta} <- Base.decode64(j["old_metadata"]),
               {:ok, new_body} <- Base.decode64(j["new_body"]),
               {:ok, new_meta} <- Base.decode64(j["new_metadata"]),
               {:ok, _} <- valid_text(old_body),
               {:ok, _} <- valid_text(new_body),
               true <- valid_journal_metadata?(old_meta, poem.id),
               true <- valid_journal_metadata?(new_meta, poem.id) do
            cond do
              current_body == new_body and current_meta == new_meta ->
                File.rm(path)

              current_body in [old_body, new_body] and current_meta in [old_meta, new_meta] ->
                with :ok <- atomic_write(Path.join(dir, filename), new_body),
                     :ok <- atomic_write(Path.join(dir, @metadata), new_meta),
                     :ok <- File.rm(path),
                     do: sync_dir(dir)

              true ->
                {:error,
                 "An interrupted poem save conflicts with later file changes. The journal and all poem files were preserved."}
            end
          else
            _ ->
              {:error,
               "An interrupted poem save cannot be verified. The journal and all poem files were preserved."}
          end
        else
          {:error, reason} -> {:error, explain(reason)}
        end

      error ->
        error
    end
  rescue
    _ ->
      {:error,
       "An interrupted poem save cannot be verified. The journal and all poem files were preserved."}
  end

  defp valid_journal_metadata?(bytes, id) do
    with {:ok, metadata} when is_map(metadata) <- Jason.decode(bytes),
         true <- metadata["id"] == id,
         true <- valid_metadata?(metadata) do
      true
    else
      _ -> false
    end
  end

  defp with_location(passed, fun) do
    case Still.Storage.collection_location() do
      %{configured: true, available: true, folder: root, scope: scope} when is_binary(root) ->
        passed_scope = if is_map(passed), do: passed[:scope] || passed["scope"], else: nil

        if is_binary(passed_scope) and passed_scope != scope do
          {:error, "The active collection changed. Reopen the poem before continuing."}
        else
          if File.dir?(root) do
            :global.trans({{__MODULE__, scope}, self()}, fn ->
              with_filesystem_lock(root, scope, fun)
            end)
          else
            {:error,
             "The selected collection folder became unavailable. Reconnect it before continuing."}
          end
        end

      %{configured: false} ->
        {:error, "Choose a collection folder before saving poems."}

      %{available: false, error: error} ->
        {:error, error || "The selected collection folder is unavailable."}

      _ ->
        {:error, "The selected collection folder is unavailable."}
    end
  end

  defp with_filesystem_lock(root, scope, fun) do
    lock_dir = Path.join(root, ".still-poems-lock")
    owner_path = Path.join(lock_dir, "owner")

    case File.mkdir(lock_dir) do
      :ok ->
        token = Ecto.UUID.generate()

        case write_lock_owner(owner_path, token) do
          :ok ->
            result =
              try do
                case Still.Storage.collection_location() do
                  %{configured: true, available: true, folder: ^root, scope: ^scope} ->
                    fun.(root, scope)

                  _ ->
                    {:error,
                     "The active collection changed while waiting for its file lock. Reopen the poem."}
                end
              rescue
                error -> {:error, "Poem operation failed: #{Exception.message(error)}"}
              catch
                kind, reason -> {:error, "Poem operation failed: #{inspect({kind, reason})}"}
              end

            case release_filesystem_lock(lock_dir, owner_path, token, root) do
              :ok ->
                result

              {:error, reason} ->
                {:error,
                 "Poem operation finished, but its collection lock could not be released: #{reason}. Close Still instances before removing #{lock_dir}."}
            end

          {:error, reason} ->
            {:error,
             "Could not establish the poem collection lock: #{explain(reason)}. Its lock folder is #{lock_dir}; check it before continuing."}
        end

      {:error, :eexist} ->
        {:error,
         "Another Still instance is using this poem collection, or a previous instance left a lock. Close every Still instance before removing #{lock_dir}; do not remove it while another instance is writing."}

      {:error, reason} ->
        {:error, "Could not lock the poem collection: #{explain(reason)}."}
    end
  end

  defp write_lock_owner(path, token) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result =
          try do
            with :ok <- IO.binwrite(io, token <> "\n"), :ok <- :file.sync(io), do: :ok
          after
            File.close(io)
          end

        with :ok <- result, :ok <- File.chmod(path, 0o600), do: :ok

      error ->
        error
    end
  end

  defp release_filesystem_lock(lock_dir, owner_path, token, root) do
    with :ok <- safe_file(owner_path),
         {:ok, current} <- File.read(owner_path),
         true <- current == token <> "\n",
         {:ok, ["owner"]} <- File.ls(lock_dir),
         :ok <- File.rm(owner_path),
         :ok <- File.rmdir(lock_dir),
         :ok <- sync_dir(root) do
      :ok
    else
      false ->
        {:error, "the owner token changed"}

      {:ok, entries} ->
        {:error, "unexpected files remain in the lock folder: #{inspect(entries)}"}

      {:error, reason} ->
        {:error, explain(reason)}

      _ ->
        {:error, "the lock folder is not in its expected state"}
    end
  end

  defp valid_text(text) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>),
      do: {:ok, text},
      else: {:error, "Poem text must be valid UTF-8 without null bytes."}
  end

  defp valid_text(_), do: {:error, "Poem text must be a string."}
  defp valid_title(nil), do: {:ok, nil}

  defp valid_title(title) when is_binary(title),
    do:
      if(String.valid?(title) and not String.contains?(title, <<0>>),
        do: {:ok, title},
        else: {:error, "Poem title must be valid UTF-8 without null bytes."}
      )

  defp valid_title(_), do: {:error, "Poem title must be text or empty."}
  defp valid_id?(id), do: is_binary(id) and Ecto.UUID.cast(id) != :error

  defp valid_metadata?(meta) do
    title = meta["title"]
    filename = meta["filename"]

    valid_title =
      is_nil(title) or
        (is_binary(title) and String.valid?(title) and not String.contains?(title, <<0>>))

    valid_filename =
      is_binary(filename) and Path.basename(filename) == filename and
        String.ends_with?(filename, ".txt")

    valid_title and valid_filename and valid_time?(meta["created_at"]) and
      valid_time?(meta["updated_at"])
  end

  defp valid_time?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> true
      _ -> false
    end
  end

  defp valid_time?(_), do: false
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp atomic_write(path, bytes) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    result =
      case File.open(tmp, [:write, :binary, :exclusive]) do
        {:ok, io} ->
          try do
            with :ok <- IO.binwrite(io, bytes), :ok <- :file.sync(io), do: :ok
          after
            File.close(io)
          end

        error ->
          error
      end

    with :ok <- result,
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path),
         :ok <- sync_dir(Path.dirname(path)) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp sync_dir(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, io} ->
        result = :file.sync(io)
        :file.close(io)

        case result do
          :ok -> :ok
          {:error, reason} when reason in [:eisdir, :enotsup, :einval] -> :ok
          error -> error
        end

      {:error, reason} when reason in [:eisdir, :enotsup, :einval] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_dir(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _} -> {:error, "A poem path is a symlink or is not a directory."}
      error -> error
    end
  end

  defp safe_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _} -> {:error, "A poem file is a symlink or is not a regular file."}
      error -> error
    end
  end

  defp ensure_safe_dir(path) do
    case safe_dir(path) do
      :ok -> :ok
      {:error, :enoent} -> with :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700), do: :ok
      error -> error
    end
  end

  defp explain(reason) when is_binary(reason), do: reason
  defp explain(reason) when is_atom(reason), do: :file.format_error(reason) |> List.to_string()
  defp explain(reason), do: inspect(reason)

  defp normalize_error({:error, reason}), do: {:error, explain(reason)}
  defp normalize_error(error), do: error
end

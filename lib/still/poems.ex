defmodule Still.Poems do
  @moduledoc """
  File-backed writing in the currently selected Still collection.

  Original UUID folders remain readable. Explicit saves enable the v2 marker before
  publishing readable folder names, so older app versions refuse this newer collection safely.

  A collection lock left by a crashed process is never removed automatically. Close all Still
  instances before manually removing `.still-poems-lock` from the selected collection folder.
  The lock coordinates Still instances; an external editor can still race a final token check.
  """

  @marker ".still-poems.json"
  @marker_contents Jason.encode!(%{"format" => "still-poems-v2"}, pretty: true) <> "\n"
  @metadata "metadata.json"
  @journal ".save-journal.json"

  @doc "The optional title supplied by the writer; automatic titles leave this empty."
  def explicit_title(%{title_source: "first_line"}), do: nil
  def explicit_title(piece), do: piece.title

  @doc "The explicit title or a shortened first written line, without changing the body."
  def display_title(%{body: body} = piece) do
    title = explicit_title(piece)

    if is_binary(title) && String.trim(title) != "" do
      title
    else
      line =
        body
        |> String.split(~r/\r\n|\r|\n/)
        |> Enum.find("", &(String.trim(&1) != ""))
        |> String.trim()

      cond do
        line == "" -> "Untitled"
        String.length(line) > 60 -> String.slice(line, 0, 59) <> "…"
        true -> line
      end
    end
  end

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

  @doc "Keeps one editable file-backed version of a historical List, preserving its source link."
  def from_historical(location, %{origin: "before", source_key: key} = entry)
      when is_binary(key) and key != "" do
    with {:ok, body} <- valid_text(entry.body),
         {:ok, title} <- valid_title(entry.title) do
      # The importer source key survives restored databases; titles and filenames do not define identity.
      <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
        :crypto.hash(:sha256, "still-historical-list-v1:" <> key)

      {:ok, id} = Ecto.UUID.load(<<a::48, 8::4, b::12, 2::2, c::62>>)

      source = %{
        "kind" => "historical_list",
        "source_key" => key,
        "title" => entry.title,
        "notebook" => entry.notebook,
        "source_number" => Still.Writing.source_number(entry)
      }

      with_location(location, fn root, scope ->
        with {:ok, poems} <- poems_root(root, true) do
          case poem_dir_from_poems(poems, id) do
            {:ok, _} ->
              with {:ok, piece} <- read_poem(root, id) do
                if piece.historical_source && piece.historical_source["source_key"] == key,
                  do: {:ok, Map.put(piece, :scope, scope)},
                  else:
                    {:error,
                     "This saved identifier belongs to a different source. Its writing was left untouched."}
              end

            {:error, :enoent} ->
              with :ok <- historical_not_in_trash(poems, id) do
                automatic? = is_nil(title) or String.trim(title) == ""
                effective = if automatic?, do: first_line_title(body), else: title
                title_source = if automatic?, do: "first_line", else: "explicit"

                case create_poem(root, id, body, effective, title_source, source) do
                  {:ok, piece} -> {:ok, Map.put(piece, :scope, scope)}
                  error -> error
                end
              end

            {:error, reason} ->
              {:error, explain(reason)}
          end
        end
      end)
    end
  end

  def from_historical(_, _),
    do:
      {:error, "Only a historical List with a preserved source identifier can be added this way."}

  defp historical_not_in_trash(poems, id) do
    case trash_root(poems, false) do
      :missing ->
        :ok

      {:ok, trash} ->
        case poem_dir_from_poems(trash, id) do
          {:error, :enoent} ->
            :ok

          {:ok, _} ->
            {:error,
             "This List already has a saved version in Trash. Restore it from Saved writing before continuing."}

          {:error, reason} ->
            {:error, explain(reason)}
        end

      {:error, reason} ->
        {:error, explain(reason)}
    end
  end

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

  @doc "Lists saved writing without replaying or removing any interrupted-save journal."
  def list_read_only(location) do
    case Still.Storage.collection_location() do
      %{configured: true, available: true, folder: root, scope: scope} when is_binary(root) ->
        passed_scope = if is_map(location), do: location[:scope] || location["scope"], else: nil

        cond do
          is_binary(passed_scope) and passed_scope != scope ->
            {:error, "The active collection changed. Reopen the writing before continuing."}

          File.dir?(root) ->
            list_read_only_root(root, scope)

          true ->
            {:error,
             "The selected collection folder became unavailable. Reconnect it before continuing."}
        end

      %{configured: false} ->
        {:error, "Choose a collection folder before reading saved writing."}

      %{available: false, error: error} ->
        {:error, error || "The selected collection folder is unavailable."}

      _ ->
        {:error, "The selected collection folder is unavailable."}
    end
  end

  defp list_read_only_root(root, scope) do
    case poems_root(root, false) do
      :missing ->
        {:ok, []}

      {:ok, poems} ->
        with {:ok, ids} <- File.ls(poems),
             {:ok, entries} <- read_entries_read_only(poems, ids) do
          {:ok,
           entries
           |> Enum.map(&Map.put(&1, :scope, scope))
           |> Enum.sort_by(&{&1.updated_at || "", &1.id}, :desc)}
        else
          {:error, reason} -> {:error, explain(reason)}
        end

      error ->
        normalize_error(error)
    end
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

  @doc "Lists safely readable writings in the collection's recoverable trash."
  def list_trash(location) do
    with_location(location, fn root, scope ->
      case poems_root(root, false) do
        :missing ->
          {:ok, []}

        {:ok, poems} ->
          case trash_root(poems, false) do
            :missing ->
              {:ok, []}

            {:ok, trash} ->
              with {:ok, ids} <- File.ls(trash),
                   {:ok, entries} <- read_trash_entries(trash, ids) do
                {:ok,
                 entries
                 |> Enum.map(&Map.put(&1, :scope, scope))
                 |> Enum.sort_by(&{&1.updated_at || "", &1.id}, :desc)}
              else
                {:error, reason} -> {:error, explain(reason)}
              end

            error ->
              normalize_error(error)
          end

        error ->
          normalize_error(error)
      end
    end)
  end

  @doc "Moves a saved writing into recoverable trash after checking its open snapshot token."
  def trash(location, existing) when is_map(existing) do
    id = Map.get(existing, :id)
    expected = Map.get(existing, :token)

    if valid_id?(id) and is_binary(expected) do
      with_location(location, fn root, scope ->
        if is_binary(existing[:scope]) and existing.scope != scope do
          {:error, "The active collection changed. Reopen the writing before moving it to trash."}
        else
          with {:ok, current} <- read_poem(root, id),
               true <- current.token == expected,
               {:ok, poems} <- poems_root(root, false),
               {:ok, source} <- poem_dir(root, id),
               {:ok, trash} <- trash_root(poems, true),
               :ok <- identifier_available(trash, id),
               :ok <- token_still_current(root, id, expected) do
            case File.rename(source, Path.join(trash, id)) do
              :ok -> finish_trash_move(poems, trash, id, scope)
              {:error, reason} -> {:error, explain(reason)}
            end
          else
            false -> stale_writing_error()
            :missing -> {:error, "This collection has no saved writings to trash."}
            {:error, reason} -> {:error, explain(reason)}
          end
        end
      end)
    else
      {:error, "This writing has no valid identifier or current save token."}
    end
  end

  def trash(_, _), do: {:error, "The writing could not be trashed because its data is invalid."}

  @doc "Restores a trashed writing if its original identifier is still available."
  def restore(location, id) do
    if valid_id?(id) do
      with_location(location, fn root, scope ->
        with {:ok, poems} <- poems_root(root, false),
             {:ok, trash} <- trash_root(poems, false),
             {:ok, current} <- read_trash_poem(trash, id),
             :ok <- identifier_available(poems, id),
             {:ok, ^poems} <- poems_root(root, true) do
          case File.rename(
                 Path.dirname(current.path),
                 Path.join(poems, folder_name(id, current.title, current.body))
               ) do
            :ok -> finish_restore_move(root, poems, trash, id, scope)
            {:error, reason} -> {:error, explain(reason)}
          end
        else
          :missing -> {:error, "There are no trashed writings in this collection."}
          {:error, reason} -> {:error, explain(reason)}
        end
      end)
    else
      {:error, "This writing identifier is invalid."}
    end
  end

  @doc "Permanently removes a trashed writing after explicit confirmation and token validation."
  def purge(location, id, token, confirmed?) do
    cond do
      confirmed? !== true ->
        {:error, "Permanent deletion requires explicit confirmation."}

      not valid_id?(id) ->
        {:error, "This writing identifier is invalid."}

      not is_binary(token) ->
        {:error, "Permanent deletion requires the current save token."}

      true ->
        with_location(location, fn root, _scope ->
          with {:ok, poems} <- poems_root(root, false),
               {:ok, trash} <- trash_root(poems, false),
               {:ok, current} <- read_trash_poem(trash, id),
               true <- current.token == token,
               {:ok, dir} <- poem_dir_from_poems(trash, id),
               :ok <- validate_purge_tree(dir, id),
               :ok <- trash_token_still_current(trash, id, token),
               :ok <- remove_trash_tree(dir) do
            case sync_dir(trash) do
              :ok ->
                :ok

              {:error, reason} ->
                {:error,
                 "The writing was permanently removed, but its trash folder could not be synced: #{explain(reason)}. Refresh trash to see the current contents."}
            end
          else
            false -> stale_trash_error()
            :missing -> {:error, "There are no trashed writings in this collection."}
            {:error, reason} -> {:error, explain(reason)}
          end
        end)
    end
  end

  def save(location, existing, attrs) when is_map(existing) and is_map(attrs) do
    with {:ok, body} <- valid_text(Map.get(attrs, :body)),
         {:ok, title} <- valid_title(Map.get(attrs, :title)) do
      with_location(location, fn root, scope ->
        id = Map.get(existing, :id)

        if is_binary(id) do
          automatic? = is_nil(title) or String.trim(title) == ""
          effective = if automatic?, do: first_line_title(body), else: title
          source = if automatic?, do: "first_line", else: "explicit"
          do_save(root, scope, existing, id, body, effective, source)
        else
          {:error, "This writing has no valid identifier."}
        end
      end)
    end
  end

  def save(_, _, _), do: {:error, "The writing could not be saved because its data is invalid."}

  defp do_save(root, scope, existing, id, body, title, title_source) do
    if is_binary(existing[:scope]) and existing.scope != scope do
      {:error, "The active collection changed. Reopen the writing before continuing."}
    else
      if is_nil(existing[:token]) do
        case create_poem(root, id, body, title, title_source) do
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
          if current_text == body and current.title == title and
               current.title_source == title_source do
            finish_save(root, scope, id, title, body)
          else
            now = DateTime.utc_now() |> DateTime.to_iso8601()
            filename = Path.basename(current.path)

            next_metadata = %{
              "id" => id,
              "title" => title,
              "title_source" => title_source,
              "created_at" => current.created_at,
              "updated_at" => now,
              "filename" => filename,
              "historical_source" => current.historical_source
            }

            next_meta_bytes = Jason.encode!(next_metadata, pretty: true) <> "\n"

            with {:ok, revision_name} <-
                   write_revision(dir, id,
                     title: current.title,
                     title_source: current.title_source,
                     body: current_text,
                     created_at: now
                   ),
                 :ok <-
                   token_still_current(root, id, current.token, [
                     Path.join("revisions", revision_name)
                   ]),
                 :ok <-
                   write_journal(
                     dir,
                     current_text,
                     metadata_bytes,
                     filename,
                     body,
                     next_meta_bytes
                   ),
                 :ok <-
                   token_still_current(root, id, current.token, [
                     Path.join("revisions", revision_name),
                     @journal
                   ]),
                 :ok <- atomic_write(current.path, body),
                 :ok <- atomic_write(Path.join(dir, @metadata), next_meta_bytes),
                 :ok <- File.rm(Path.join(dir, @journal)),
                 :ok <- sync_dir(dir) do
              _ = poems

              finish_save(root, scope, id, title, body)
            else
              {:error, reason} -> {:error, explain(reason)}
            end
          end
        else
          false ->
            {:error, "This writing changed on disk since it was opened. Reopen it before saving."}

          {:error, reason} ->
            {:error, explain(reason)}
        end
      end
    end
  end

  defp create_poem(root, id, body, title, title_source, historical_source \\ nil) do
    with true <- valid_id?(id),
         {:ok, poems} <- poems_root(root, true),
         :ok <- identifier_available(poems, id),
         now = DateTime.utc_now() |> DateTime.to_iso8601(),
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
               "title_source" => title_source,
               "created_at" => now,
               "updated_at" => now,
               "filename" => "poem.txt",
               "historical_source" => historical_source
             },
             pretty: true
           ) <> "\n",
         :ok <- atomic_write(Path.join(staging, @metadata), metadata),
         :ok <- File.rename(staging, Path.join(poems, folder_name(id, title, body))),
         :ok <- sync_dir(poems) do
      read_poem(root, id)
    else
      false -> {:error, "This writing identifier already exists. Reopen it before saving."}
      {:error, reason} -> {:error, explain(reason)}
      _ -> {:error, "This writing could not be created safely."}
    end
  end

  defp read_entries(poems, ids) do
    ids = ids |> Enum.map(&directory_id/1) |> Enum.reject(&is_nil/1)

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

  defp read_entries_read_only(poems, ids) do
    ids = ids |> Enum.map(&directory_id/1) |> Enum.reject(&is_nil/1)

    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case read_poem_dir(poems, id) do
        {:ok, poem} ->
          with {:ok, dir} <- poem_dir_from_poems(poems, id),
               :ok <- no_interrupted_journal(dir, id) do
            {:cont, {:ok, [poem | acc]}}
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

  defp no_interrupted_journal(dir, id) do
    case safe_file(Path.join(dir, @journal)) do
      {:error, :enoent} ->
        :ok

      :ok ->
        {:error, "Writing folder #{id} has an interrupted save; its files were left untouched."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Accept original UUID folders and readable labels carrying the full stable ID.
  # Refuse duplicate identities among recognized folders; never choose arbitrarily.
  defp directory_id(name) do
    candidate = name |> String.split(" -- ") |> List.last()
    if valid_id?(candidate), do: candidate
  end

  defp poem_dir_from_poems(poems, id) do
    with true <- valid_id?(id), {:ok, names} <- File.ls(poems) do
      case Enum.filter(names, &(directory_id(&1) == id)) do
        [] ->
          {:error, :enoent}

        [name] ->
          path = Path.join(poems, name)
          with :ok <- safe_dir(path), do: {:ok, path}

        _ ->
          {:error,
           "Multiple writing folders share this identifier. Their files were left untouched."}
      end
    else
      false -> {:error, "This writing identifier is invalid."}
      error -> error
    end
  end

  defp identifier_available(poems, id) do
    case poem_dir_from_poems(poems, id) do
      {:error, :enoent} -> :ok
      {:ok, _} -> {:error, "A writing with this identifier already exists at the destination."}
      error -> error
    end
  end

  defp first_line_title(body) do
    case display_title(%{title: nil, body: body}) do
      "Untitled" -> if String.trim(body) == "", do: nil, else: "Untitled"
      title -> title
    end
  end

  defp folder_name(id, title, body) do
    label =
      display_title(%{title: title, body: body})
      |> String.replace(~r/[\p{C}<>:"\/\\|?*]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.trim(".")
      |> String.graphemes()
      |> Enum.reduce_while("", fn glyph, acc ->
        if byte_size(acc <> glyph) <= 160, do: {:cont, acc <> glyph}, else: {:halt, acc}
      end)
      |> String.trim()

    label = if label == "", do: "Untitled", else: label
    label <> " -- " <> id
  end

  defp finish_save(root, scope, id, title, body) do
    with {:ok, poems} <- poems_root(root, true),
         {:ok, dir} <- poem_dir_from_poems(poems, id),
         destination = Path.join(poems, folder_name(id, title, body)),
         :ok <- rename_saved_folder(dir, destination, poems),
         {:ok, piece} <- read_poem(root, id) do
      {:ok, Map.put(piece, :scope, scope)}
    end
  end

  defp rename_saved_folder(dir, dir, _poems), do: :ok

  defp rename_saved_folder(dir, destination, poems) do
    # The full ID suffix disambiguates equal titles. A case-only rename can refer
    # to the same inode on macOS; another existing path must never be replaced.
    available =
      case File.lstat(destination) do
        {:error, :enoent} ->
          :ok

        {:ok, %{type: :directory, inode: inode, major_device: device}} ->
          case File.lstat(dir) do
            {:ok, %{inode: ^inode, major_device: ^device}} -> :ok
            _ -> {:error, "The destination already exists."}
          end

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, "The destination already exists."}
      end

    with :ok <- available, :ok <- File.rename(dir, destination), :ok <- sync_dir(poems) do
      :ok
    else
      {:error, reason} ->
        {:error,
         "The words were saved, but the folder could not be renamed: #{explain(reason)}. Reopen the writing before continuing."}
    end
  end

  defp read_poem(root, id) do
    with true <- valid_id?(id),
         {:ok, poems} <- poems_root(root, false),
         {:ok, poem} <- read_poem_dir(poems, id),
         {:ok, dir} <- poem_dir(root, id),
         :ok <- recover(dir, poem) do
      read_poem_dir(poems, id)
    else
      false -> {:error, "This writing identifier is invalid."}
      :missing -> {:error, "This collection has no saved writing yet."}
      {:skip, _} -> {:error, "This writing could not be found in the selected collection."}
      {:error, reason} -> {:error, explain(reason)}
    end
  end

  defp token_still_current(root, id, expected), do: token_still_current(root, id, expected, [])

  defp token_still_current(root, id, expected, excluded_paths) do
    with {:ok, dir} <- poem_dir(root, id),
         {:ok, current_token} <- poem_tree_token(dir, excluded_paths),
         true <- current_token == expected do
      :ok
    else
      false ->
        {:error,
         "This writing changed on disk during the save. Its files and recovery journal were preserved."}

      {:error, reason} ->
        {:error, explain(reason)}

      _ ->
        {:error,
         "This writing changed on disk during the save. Its files and recovery journal were preserved."}
    end
  end

  defp read_poem_dir(poems, id) do
    if not valid_id?(id) do
      {:skip, :invalid}
    else
      with {:ok, dir} <- poem_dir_from_poems(poems, id),
           {:ok, entries, files_by_path} <- fingerprint_tree(dir, "", []),
           {:ok, meta_bytes} <- Map.fetch(files_by_path, @metadata),
           {:ok, meta} when is_map(meta) <- Jason.decode(meta_bytes),
           true <- meta["id"] == id,
           true <- valid_metadata?(meta),
           files =
             Enum.filter(Map.keys(files_by_path), fn path ->
               Path.dirname(path) == "." and String.ends_with?(path, ".txt")
             end),
           true <- length(files) == 1,
           filename = hd(files),
           {:ok, body} <- Map.fetch(files_by_path, filename),
           {:ok, _} <- valid_text(body),
           token = tree_token(entries) do
        {:ok,
         %{
           id: id,
           title: meta["title"],
           historical_source: meta["historical_source"],
           title_source:
             meta["title_source"] ||
               if(meta["title"] in [nil, ""], do: "first_line", else: "explicit"),
           body: body,
           token: token,
           created_at: meta["created_at"],
           updated_at: meta["updated_at"],
           path: Path.join(dir, filename)
         }}
      else
        {:error, :enoent} ->
          {:error, "Writing folder #{id} is incomplete; its files were left untouched."}

        :error ->
          {:error, "Writing folder #{id} is incomplete; its files were left untouched."}

        false ->
          {:error, "Writing folder #{id} has invalid metadata or more than one text file."}

        {:error, reason} ->
          {:error, explain(reason)}

        _ ->
          {:error, "Writing folder #{id} is damaged. Its files were left untouched."}
      end
    end
  end

  defp poem_tree_token(dir, excluded_paths) do
    with :ok <- safe_dir(dir),
         {:ok, entries, _files_by_path} <- fingerprint_tree(dir, "", excluded_paths) do
      {:ok, tree_token(entries)}
    end
  end

  defp tree_token(entries),
    do: digest(:erlang.term_to_binary({:still_writing_tree_v1, entries}, [:deterministic]))

  defp fingerprint_tree(dir, relative, excluded_paths) do
    with {:ok, names} <- File.ls(dir) do
      names
      |> Enum.sort()
      |> Enum.reject(fn name -> Path.join(relative, name) in excluded_paths end)
      |> Enum.reduce_while({:ok, [], %{}}, fn name, {:ok, entries, files_by_path} ->
        path = Path.join(dir, name)
        child_relative = Path.join(relative, name)

        case File.lstat(path) do
          {:ok, %{type: :directory}} ->
            case fingerprint_tree(path, child_relative, excluded_paths) do
              {:ok, children, child_files} ->
                {:cont,
                 {:ok, [{name, {:directory, children}} | entries],
                  Map.merge(files_by_path, child_files)}}

              error ->
                {:halt, error}
            end

          {:ok, %{type: :regular}} ->
            case File.read(path) do
              {:ok, bytes} ->
                {:cont,
                 {:ok, [{name, {:file, bytes}} | entries],
                  Map.put(files_by_path, child_relative, bytes)}}

              error ->
                {:halt, error}
            end

          {:ok, _} ->
            {:halt, {:error, "A writing folder contains a symlink or unsupported file type."}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, reversed, files_by_path} -> {:ok, Enum.reverse(reversed), files_by_path}
        error -> error
      end
    end
  end

  defp finish_trash_move(poems, trash, id, scope) do
    result =
      with :ok <- sync_dir(poems),
           :ok <- sync_dir(trash),
           {:ok, moved} <- read_trash_poem(trash, id) do
        {:ok, Map.put(moved, :scope, scope)}
      end

    case result do
      {:ok, moved} ->
        {:ok, moved}

      {:error, reason} ->
        {:error,
         "The writing was moved to trash, but the move could not be fully verified: #{explain(reason)}. Refresh trash to see its current state."}
    end
  end

  defp finish_restore_move(root, poems, trash, id, scope) do
    result =
      with :ok <- sync_dir(trash),
           :ok <- sync_dir(poems),
           {:ok, restored} <- read_poem(root, id) do
        {:ok, Map.put(restored, :scope, scope)}
      end

    case result do
      {:ok, restored} ->
        {:ok, restored}

      {:error, reason} ->
        {:error,
         "The writing was restored, but the move could not be fully verified: #{explain(reason)}. Reopen it to see its current state."}
    end
  end

  defp remove_trash_tree(dir) do
    case File.rm_rf(dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        {:error,
         "Permanent deletion was incomplete at #{path}: #{explain(reason)}. Some files may already be gone; refresh trash to see what remains."}
    end
  end

  defp read_trash_entries(trash, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      if valid_id?(id) do
        case read_trash_poem(trash, id) do
          {:ok, poem} -> {:cont, {:ok, [poem | acc]}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp read_trash_poem(trash, id) do
    with true <- valid_id?(id),
         {:ok, path} <- poem_dir_from_poems(trash, id),
         {:ok, poem} <- read_poem_dir(trash, id),
         :ok <- recover(path, poem),
         {:ok, current} <- read_poem_dir(trash, id) do
      {:ok, current}
    else
      false -> {:error, "This writing identifier is invalid."}
      {:error, :enoent} -> {:error, "This writing could not be found in trash."}
      {:error, reason} -> {:error, explain(reason)}
      _ -> {:error, "This writing could not be read safely from trash."}
    end
  end

  defp trash_root(poems, create?) do
    path = Path.join(poems, ".trash")

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        {:ok, path}

      {:ok, _} ->
        {:error, "The trash folder is not a safe directory."}

      {:error, :enoent} when create? ->
        with :ok <- File.mkdir(path),
             :ok <- File.chmod(path, 0o700),
             :ok <- sync_dir(poems) do
          {:ok, path}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale_writing_error do
    {:error,
     "This writing changed on disk since it was opened. Reopen it before moving it to trash."}
  end

  defp stale_trash_error do
    {:error,
     "This trashed writing changed on disk. Refresh trash before permanently deleting it."}
  end

  defp trash_token_still_current(trash, id, expected) do
    case read_trash_poem(trash, id) do
      {:ok, current} when current.token == expected -> :ok
      {:ok, _current} -> stale_trash_error()
      {:error, _reason} -> stale_trash_error()
    end
  end

  defp validate_purge_tree(dir, id) do
    with :ok <- safe_dir(dir),
         {:ok, poem} <- read_poem_dir(Path.dirname(dir), id),
         {:ok, names} <- File.ls(dir),
         files = Enum.filter(names, &String.ends_with?(&1, ".txt")),
         true <- length(files) == 1,
         filename = hd(files),
         true <-
           Enum.sort(names) in [
             Enum.sort([@metadata, filename]),
             Enum.sort([@metadata, filename, "revisions"])
           ],
         :ok <- validate_revision_tree(Path.join(dir, "revisions"), id) do
      _ = poem
      :ok
    else
      false ->
        {:error, "Trash contains extra or invalid files; everything was left untouched."}

      {:error, :enoent} ->
        {:error, "A trashed writing is incomplete; everything was left untouched."}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, "Trash could not be verified safely; everything was left untouched."}
    end
  end

  defp validate_revision_tree(path, id) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        with {:ok, names} <- File.ls(path),
             true <- Enum.all?(names, &valid_revision_name?/1),
             :ok <- validate_revisions(path, names, id) do
          :ok
        else
          false ->
            {:error, "Trash contains an invalid revision entry; everything was left untouched."}

          error ->
            error
        end

      {:ok, _} ->
        {:error, "Trash contains an unsafe revisions path; everything was left untouched."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_revisions(_path, [], _id), do: :ok

  defp validate_revisions(path, [name | rest], id) do
    revision_dir = Path.join(path, name)

    with {:ok, names} <- File.ls(revision_dir),
         true <- Enum.sort(names) == Enum.sort([@metadata, "poem.txt"]),
         {:ok, _revision} <- read_revision(revision_dir, id),
         :ok <- validate_revisions(path, rest, id) do
      :ok
    else
      false -> {:error, "A revision contains extra files; everything was left untouched."}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "A revision could not be verified safely; everything was left untouched."}
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
                  {:ok, %{"format" => format}}
                  when format in ["still-poems-v1", "still-poems-v2"] ->
                    if create? and format == "still-poems-v1" do
                      with :ok <- atomic_write(Path.join(path, @marker), @marker_contents),
                           do: {:ok, path}
                    else
                      {:ok, path}
                    end

                  _ ->
                    {:error,
                     "The writings folder has an unknown format; its files were left untouched."}
                end

              {:error, :enoent} ->
                {:error,
                 "The writings folder has no Still format marker; its files were left untouched."}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :enoent} ->
            {:error,
             "The writings folder has no Still format marker; its files were left untouched."}

          error ->
            error
        end

      {:ok, _} ->
        {:error, "The writings folder is not a safe directory."}

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
    with {:ok, poems} <- poems_root(root, false), do: poem_dir_from_poems(poems, id)
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
                 "title_source" => fields[:title_source],
                 "created_at" => fields[:created_at],
                 "filename" => "poem.txt"
               },
               pretty: true
             ) <> "\n",
           :ok <- atomic_write(Path.join(staging, @metadata), metadata),
           :ok <- sync_dir(staging),
           :ok <- File.rename(staging, published),
           :ok <- sync_dir(revisions) do
        {:ok, name}
      end

    case result do
      {:ok, name} ->
        {:ok, name}

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
         true <- rev["title_source"] in [nil, "explicit", "first_line"],
         true <- valid_time?(rev["created_at"]),
         {:ok, body} <- File.read(Path.join(path, "poem.txt")),
         {:ok, _} <- valid_text(body) do
      {:ok,
       %{
         id: rev["revision_id"],
         title: rev["title"],
         title_source: rev["title_source"],
         body: body,
         created_at: rev["created_at"]
       }}
    else
      _ -> {:error, "A saved writing revision is damaged; its files were left untouched."}
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
                 "An interrupted writing save conflicts with later file changes. The journal and all poem files were preserved."}
            end
          else
            _ ->
              {:error,
               "An interrupted writing save cannot be verified. The journal and all poem files were preserved."}
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
       "An interrupted writing save cannot be verified. The journal and all poem files were preserved."}
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
          {:error, "The active collection changed. Reopen the writing before continuing."}
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
        {:error, "Choose a collection folder before saving writing."}

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
                     "The active collection changed while waiting for its file lock. Reopen the writing."}
                end
              rescue
                error -> {:error, "Writing operation failed: #{Exception.message(error)}"}
              catch
                kind, reason -> {:error, "Writing operation failed: #{inspect({kind, reason})}"}
              end

            case release_filesystem_lock(lock_dir, owner_path, token, root) do
              :ok ->
                result

              {:error, reason} ->
                {:error,
                 "Writing operation finished, but its collection lock could not be released: #{reason}. Close Still instances before removing #{lock_dir}."}
            end

          {:error, reason} ->
            {:error,
             "Could not establish the writing collection lock: #{explain(reason)}. Its lock folder is #{lock_dir}; check it before continuing."}
        end

      {:error, :eexist} ->
        {:error,
         "Another Still instance is using this writing collection, or a previous instance left a lock. Close every Still instance before removing #{lock_dir}; do not remove it while another instance is writing."}

      {:error, reason} ->
        {:error, "Could not lock the writing collection: #{explain(reason)}."}
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
      else: {:error, "Writing text must be valid UTF-8 without null bytes."}
  end

  defp valid_text(_), do: {:error, "Writing text must be a string."}
  defp valid_title(nil), do: {:ok, nil}

  defp valid_title(title) when is_binary(title),
    do:
      if(String.valid?(title) and not String.contains?(title, <<0>>),
        do: {:ok, title},
        else: {:error, "Writing title must be valid UTF-8 without null bytes."}
      )

  defp valid_title(_), do: {:error, "Writing title must be text or empty."}
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

    valid_historical_source?(meta["historical_source"]) and
      meta["title_source"] in [nil, "explicit", "first_line"] and valid_title and valid_filename and
      valid_time?(meta["created_at"]) and
      valid_time?(meta["updated_at"])
  end

  defp valid_historical_source?(nil), do: true

  defp valid_historical_source?(%{"kind" => "historical_list", "source_key" => key} = source) do
    is_binary(key) && key != "" && String.valid?(key) && !String.contains?(key, <<0>>) &&
      Enum.all?(["title", "notebook"], fn field ->
        value = source[field]

        is_nil(value) ||
          (is_binary(value) && String.valid?(value) && !String.contains?(value, <<0>>))
      end) &&
      (is_nil(source["source_number"]) ||
         (is_binary(source["source_number"]) &&
            Regex.match?(~r/^[0-9]+$/, source["source_number"])))
  end

  defp valid_historical_source?(_), do: false

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
      {:ok, _} -> {:error, "A writing path is a symlink or is not a directory."}
      error -> error
    end
  end

  defp safe_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _} -> {:error, "A writing file is a symlink or is not a regular file."}
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

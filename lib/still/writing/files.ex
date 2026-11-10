defmodule Still.Writing.Files do
  @moduledoc "Ordinary local files with database-held identities, revisions and save recovery."
  import Ecto.Query
  alias Ecto.Changeset
  alias Still.{Repo, Storage}
  alias Still.Writing.{CollectionFolder, CollectionLock, Entry, Notebook, TextFile, Version}

  def collection_scope(root) do
    root = Path.expand(root)

    case Repo.get_by(CollectionFolder, root: root) do
      %CollectionFolder{id: id} ->
        id

      nil ->
        Repo.insert!(%CollectionFolder{root: root},
          on_conflict: :nothing,
          conflict_target: :root
        )

        Repo.get_by!(CollectionFolder, root: root).id
    end
  end

  def register_folder(location, relative, attrs) when is_map(attrs) do
    with_location(location, fn active -> register_folder_in(active, relative, attrs) end)
  end

  def create_folder(location, relative, attrs) when is_map(attrs) do
    with_location(location, fn active ->
      with {:ok, path} <- safe_directory(active.folder, relative) do
        case File.lstat(path) do
          {:error, :enoent} ->
            case create_directory_path(active.folder, relative) do
              {:ok, created} ->
                case register_folder_in(active, relative, attrs) do
                  {:ok, notebook} ->
                    {:ok, notebook}

                  error ->
                    Enum.each(created, &File.rmdir/1)
                    error
                end

              {:error, reason, created} ->
                Enum.each(created, &File.rmdir/1)
                {:error, folder_error(reason)}

              {:error, reason} ->
                {:error, folder_error(reason)}

              error ->
                error
            end

          _ ->
            {:error, "That notebook folder already exists; register it instead."}
        end
      end
    end)
  end

  defp register_folder_in(active, relative, attrs) do
    with {:ok, path} <- safe_directory(active.folder, relative),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :directory do
      identity = directory_identity(path)
      existing = Repo.get_by(Notebook, collection_scope: active.scope, folder_identity: identity)
      by_path = Repo.get_by(Notebook, collection_scope: active.scope, relative_path: relative)
      notebook = existing || by_path || %Notebook{}
      attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      key = if attrs["key"] in [nil, ""], do: notebook.key || relative, else: attrs["key"]
      attrs = Map.put(attrs, "key", key)
      collision = Repo.get_by(Notebook, key: key)

      attrs =
        if collision && collision.collection_scope != active.scope,
          do: Map.put(attrs, "key", key <> " [" <> String.slice(active.scope, 0, 8) <> "]"),
          else: attrs

      attrs =
        Map.merge(attrs, %{
          "collection_scope" => active.scope,
          "relative_path" => relative,
          "folder_identity" => identity
        })

      attrs = if attrs["key"] in [nil, ""], do: Map.put(attrs, "key", relative), else: attrs

      attrs =
        if attrs["label"] in [nil, ""],
          do: Map.put(attrs, "label", Path.basename(relative)),
          else: attrs

      notebook |> Notebook.changeset(attrs) |> Repo.insert_or_update()
    else
      false -> {:error, "Choose an ordinary local folder."}
      {:error, reason} -> {:error, folder_error(reason)}
      error -> error
    end
  end

  def reconnect(scope, root) do
    with true <- File.dir?(root),
         %CollectionFolder{} = folder <- Repo.get(CollectionFolder, scope),
         nil <- Repo.get_by(CollectionFolder, root: Path.expand(root)) do
      folder |> Changeset.change(root: Path.expand(root)) |> Repo.update()
    else
      _ -> {:error, "Choose an available folder not attached to another collection."}
    end
  end

  def new(location) do
    %{
      id: Ecto.UUID.generate(),
      entry_id: nil,
      title: nil,
      body: "",
      token: nil,
      title_source: "first_line",
      title_in_body: true,
      title_line: nil,
      title_needs_review: false,
      created_at: nil,
      updated_at: nil,
      path: nil,
      relative_path: nil,
      historical_source: nil,
      notebook: nil,
      notebook_id: nil,
      list_label: nil,
      source_order: nil,
      scope: if(is_map(location), do: location[:scope])
    }
  end

  def explicit_title(%{title_source: "first_line"}), do: nil
  def explicit_title(%{title_needs_review: true}), do: nil
  def explicit_title(piece), do: piece[:title]

  def display_title(piece) do
    case explicit_title(piece) do
      title when is_binary(title) and title != "" ->
        String.trim(title)

      _ ->
        TextFile.filename_label(piece[:relative_path], piece[:list_label]) ||
          case TextFile.decode(piece.body) do
            {:ok, doc} ->
              {:ok, label} = TextFile.display_label(doc)
              label
          end
    end
  end

  def list(location) do
    case snapshot_pieces(location, recover: true) do
      {:ok, pieces} -> {:ok, pieces}
      :none -> synchronize(location)
      {:error, message} -> {:error, message}
    end
  end

  def list_read_only(location) do
    case snapshot_pieces(location, recover: false) do
      {:ok, pieces} -> {:ok, pieces}
      :none -> synchronize(location, recover: false)
      {:error, message} -> {:error, message}
    end
  end

  @doc "Read only the linked sources, reconciling moved files when requested. Never writes a text file."
  def reference_sources(location, references, opts \\ []) do
    with_location(location, fn active ->
      references = Enum.uniq_by(references, &reference_key/1)
      results = read_reference_sources(active, references)

      if Keyword.get(opts, :reconcile, true) &&
           Enum.any?(results, fn {_, result} -> match?({:error, _}, result) end) do
        case refresh_projection(active, false) do
          {:ok, _} -> {:ok, read_reference_sources(active, references)}
          {:error, _} -> {:ok, results}
        end
      else
        {:ok, results}
      end
    end)
  end

  defp reference_key(%{id: id}) when is_binary(id), do: {:id, id}
  defp reference_key(%{path: path}), do: {:path, path}

  defp read_reference_sources(active, references) do
    Map.new(references, fn reference ->
      {reference_key(reference), read_reference_source(active, reference)}
    end)
  end

  defp read_reference_source(active, %{path: relative} = reference) do
    components = String.split(relative, "/")

    if Path.type(relative) != :relative ||
         Enum.any?(components, &(&1 in ["", ".", ".."])) do
      {:error, "The poem reference must stay inside the writing folder."}
    else
      query = from(e in Entry, where: e.collection_scope == ^active.scope and not e.trashed)

      entry =
        if reference[:id],
          do: Repo.one(from(e in query, where: e.file_id == ^reference.id)),
          else: Repo.one(from(e in query, where: e.relative_path == ^relative))

      with %Entry{pending: nil} <- entry,
           {:ok, path} <- safe_path(active.folder, entry.relative_path),
           {:ok, document} <- TextFile.read(path),
           identity <- file_identity(path),
           true <-
             is_nil(entry.source["file_identity"]) || entry.source["file_identity"] == identity,
           {:ok, refreshed} <-
             refresh_reference_entry(entry, document, identity) do
        {:ok, piece(refreshed, active)}
      else
        _ -> {:error, "Source unavailable. Reopen Saved writing to reconnect a moved poem."}
      end
    end
  end

  defp refresh_reference_entry(entry, document, identity) do
    if entry.file_token == document.token && not entry.file_missing do
      {:ok, entry}
    else
      Repo.transaction(fn ->
        refresh_entry(entry, %{
          relative: entry.relative_path,
          document: document,
          identity: identity
        })
      end)
    end
  end

  defp snapshot_pieces(location, opts) do
    active = Storage.collection_location()
    recover? = Keyword.get(opts, :recover, false)

    cond do
      not active.configured or not active.available ->
        :none

      not is_map(location) or location[:scope] != active.scope ->
        :none

      true ->
        case Still.Writing.Discovery.current(active, recover: recover?) do
          {:ok, scope} ->
            case Still.Writing.Discovery.problem(active) do
              nil ->
                if scope == active.scope do
                  pieces =
                    rows(scope, false)
                    |> Enum.reject(& &1.file_missing)
                    |> Enum.map(&piece(&1, active))

                  {:ok, pieces}
                else
                  :none
                end

              message ->
                {:error, message}
            end

          _ ->
            :none
        end
    end
  end

  def synchronize(location, opts \\ []) do
    with_location(location, fn active ->
      with {:ok, _files} <- refresh_projection(active, Keyword.get(opts, :recover, true)) do
        {:ok, active |> rows_for() |> visible_pieces(active)}
      end
    end)
  end

  @doc "One verified refresh for the Saved writing list and its reconnection choices."
  def saved_writing(location) do
    with_location(location, fn active ->
      with {:ok, files} <- refresh_projection(active, true) do
        entries = rows_for(active)

        {:ok,
         %{
           pieces: visible_pieces(entries, active),
           reconciliation: reconciliation_for(entries, files, active)
         }}
      end
    end)
  end

  defp refresh_projection(active, recover?) do
    with :ok <- recover_pending(active, recover?),
         {:ok, files} <- scan(active.folder),
         :ok <- discover_notebooks(active, files),
         {:ok, _} <- reconcile(active, files),
         do: {:ok, files}
  end

  defp rows_for(active), do: rows(active.scope, false)

  defp visible_pieces(entries, active) do
    entries
    |> Enum.reject(& &1.file_missing)
    |> Enum.map(&piece(&1, active))
  end

  def get(location, id) do
    active = Storage.collection_location()

    if active.available and is_map(location) and location[:scope] == active.scope and
         Still.Writing.Discovery.current(active) == {:ok, active.scope} do
      case Repo.get_by(Entry,
             file_id: id,
             collection_scope: active.scope,
             file_missing: false,
             trashed: false
           ) do
        nil -> missing_file()
        entry -> {:ok, piece(entry, active)}
      end
    else
      get_refreshed(location, id)
    end
  end

  defp get_refreshed(location, id) do
    with {:ok, pieces} <- synchronize(location) do
      case Enum.find(pieces, &(&1.id == id)) do
        nil ->
          missing_file()

        found ->
          {:ok, found}
      end
    end
  end

  defp missing_file do
    {:error,
     "This file is missing or set aside. Reconnect a moved file from Saved writing; its earlier words remain in SQLite."}
  end

  def revisions(location, id) do
    with_location(location, fn active ->
      case Repo.get_by(Entry, file_id: id, collection_scope: active.scope) do
        nil ->
          {:error, "This writing is no longer indexed."}

        entry ->
          versions =
            Repo.all(from(v in Version, where: v.entry_id == ^entry.id, order_by: [desc: v.id]))

          {:ok,
           Enum.map(versions, fn v ->
             %{
               id: v.id,
               body: v.body,
               title: v.title,
               title_line: v.title_line,
               title_in_body: true,
               created_at: DateTime.to_iso8601(v.inserted_at),
               updated_at: DateTime.to_iso8601(v.inserted_at)
             }
           end)}
      end
    end)
  end

  def save(location, existing, attrs) when is_map(existing) and is_map(attrs) do
    with_location(location, fn active ->
      with :ok <- recover_pending(active, true),
           {:ok, body, line} <- desired_text(existing, attrs),
           {:ok, doc} <- TextFile.decode(body),
           {:ok, role} <- role_for(doc, line),
           {:ok, entry} <- open_snapshot(active, existing),
           {:ok, attrs} <- number_new_list(active, entry, existing, attrs),
           {:ok, relative} <-
             destination(
               active,
               entry,
               existing,
               Map.put(
                 attrs,
                 :filename_label,
                 (role && role.text) || first_filename_line(doc.body)
               )
             ),
           {:ok, path} <- safe_path(active.folder, relative),
           :ok <- fresh_disk(entry, path),
           {:ok, metadata} <- notebook_metadata(entry, existing, attrs, active, relative),
           {:ok, metadata} <- renumber_target(active, entry, metadata),
           metadata <-
             Map.put(
               metadata,
               :historical_source,
               attrs[:historical_source] || (entry && entry.source["historical_source"])
             ),
           {:ok, prepared} <- prepare(active, entry, existing.id, relative, doc, role, metadata),
           {:ok, finished} <- complete_pending(active, prepared) do
        {:ok, piece(finished, active)}
      end
    end)
  end

  def save(_, _, _), do: {:error, "The writing data is invalid."}

  def save_location(location, relative \\ nil) do
    explicit? = is_binary(relative) and relative != ""

    notebook =
      if location.available do
        if explicit?,
          do: closest_notebook(location.scope, relative),
          else: Still.Writing.Notebooks.current()
      end

    folder =
      cond do
        explicit? -> Path.dirname(relative)
        notebook -> Still.Writing.NotebookSections.destination(notebook)
        true -> "."
      end

    folder = if is_binary(folder), do: folder, else: "."

    section =
      if notebook do
        key = file_section_key(notebook, Path.join(folder, "page.txt"))

        Still.Writing.NotebookSections.label(
          notebook.key,
          key,
          if(folder == notebook.relative_path, do: notebook.label, else: Path.basename(folder))
        )
      end

    path_number =
      if explicit? && notebook && notebook.numbered,
        do: elem(filename_order(Path.basename(relative)), 0)

    %{
      folder: folder,
      notebook: notebook && notebook.label,
      section: section,
      number:
        if(notebook && notebook.numbered, do: path_number || next_label(location.scope, notebook))
    }
  end

  def proposed_path(location, body) do
    filename = filename_from_label(first_filename_line(body))
    filename = if location.number, do: location.number <> "_" <> filename, else: filename
    if location.folder == ".", do: filename, else: Path.join(location.folder, filename)
  end

  defp infer_path_notebook(active, nil, %{notebook_from_path: true, relative_path: path} = attrs)
       when is_binary(path) and path != "" do
    notebook = closest_notebook(active.scope, path)
    Map.put(attrs, :notebook_id, notebook && notebook.id)
  end

  defp infer_path_notebook(_, _, attrs), do: attrs

  def save_to_scratch(location, %{token: nil} = existing, attrs) do
    with_location(location, fn active ->
      with {:ok, notebook} <- scratch_notebook(active) do
        attrs =
          Map.merge(attrs, %{
            notebook_id: notebook.id,
            relative_path: nil,
            list_label: nil,
            source_order: nil
          })

        save(active, existing, attrs)
      end
    end)
  end

  def save_to_scratch(_, _, _),
    do: {:error, "This page is already saved. Start a new page to save to Scratch."}

  defp scratch_notebook(active) do
    record =
      Repo.get_by(Still.LocalRecord, scope: active.scope, kind: "scratch", record_key: "notebook")

    notebook = if record, do: Repo.get(Notebook, record.data["notebook_id"])

    cond do
      notebook && notebook.collection_scope == active.scope && not notebook.numbered ->
        with {:ok, _} <- safe_directory(active.folder, notebook.relative_path),
             true <- File.dir?(Path.join(active.folder, notebook.relative_path)) do
          {:ok, notebook}
        else
          _ -> {:error, "The Scratch folder is unavailable. Reconnect it before saving."}
        end

      record ->
        {:error, "The Scratch folder is unavailable. Reconnect it before saving."}

      true ->
        with {:ok, notebook} <-
               create_folder(active, "Scratch", %{label: "Scratch", numbered: false}),
             {:ok, _} <-
               Repo.insert(%Still.LocalRecord{
                 scope: active.scope,
                 kind: "scratch",
                 record_key: "notebook",
                 data: %{"notebook_id" => notebook.id}
               }) do
          {:ok, notebook}
        end
    end
  end

  def set_title_role(location, existing, line),
    do: save(location, existing, %{body: existing.body, title_line: line})

  def pending_save?(scope) do
    Repo.all(
      from(e in Entry,
        where: e.collection_scope == ^scope and not is_nil(e.pending),
        select: e.pending
      )
    )
    |> Enum.any?(&is_map/1)
  end

  def pending_recovery(location) do
    with_location(location, fn active ->
      entries =
        Repo.all(from(e in Entry, where: e.collection_scope == ^active.scope))
        |> Enum.filter(&is_map(&1.pending))

      {:ok,
       Enum.map(entries, fn e ->
         current =
           with {:ok, path} <- safe_path(active.folder, e.relative_path), do: TextFile.read(path)

         %{
           id: e.file_id,
           path: e.relative_path,
           proposed_body: e.pending["body"] || e.body,
           current_body:
             case current do
               {:ok, d} -> d.body
               _ -> ""
             end,
           problem:
             if(match?({:ok, _}, current),
               do: nil,
               else:
                 "The current file is unavailable or unsupported; reconnect it before resolving."
             )
         }
       end)}
    end)
  end

  def resolve_pending(location, id, choice) when choice in ["keep_file", "use_proposed"] do
    with_location(location, fn active ->
      with %Entry{pending: pending} = e when is_map(pending) <-
             Repo.get_by(Entry, file_id: id, collection_scope: active.scope),
           true <- pending["kind"] == "save",
           {:ok, path} <- safe_path(active.folder, e.relative_path),
           {:ok, current} <- TextFile.read(path),
           :ok <- cleanup_stage(path, pending) do
        result =
          Repo.transaction(fn ->
            Repo.insert!(%Version{
              entry_id: e.id,
              body: current.body,
              file_prefix: current.prefix
            })

            Repo.insert!(%Version{
              entry_id: e.id,
              body: pending["body"],
              title: pending["title_anchor"],
              title_line: pending["title_line"],
              title_anchor: pending["title_anchor"],
              file_prefix: Base.decode64!(pending["prefix"])
            })

            attrs =
              if choice == "keep_file" do
                %{
                  pending: nil,
                  body: current.body,
                  file_prefix: current.prefix,
                  file_token: current.token,
                  title_needs_review: not is_nil(e.title_line),
                  file_missing: false
                }
              else
                %{pending: Map.put(pending, "old_token", current.token)}
              end

            e |> Changeset.change(attrs) |> persist!()
          end)

        with {:ok, prepared} <- result,
             {:ok, finished} <- complete_pending(active, prepared),
             do: {:ok, piece(finished, active)}
      else
        _ -> {:error, "Reconnect the current readable file before choosing which words to keep."}
      end
    end)
  end

  def discovery_scope do
    location = Storage.collection_location()

    case discovery_result(location) do
      {:ok, scope} -> scope
      {:error, _} -> nil
    end
  end

  def discovery_result(location) do
    case Still.Writing.Discovery.current(location) do
      {:ok, scope} ->
        case Still.Writing.Discovery.problem(location) do
          nil -> {:ok, scope}
          message -> {:error, message}
        end

      :none ->
        cond do
          not location.configured ->
            {:ok, nil}

          not location.available ->
            {:error, location.error || "The selected writing folder is unavailable."}

          true ->
            case synchronize(location, recover: false) do
              {:ok, _} -> {:ok, location.scope}
              {:error, message} -> {:error, message}
            end
        end
    end
  end

  defp desired_text(existing, attrs) do
    body = attrs[:body]

    if is_binary(body) do
      line =
        if Map.has_key?(attrs, :title_line),
          do: number(attrs.title_line),
          else: existing[:title_line]

      title = attrs[:title]

      cond do
        Map.has_key?(attrs, :title_line) or title in [nil, ""] ->
          {:ok, body, line}

        not is_binary(title) or String.contains?(title, ["\n", "\r"]) ->
          {:error, "A title must be one line of text."}

        true ->
          {:ok, title <> "\n\n" <> body, 1}
      end
    else
      {:error, "Writing must be readable UTF-8 text."}
    end
  end

  defp number(nil), do: nil
  defp number(""), do: nil
  defp number(n) when is_integer(n), do: n

  defp number(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> :invalid
    end
  end

  defp number(_), do: :invalid
  defp role_for(_, nil), do: {:ok, nil}

  defp role_for(doc, line) do
    case TextFile.mark_title(doc, line) do
      {:ok, role} ->
        {:ok, role}

      _ ->
        {:error, "Choose a nonblank physical line as the title, or leave the title role empty."}
    end
  end

  defp open_snapshot(_active, %{token: nil, id: id}) do
    if Ecto.UUID.cast(id) != :error and is_nil(Repo.get_by(Entry, file_id: id)),
      do: {:ok, nil},
      else: {:error, "This writing identifier already exists. Reopen it before saving."}
  end

  defp open_snapshot(active, %{id: id, token: token}) do
    case Repo.get_by(Entry, file_id: id, collection_scope: active.scope) do
      %Entry{} = entry ->
        if snapshot_token(entry) == token and not entry.trashed and not entry.file_missing,
          do: {:ok, entry},
          else: stale()

      _ ->
        stale()
    end
  end

  defp open_snapshot(_, _), do: stale()

  defp selected_notebook_id(existing, attrs) do
    cond do
      Map.has_key?(attrs, :notebook_id) -> number(attrs[:notebook_id])
      existing[:notebook_id] -> number(existing[:notebook_id])
      true -> Map.get(Still.Writing.Notebooks.current() || %{}, :id)
    end
  end

  defp number_new_list(_active, %Entry{}, _existing, attrs), do: {:ok, attrs}

  defp number_new_list(active, nil, existing, attrs) do
    with {:ok, _} <- synchronize(active) do
      attrs = infer_path_notebook(active, nil, attrs)
      relative = attrs[:relative_path] || existing[:relative_path]

      nearest =
        if is_binary(relative) and relative != "", do: closest_notebook(active.scope, relative)

      id = selected_notebook_id(existing, attrs) || (nearest && nearest.id)
      notebook = if is_integer(id), do: Repo.get(Notebook, id)
      label = attrs[:list_label] || existing[:list_label]
      order = number(attrs[:source_order] || existing[:source_order])

      {path_label, _} =
        if is_binary(relative) and (is_nil(notebook) or notebook.numbered),
          do: filename_order(Path.basename(relative)),
          else: {nil, nil}

      label = if label in [nil, ""], do: path_label, else: label
      label = if label in [nil, ""] and is_integer(order), do: to_string(order), else: label

      label =
        if (label in [nil, ""] and notebook) && notebook.numbered,
          do: next_label(active.scope, notebook),
          else: label

      if label not in [nil, ""] and not valid_list_label?(label) do
        {:error, "Use a List number such as 12, 0012, 12a, or 12.1."}
      else
        order =
          if is_nil(order) and label not in [nil, ""],
            do: elem(filename_order(label), 1),
            else: order

        {:ok, attrs |> Map.put(:list_label, label) |> Map.put(:source_order, order)}
      end
    end
  end

  defp valid_list_label?(label),
    do:
      is_binary(label) and Regex.match?(~r/^\d+(?:\.\d+)*[A-Za-z]*$/u, label) and
        byte_size(label) <= 80

  defp next_label(scope, notebook) do
    entries =
      Repo.all(
        from e in Entry,
          where:
            not e.trashed and (e.collection_scope == ^scope or is_nil(e.collection_scope)) and
              (e.notebook_id == ^notebook.id or
                 (is_nil(e.notebook_id) and e.notebook == ^notebook.key))
      )

    {last, width} =
      Enum.reduce(entries, {0, 1}, fn entry, {highest, width} ->
        digits =
          case Regex.run(~r/^\d+/, entry.list_label || "") do
            [digits] -> digits
            _ -> if is_integer(entry.source_order), do: to_string(entry.source_order), else: "0"
          end

        value = String.to_integer(digits)

        cond do
          value > highest -> {value, String.length(digits)}
          value == highest -> {highest, max(width, String.length(digits))}
          true -> {highest, width}
        end
      end)

    Integer.to_string(last + 1) |> String.pad_leading(width, "0")
  end

  defp renumber_target(_active, nil, metadata), do: {:ok, metadata}

  defp renumber_target(active, entry, metadata) do
    label = metadata.list_label

    if label not in [nil, ""] and label != entry.list_label do
      if valid_list_label?(label) do
        basename = Path.basename(entry.relative_path)
        {file_label, _} = filename_order(basename)

        basename =
          if entry.list_label && file_label == entry.list_label,
            do: Regex.replace(~r/^#{Regex.escape(entry.list_label)}[_. -]*/u, basename, ""),
            else: basename

        dirname = Path.dirname(entry.relative_path)

        target =
          if dirname == ".",
            do: label <> "_" <> basename,
            else: Path.join(dirname, label <> "_" <> basename)

        with {:ok, path} <- safe_path(active.folder, target), :ok <- fresh_disk(nil, path) do
          {:ok, Map.put(metadata, :rename_target, target)}
        end
      else
        {:error, "Use a List number such as 12, 0012, 12a, or 12.1."}
      end
    else
      {:ok, metadata}
    end
  end

  defp destination(_, %Entry{} = entry, _, _), do: {:ok, entry.relative_path}

  defp destination(active, nil, existing, attrs) do
    case attrs[:relative_path] || existing[:relative_path] do
      path when path in [nil, ""] ->
        notebook_id = selected_notebook_id(existing, attrs)

        notebook = if is_integer(notebook_id), do: Repo.get(Notebook, notebook_id)

        base =
          cond do
            notebook && notebook.collection_scope == active.scope ->
              Still.Writing.NotebookSections.destination(notebook)

            notebook && is_nil(notebook.collection_scope) ->
              nil

            notebook_id ->
              :unavailable

            true ->
              nil
          end

        if base == :unavailable do
          {:error, "The selected notebook folder is unavailable. Reconnect it before saving."}
        else
          filename = filename_from_label(attrs[:filename_label])

          filename =
            if attrs[:list_label] in [nil, ""],
              do: filename,
              else: attrs[:list_label] <> "_" <> filename

          name = if is_nil(base), do: filename, else: Path.join(base, filename)
          free_name(active.folder, name, 1)
        end

      path when is_binary(path) ->
        {:ok, path}

      _ ->
        {:error, "Choose a relative filename inside the selected folder."}
    end
  end

  defp first_filename_line(body) do
    body
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.find("", fn line ->
      String.trim(line) != "" &&
        not (String.starts_with?(line, "[[poem: ") &&
               Enum.any?(Still.Writing.PoemReferences.parse(line), &(&1.kind == :reference)))
    end)
  end

  defp filename_from_label(label) do
    stem =
      (label || "")
      |> String.replace(~r/[\x00-\x1F\x7F\/\\*?"<>|]/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.trim(".")
      |> String.replace(~r/ *: */u, "_")
      |> String.replace(" ", "_")
      |> String.codepoints()
      |> Enum.reduce_while("", fn char, acc ->
        if byte_size(acc <> char) <= 180, do: {:cont, acc <> char}, else: {:halt, acc}
      end)
      |> String.trim()

    if(stem == "", do: "Untitled", else: stem) <> ".txt"
  end

  @doc "Rename a saved file within its folder, preserving its identity and history."
  def rename(location, existing, filename) do
    with_location(location, fn active ->
      with :ok <- recover_pending(active, true),
           {:ok, entry} <- open_snapshot(active, existing),
           true <- not is_nil(entry),
           true <-
             is_binary(filename) and String.trim(filename) != "" and
               Path.basename(filename) == filename and filename not in [".", ".."] and
               String.downcase(Path.extname(filename)) != ".gdoc" and
               not Regex.match?(~r/[\x00-\x1F\x7F]/u, filename) and
               not String.contains?(filename, ["/", "\\", "\n", "\r", <<0>>]),
           relative =
             if(Path.dirname(entry.relative_path) == ".",
               do: filename,
               else: Path.join(Path.dirname(entry.relative_path), filename)
             ),
           {:ok, old_path} <- safe_path(active.folder, entry.relative_path),
           {:ok, target} <- safe_path(active.folder, relative),
           :ok <- fresh_disk(entry, old_path) do
        if relative == entry.relative_path do
          {:ok, piece(entry, active)}
        else
          with :ok <- fresh_disk(nil, target),
               prepared <-
                 entry
                 |> Changeset.change(
                   pending: %{
                     "kind" => "rename",
                     "target" => relative,
                     "identity" => file_identity(old_path)
                   }
                 )
                 |> persist!(),
               {:ok, finished} <- complete_pending(active, prepared) do
            {:ok, piece(finished, active)}
          end
        end
      else
        false -> {:error, "Choose a file name within this writing's current folder."}
        error -> error
      end
    end)
  end

  defp free_name(root, base, n) do
    name = if n == 1, do: base, else: Path.rootname(base) <> "_#{n}" <> Path.extname(base)
    if File.exists?(Path.join(root, name)), do: free_name(root, base, n + 1), else: {:ok, name}
  end

  defp notebook_metadata(entry, existing, attrs, active, relative) do
    id =
      cond do
        Map.has_key?(attrs, :notebook_id) -> number(attrs[:notebook_id])
        entry -> entry.notebook_id
        true -> number(existing[:notebook_id])
      end

    nearest = if is_nil(entry), do: closest_notebook(active.scope, relative)

    id =
      cond do
        is_nil(entry) and is_nil(id) and nearest ->
          nearest.id

        is_nil(entry) and is_nil(id) and not Map.has_key?(attrs, :notebook_id) ->
          Map.get(Still.Writing.Notebooks.current() || %{}, :id)

        true ->
          id
      end

    notebook = if is_integer(id), do: Repo.get(Notebook, id)

    order =
      if Map.has_key?(attrs, :source_order),
        do: number(attrs[:source_order]),
        else: entry && entry.source_order

    label =
      if Map.has_key?(attrs, :list_label), do: attrs[:list_label], else: entry && entry.list_label

    order =
      if label not in [nil, ""] and valid_list_label?(label) and
           (is_nil(order) or (entry && label != entry.list_label && order == entry.source_order)),
         do: elem(filename_order(label), 1),
         else: order

    cond do
      entry && id != entry.notebook_id ->
        {:error,
         "This writing is already in a file. Move it into the chosen notebook folder in your file manager, then reopen it."}

      is_nil(entry) and not is_nil(nearest) and not is_nil(id) and nearest.id != id ->
        {:error,
         "The chosen file folder belongs to a different notebook. Choose a path inside that notebook or clear the notebook selection."}

      is_nil(entry) and not is_nil(nearest) and is_nil(id) and Map.has_key?(attrs, :notebook_id) ->
        {:error,
         "The chosen file folder belongs to a notebook. Keep that notebook selected or choose a folder outside it."}

      is_nil(entry) and not is_nil(notebook) and notebook.collection_scope == active.scope and
          (is_nil(nearest) or nearest.id != notebook.id) ->
        {:error,
         "The selected notebook folder is unavailable for this file path. Save inside its folder."}

      id && is_nil(notebook) ->
        {:error, "Choose an existing notebook or no notebook."}

      order == :invalid or (is_integer(order) and order > 9_223_372_036_854_775_807) ->
        {:error, "List order must be a positive number, or empty."}

      not is_nil(label) and not is_binary(label) ->
        {:error, "The List label must be text."}

      true ->
        {:ok,
         %{
           notebook_id: id,
           notebook:
             if(notebook, do: file_section_key(notebook, relative), else: entry && entry.notebook),
           source_order: order,
           list_label: label
         }}
    end
  end

  defp fresh_disk(nil, path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      _ ->
        {:error, "That filename is occupied. Choose another; its contents were left untouched."}
    end
  end

  defp fresh_disk(entry, path) do
    with {:ok, doc} <- TextFile.read(path), true <- doc.token == entry.file_token do
      :ok
    else
      _ -> stale()
    end
  end

  defp prepare(active, entry, id, relative, doc, role, metadata) do
    same? =
      entry && entry.body == doc.body && entry.title_line == (role && role.line) &&
        entry.title_anchor == (role && role.text) && not entry.title_needs_review &&
        Map.take(entry, [:notebook_id, :notebook, :source_order, :list_label]) ==
          Map.take(metadata, [:notebook_id, :notebook, :source_order, :list_label]) &&
        entry.source["historical_source"] == metadata[:historical_source] && not entry.trashed

    if same? do
      {:ok, entry}
    else
      Repo.transaction(fn ->
        if entry, do: checkpoint(entry)

        entry =
          entry ||
            %Entry{file_id: id, collection_scope: active.scope, body: "", relative_path: relative}

        prefix = if entry.file_token, do: entry.file_prefix || "", else: doc.prefix

        pending = %{
          "kind" => "save",
          "stage" => ".still-#{Ecto.UUID.generate()}.partial",
          "old_token" => entry.file_token,
          "body" => doc.body,
          "prefix" => Base.encode64(prefix),
          "title_line" => role && role.line,
          "title_anchor" => role && role.text,
          "metadata" => Map.new(metadata, fn {k, v} -> {Atom.to_string(k), v} end)
        }

        entry |> Changeset.change(pending: pending) |> persist!()
      end)
    end
  end

  defp checkpoint(entry) do
    Repo.insert!(%Version{
      entry_id: entry.id,
      title: entry.title,
      body: entry.body,
      title_line: entry.title_line,
      title_anchor: entry.title_anchor,
      file_prefix: entry.file_prefix
    })
  end

  defp persist!(%Changeset{data: %{id: nil}} = change), do: Repo.insert!(change)
  defp persist!(change), do: change |> Changeset.optimistic_lock(:lock_version) |> Repo.update!()

  defp recover_pending(active, recover?) do
    pending =
      Repo.all(
        from(e in Entry,
          where: e.collection_scope == ^active.scope and not is_nil(e.pending)
        )
      )
      |> Enum.filter(&is_map(&1.pending))

    cond do
      pending == [] ->
        :ok

      not recover? ->
        {:error, "An interrupted save needs recovery. Open Saved writing before continuing."}

      true ->
        Enum.reduce_while(pending, :ok, fn e, _ ->
          case complete_pending(active, e) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp complete_pending(_active, %{pending: nil} = entry), do: {:ok, entry}

  defp complete_pending(active, %{pending: %{"kind" => kind} = p} = entry) do
    with :ok <- same_location(active),
         {:ok, path} <- safe_path(active.folder, entry.relative_path) do
      case kind do
        "save" ->
          bytes = Base.decode64!(p["prefix"]) <> p["body"]
          {:ok, desired} = TextFile.decode(bytes)
          current = TextFile.read(path)

          current_token =
            case current do
              {:ok, doc} -> doc.token
              _ -> nil
            end

          result =
            cond do
              current_token == desired.token ->
                :ok

              current_token && current_token == p["old_token"] ->
                publish(path, bytes, false, p)

              current == {:error, :enoent} and is_nil(p["old_token"]) ->
                publish(path, bytes, true, p)

              true ->
                {:error,
                 "An interrupted save conflicts with an external change. Proposed and earlier words remain in SQLite; the file was left untouched."}
            end

          with :ok <- result,
               {:ok, verified} <- TextFile.read(path),
               true <- verified.token == desired.token,
               :ok <- cleanup_stage(path, p) do
            attrs = %{
              body: verified.body,
              file_prefix: verified.prefix,
              file_token: verified.token,
              title_line: p["title_line"],
              title_anchor: p["title_anchor"],
              title: p["title_anchor"],
              title_needs_review: false,
              file_missing: false,
              trashed: false,
              pending: nil,
              source:
                (entry.source || %{})
                |> Map.put("file_identity", file_identity(path))
                |> Map.put("historical_source", p["metadata"]["historical_source"])
            }

            attrs =
              Enum.reduce(~w(notebook_id notebook source_order list_label), attrs, fn name, a ->
                Map.put(a, String.to_existing_atom(name), p["metadata"][name])
              end)

            attrs =
              if target = p["metadata"]["rename_target"] do
                Map.put(attrs, :pending, %{
                  "kind" => "rename",
                  "target" => target,
                  "identity" => file_identity(path)
                })
              else
                attrs
              end

            complete_pending(active, entry |> Changeset.change(attrs) |> persist!())
          else
            false -> stale()
            error -> error
          end

        "rename" ->
          with {:ok, target} <- safe_path(active.folder, p["target"]),
               :ok <- publish_rename(path, target, entry, p),
               :ok <- sync_dir(Path.dirname(path)) do
            {:ok,
             entry |> Changeset.change(relative_path: p["target"], pending: nil) |> persist!()}
          end

        "trash" ->
          case TextFile.read(path) do
            {:error, :enoent} ->
              finish_trash(entry)

            {:ok, %{token: token}} when token == entry.file_token ->
              with :ok <- File.rm(path),
                   :ok <- sync_dir(Path.dirname(path)),
                   do: finish_trash(entry)

            _ ->
              stale()
          end

        "permanent_delete" ->
          case TextFile.read(path) do
            {:error, :enoent} ->
              with :ok <- sync_dir(Path.dirname(path)), do: finish_permanent_delete(entry)

            {:ok, %{token: token}} when token == entry.file_token ->
              if file_identity(path) == p["identity"] and
                   p["identity"] == (entry.source || %{})["file_identity"] do
                with :ok <- File.rm(path),
                     :ok <- sync_dir(Path.dirname(path)),
                     do: finish_permanent_delete(entry)
              else
                stale()
              end

            _ ->
              stale()
          end
      end
    end
  end

  defp publish_rename(path, target, entry, pending) do
    source = TextFile.read(path)
    destination = TextFile.read(target)
    identity = pending["identity"]

    cond do
      source == {:error, :enoent} and
        match?({:ok, %{token: token}} when token == entry.file_token, destination) and
          file_identity(target) == identity ->
        :ok

      match?({:ok, %{token: token}} when token == entry.file_token, source) and
          file_identity(path) == identity ->
        linked =
          case File.lstat(target) do
            {:error, :enoent} -> File.ln(path, target)
            {:ok, _} -> if(file_identity(target) == identity, do: :ok, else: {:error, :eexist})
            error -> error
          end

        with :ok <- linked,
             :ok <- fresh_disk(entry, path),
             :ok <- fresh_disk(entry, target),
             :ok <- File.rm(path),
             do: :ok

      true ->
        {:error,
         "The file changed during renaming. Reopen Saved writing to review it; no other file was replaced."}
    end
  end

  defp finish_trash(entry),
    do: {:ok, entry |> Changeset.change(trashed: true, pending: nil) |> persist!()}

  defp finish_permanent_delete(entry) do
    case Repo.transaction(fn ->
           Repo.delete_all(from(v in Version, where: v.entry_id == ^entry.id))
           Repo.delete!(entry)
           :deleted
         end) do
      {:ok, :deleted} -> {:ok, :deleted}
      error -> error
    end
  end

  defp publish(path, bytes, exclusive?, pending) do
    name = pending["stage"] || ".still-#{Ecto.UUID.generate()}.partial"

    if is_binary(name) and Regex.match?(~r/^\.still-[0-9a-f-]{36}\.partial$/, name) do
      pending = Map.put(pending, "stage", name)
      temp = Path.join(Path.dirname(path), name)

      try do
        with :ok <- cleanup_stage(path, pending),
             {:ok, handle} <- File.open(temp, [:write, :exclusive, :binary]) do
          result =
            try do
              with :ok <- IO.binwrite(handle, bytes), do: :file.sync(handle)
            after
              File.close(handle)
            end

          with :ok <- result,
               :ok <- File.chmod(temp, mode(path)),
               :ok <- if(exclusive?, do: :ok, else: fresh_token(path, pending["old_token"])),
               :ok <- if(exclusive?, do: File.ln(temp, path), else: File.rename(temp, path)),
               :ok <- sync_dir(Path.dirname(path)),
               do: :ok
        end
      after
        cleanup_stage(path, pending)
      end
    else
      {:error, "The interrupted save staging name is invalid; all files were left untouched."}
    end
  end

  defp cleanup_stage(_path, %{"stage" => nil}), do: :ok

  defp cleanup_stage(path, %{"stage" => name} = pending) when is_binary(name) do
    if Regex.match?(~r/^\.still-[0-9a-f-]{36}\.partial$/, name) do
      temp = Path.join(Path.dirname(path), name)
      bytes = Base.decode64!(pending["prefix"]) <> pending["body"]

      case File.lstat(temp) do
        {:error, :enoent} ->
          :ok

        {:ok, %{type: :regular}} ->
          with {:ok, partial} <- File.read(temp),
               true <- byte_size(partial) <= byte_size(bytes),
               true <- binary_part(bytes, 0, byte_size(partial)) == partial,
               do: File.rm(temp),
               else: (_ ->
                        {:error,
                         "An interrupted staging file has unfamiliar contents; it was left untouched."})

        _ ->
          {:error, "An interrupted staging path is unsafe; it was left untouched."}
      end
    else
      {:error, "The interrupted save staging name is invalid."}
    end
  end

  defp cleanup_stage(_path, _), do: :ok

  defp mode(path) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o777)
      _ -> 0o600
    end
  end

  defp fresh_token(path, token) do
    case TextFile.read(path) do
      {:ok, %{token: ^token}} -> :ok
      _ -> stale()
    end
  end

  defp scan(root), do: walk(root, "", [])

  defp walk(root, relative, acc) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        with {:ok, names} <- File.ls(path) do
          names
          |> Enum.sort()
          |> Enum.reduce_while({:ok, acc}, fn name, {:ok, gathered} ->
            if name == ".DS_Store" or
                 (name == "still-backup.sqlite3" and database_backup?(Path.join(path, name))) do
              {:cont, {:ok, gathered}}
            else
              case walk(root, Path.join(relative, name), gathered) do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end
            end
          end)
        end

      {:ok, %{type: :regular}} ->
        case TextFile.read(path) do
          {:ok, doc} ->
            {:ok, [%{relative: relative, document: doc, identity: file_identity(path)} | acc]}

          {:error, reason} ->
            {:error,
             "Cannot read #{relative} as ordinary UTF-8 text (#{inspect(reason)}). Its contents were left untouched."}
        end

      _ ->
        {:error,
         "The file or folder #{relative} is unavailable or a symbolic link. Choose readable local text; nothing was deleted."}
    end
  end

  defp reconcile(active, files) do
    Repo.transaction(fn ->
      old = rows(active.scope, false)

      reserved_paths =
        Repo.all(
          from(e in Entry,
            where: e.collection_scope == ^active.scope and e.trashed,
            select: e.relative_path
          )
        )
        |> MapSet.new()

      if file = Enum.find(files, &MapSet.member?(reserved_paths, &1.relative)) do
        Repo.rollback(
          "A new file occupies the original path of writing in Trash: #{file.relative}. Rename that file before restoring or indexing it; both versions were left untouched."
        )
      end

      matches = reconcile_matches(old, files)
      claimed = matches |> Map.values() |> MapSet.new(& &1.id)
      missing = Enum.reject(old, &MapSet.member?(claimed, &1.id))

      if entry = Enum.find(missing, &Map.has_key?(matches, &1.relative_path)) do
        Repo.rollback(
          "An indexed writing's path now holds a different file: #{entry.relative_path}. Move the present file to an unused filename and reopen Saved writing to review both identities; no writing was changed."
        )
      end

      Enum.each(missing, fn entry ->
        unless entry.file_missing,
          do: entry |> Changeset.change(file_missing: true) |> persist!()
      end)

      # A path swap cannot be updated one row at a time under the unique path
      # index. NULL is transient inside this transaction; the original structs
      # still provide the authored filename and notebook metadata below.
      moved_ids =
        for {relative, entry} <- matches, entry.relative_path != relative, do: entry.id

      if moved_ids != [] do
        Repo.update_all(from(e in Entry, where: e.id in ^moved_ids), set: [relative_path: nil])
      end

      missing_tokens = MapSet.new(missing, & &1.file_token)
      missing_paths = MapSet.new(missing, & &1.relative_path)

      notebooks =
        Repo.all(
          from(n in Notebook,
            where: n.collection_scope == ^active.scope and not is_nil(n.relative_path)
          )
        )

      notebook_ids = old |> Enum.map(& &1.notebook_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      notebooks_by_id =
        Repo.all(from(n in Notebook, where: n.id in ^notebook_ids))
        |> Map.new(&{&1.id, &1})

      Enum.each(files, fn file ->
        case matches[file.relative] do
          %Entry{} = entry ->
            refresh_entry(entry, file, notebooks, notebooks_by_id)

          nil ->
            if MapSet.member?(missing_paths, file.relative) or
                 MapSet.member?(missing_tokens, file.document.token),
               do: :ambiguous,
               else: index_file(active, file, notebooks)
        end
      end)
    end)
  end

  defp reconcile_matches(old, files) do
    by_path = Map.new(old, &{&1.relative_path, &1})

    by_identity =
      old
      |> Enum.filter(&is_binary((&1.source || %{})["file_identity"]))
      |> Enum.group_by(& &1.source["file_identity"])

    identity_counts = Enum.frequencies_by(files, & &1.identity)

    identity_matches =
      Enum.reduce(files, %{}, fn file, acc ->
        case {file.identity, identity_counts[file.identity], by_identity[file.identity]} do
          {identity, 1, [entry]} when is_binary(identity) ->
            Map.put(acc, file.relative, entry)

          _ ->
            acc
        end
      end)

    claimed = identity_matches |> Map.values() |> MapSet.new(& &1.id)

    new_paths_by_token =
      files
      |> Enum.reject(
        &(Map.has_key?(by_path, &1.relative) or Map.has_key?(identity_matches, &1.relative))
      )
      |> Enum.group_by(& &1.document.token, & &1.relative)

    path_evidence = %{
      identity_counts: identity_counts,
      new_paths_by_token: new_paths_by_token,
      old_by_token: Enum.group_by(old, & &1.file_token),
      files_by_path: Map.new(files, &{&1.relative, &1})
    }

    Enum.reduce(files, identity_matches, fn file, acc ->
      entry = by_path[file.relative]

      if not Map.has_key?(acc, file.relative) and not is_nil(entry) and
           not MapSet.member?(claimed, entry.id) and
           path_fallback?(entry, file, path_evidence) do
        Map.put(acc, file.relative, entry)
      else
        acc
      end
    end)
  end

  defp path_fallback?(entry, file, evidence) do
    old_identity = (entry.source || %{})["file_identity"]

    cond do
      is_binary(old_identity) and old_identity == file.identity ->
        true

      entry.file_missing ->
        false

      is_binary(old_identity) and Map.get(evidence.identity_counts, old_identity, 0) > 0 ->
        false

      displaced_words?(entry, file, evidence) ->
        false

      file.document.token != entry.file_token and
          Map.get(evidence.new_paths_by_token, entry.file_token, []) != [] ->
        false

      true ->
        true
    end
  end

  defp displaced_words?(entry, file, evidence) do
    Enum.any?(Map.get(evidence.old_by_token, file.document.token, []), fn other ->
      other.id != entry.id and
        case evidence.files_by_path[other.relative_path] do
          nil -> true
          current -> current.document.token != other.file_token
        end
    end)
  end

  defp index_file(active, file) do
    notebooks =
      Repo.all(
        from(n in Notebook,
          where: n.collection_scope == ^active.scope and not is_nil(n.relative_path)
        )
      )

    index_file(active, file, notebooks)
  end

  defp index_file(active, file, notebooks) do
    notebook = closest_notebook(notebooks, file.relative)
    {label, order} = notebook_file_number(notebook, file.relative)
    section_key = file_section_key(notebook, file.relative)

    Repo.insert!(%Entry{
      file_id: Ecto.UUID.generate(),
      collection_scope: active.scope,
      relative_path: file.relative,
      body: file.document.body,
      file_prefix: file.document.prefix,
      file_token: file.document.token,
      notebook_id: notebook && notebook.id,
      notebook: section_key,
      list_label: label,
      source_order: order,
      source: %{"file_identity" => file.identity}
    })
  end

  defp refresh_entry(entry, file) do
    notebooks =
      Repo.all(
        from(n in Notebook,
          where: n.collection_scope == ^entry.collection_scope and not is_nil(n.relative_path)
        )
      )

    prior =
      case entry.notebook_id && Repo.get(Notebook, entry.notebook_id) do
        %Notebook{} = notebook -> %{notebook.id => notebook}
        _ -> %{}
      end

    refresh_entry(entry, file, notebooks, prior)
  end

  defp refresh_entry(entry, file, notebooks, notebooks_by_id) do
    notebook = closest_notebook(notebooks, file.relative)
    prior = notebooks_by_id[entry.notebook_id]

    notebook =
      if prior && is_nil(prior.collection_scope) && entry.relative_path == file.relative,
        do: prior,
        else: notebook

    section_key = file_section_key(notebook, file.relative)
    {found_label, found_order} = notebook_file_number(notebook, file.relative)
    renamed? = Path.basename(entry.relative_path) != Path.basename(file.relative)
    label = if renamed?, do: found_label || entry.list_label, else: entry.list_label
    order = if renamed?, do: found_order || entry.source_order, else: entry.source_order
    changed? = entry.file_token != file.document.token
    if changed?, do: checkpoint(entry)

    if changed? or entry.relative_path != file.relative or entry.file_missing or
         entry.notebook_id != (notebook && notebook.id) or entry.notebook != section_key or
         entry.list_label != label or entry.source_order != order or
         entry.source["file_identity"] != file.identity do
      entry
      |> Changeset.change(
        body: file.document.body,
        file_prefix: file.document.prefix,
        file_token: file.document.token,
        relative_path: file.relative,
        notebook_id: notebook && notebook.id,
        notebook: section_key,
        list_label: label,
        source_order: order,
        file_missing: false,
        title_needs_review:
          entry.title_needs_review or (changed? and not is_nil(entry.title_line)),
        source: Map.put(entry.source || %{}, "file_identity", file.identity)
      )
      |> persist!()
    else
      entry
    end
  end

  defp discover_notebooks(active, files) do
    with {:ok, directories} <- directories(active.folder),
         registered = Repo.all(from(n in Notebook, where: n.collection_scope == ^active.scope)),
         directory_identities <- directory_identities(active.folder, directories),
         {:ok, registered_paths} <-
           reconcile_notebook_directories(active, directories, directory_identities, registered),
         :ok <- discover_unregistered_directories(active, directories, files, registered_paths) do
      :ok
    end
  end

  defp directories(root), do: directories(root, "", [])

  defp directories(root, relative, acc) do
    with {:ok, names} <- File.ls(Path.join(root, relative)) do
      Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, found} ->
        if name == ".DS_Store" do
          {:cont, {:ok, found}}
        else
          path = Path.join(relative, name)

          case File.lstat(Path.join(root, path)) do
            {:ok, %{type: :directory}} ->
              case directories(root, path, [path | found]) do
                {:ok, nested} -> {:cont, {:ok, nested}}
                error -> {:halt, error}
              end

            {:ok, %{type: :regular}} ->
              {:cont, {:ok, found}}

            _ ->
              {:halt,
               {:error,
                "The folder tree contains an unavailable or symbolic path; nothing was removed."}}
          end
        end
      end)
    end
  end

  defp directory_identities(root, directories) do
    Map.new(directories, fn path ->
      {path, directory_identity(Path.join(root, path))}
    end)
  end

  defp reconcile_notebook_directories(active, directories, identities, registered) do
    by_identity =
      Enum.reduce(directories, %{}, fn path, acc ->
        identity = identities[path]

        if identity,
          do: Map.update(acc, identity, path, fn existing -> existing || path end),
          else: acc
      end)

    Enum.reduce_while(registered, {:ok, MapSet.new()}, fn notebook, {:ok, registered_paths} ->
      identity_path = by_identity[notebook.folder_identity]
      path = if identity_path, do: identity_path, else: notebook.relative_path

      if path && path in directories do
        attrs = %{
          collection_scope: active.scope,
          relative_path: path,
          folder_identity: identities[path]
        }

        changeset = Notebook.changeset(notebook, attrs)

        result =
          if changeset.changes == %{} do
            :ok
          else
            case Repo.update(changeset) do
              {:ok, _} -> :ok
              error -> error
            end
          end

        case result do
          :ok -> {:cont, {:ok, MapSet.put(registered_paths, path)}}
          error -> {:halt, error}
        end
      else
        paths =
          if is_binary(notebook.relative_path),
            do: MapSet.put(registered_paths, notebook.relative_path),
            else: registered_paths

        {:cont, {:ok, paths}}
      end
    end)
  end

  defp discover_unregistered_directories(active, directories, files, registered_paths) do
    dirs = Enum.sort_by(directories, &{length(Path.split(&1)), &1})

    Enum.reduce_while(dirs, {:ok, registered_paths}, fn path, {:ok, registered_paths} ->
      under_registered? =
        Enum.any?(registered_paths, fn parent ->
          parent != path and String.starts_with?(path, parent <> "/")
        end)

      direct_files? = Enum.any?(files, &(Path.dirname(&1.relative) == path))

      empty_leaf? =
        not Enum.any?(directories, &String.starts_with?(&1, path <> "/")) and
          not Enum.any?(files, &String.starts_with?(&1.relative, path <> "/"))

      if not under_registered? and not MapSet.member?(registered_paths, path) and
           (direct_files? or empty_leaf?) do
        case register_folder_in(active, path, %{key: path, label: Path.basename(path)}) do
          {:ok, _} -> {:cont, {:ok, MapSet.put(registered_paths, path)}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, registered_paths}}
      end
    end)
    |> case do
      {:ok, _registered_paths} -> :ok
      error -> error
    end
  end

  defp closest_notebook(notebooks, relative) when is_list(notebooks) do
    notebooks
    |> Enum.filter(
      &(relative == &1.relative_path or String.starts_with?(relative, &1.relative_path <> "/"))
    )
    |> Enum.max_by(&length(Path.split(&1.relative_path)), fn -> nil end)
  end

  defp closest_notebook(scope, relative) when is_binary(scope) do
    Repo.all(
      from(n in Notebook,
        where: n.collection_scope == ^scope and not is_nil(n.relative_path)
      )
    )
    |> closest_notebook(relative)
  end

  defp file_section_key(nil, _relative), do: nil
  defp file_section_key(%Notebook{relative_path: nil, key: key}, _relative), do: key

  defp file_section_key(notebook, relative) do
    directory = Path.dirname(relative)

    if directory == notebook.relative_path,
      do: notebook.key,
      else: notebook.key <> String.replace_prefix(directory, notebook.relative_path, "")
  end

  defp notebook_file_number(%Notebook{numbered: false}, _relative), do: {nil, nil}
  defp notebook_file_number(_notebook, relative), do: filename_order(Path.basename(relative))

  defp filename_order(filename) do
    case Regex.run(~r/^(\d+(?:\.\d+)*[A-Za-z]*)(?:\D|$)/u, filename) do
      [_, label] ->
        [digits | _] = Regex.run(~r/^\d+/, label)
        {label, String.to_integer(digits)}

      _ ->
        {nil, nil}
    end
  end

  defp directory_identity(path) do
    case File.stat(path) do
      {:ok, s} -> "#{s.major_device}:#{s.minor_device}:#{s.inode}"
      _ -> nil
    end
  end

  defp safe_directory(root, relative) when is_binary(relative) do
    path = Path.expand(relative, root)
    components = String.split(relative, "/")

    if Path.type(relative) != :relative or path == root or
         not String.starts_with?(path, root <> "/") or
         Enum.any?(components, &(&1 in ["", ".", ".."])) do
      {:error, "Choose a relative folder inside the selected collection."}
    else
      parts = Path.split(Path.relative_to(path, root))

      case safe_directory_ancestors(root, Enum.drop(parts, -1)) do
        :ok ->
          case File.lstat(path) do
            {:ok, %{type: :directory}} -> {:ok, path}
            {:error, :enoent} -> {:ok, path}
            _ -> {:error, "The notebook path is unavailable or symbolic."}
          end

        error ->
          error
      end
    end
  end

  defp safe_directory(_, _), do: {:error, "Choose a relative folder."}

  defp safe_directory_ancestors(_root, []), do: :ok

  defp safe_directory_ancestors(root, parts) do
    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, path} ->
      next = Path.join(path, part)

      case File.lstat(next) do
        {:ok, %{type: :directory}} -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:halt, :ok}
        _ -> {:halt, {:error, "The notebook path contains a symbolic or unavailable parent."}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp folder_error(:eacces), do: "Still cannot create the notebook folder at that location."

  defp folder_error(:enoent),
    do: "A parent folder is unavailable. Choose an existing folder path."

  defp folder_error(:eexist), do: "That notebook folder already exists; register it instead."
  defp folder_error(message) when is_binary(message), do: message

  defp folder_error(reason),
    do: "Still could not create the notebook folder (#{inspect(reason)})."

  defp create_directory_path(root, relative) do
    parts = Path.split(relative)

    Enum.reduce_while(parts, {:ok, root, []}, fn part, {:ok, parent, created} ->
      path = Path.join(parent, part)

      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          {:cont, {:ok, path, created}}

        {:error, :enoent} ->
          case File.mkdir(path) do
            :ok -> {:cont, {:ok, path, [path | created]}}
            {:error, reason} -> {:halt, {:error, reason, created}}
          end

        _ ->
          {:halt, {:error, "A parent notebook path is symbolic or unavailable."}}
      end
    end)
    |> case do
      {:ok, _, created} -> {:ok, created}
      {:error, reason, created} -> {:error, reason, created}
      error -> error
    end
  end

  def reconciliation(location) do
    with_location(location, fn active ->
      with {:ok, files} <- scan(active.folder), {:ok, _} <- reconcile(active, files) do
        {:ok, reconciliation_for(rows_for(active), files, active)}
      end
    end)
  end

  defp reconciliation_for(entries, files, active) do
    missing = Enum.filter(entries, & &1.file_missing)
    claimed = entries |> Enum.reject(& &1.file_missing) |> MapSet.new(& &1.relative_path)

    ambiguous =
      Enum.map(missing, fn e ->
        %{
          id: e.file_id,
          path: e.relative_path,
          candidates:
            files
            |> Enum.filter(
              &(not MapSet.member?(claimed, &1.relative) and &1.document.token == e.file_token)
            )
            |> Enum.map(& &1.relative)
        }
      end)
      |> Enum.reject(&(&1.candidates == []))

    %{missing: Enum.map(missing, &piece(&1, active)), ambiguous: ambiguous}
  end

  def relink(location, id, relative) do
    with_location(location, fn active ->
      with %Entry{file_missing: true} = entry <-
             Repo.get_by(Entry, file_id: id, collection_scope: active.scope),
           {:ok, canonical, path, doc} <- manual_existing_file(active.folder, relative),
           owner <- Repo.get_by(Entry, collection_scope: active.scope, relative_path: canonical),
           true <- is_nil(owner) or owner.id == entry.id do
        case Repo.transaction(fn ->
               refresh_entry(entry, %{
                 relative: canonical,
                 document: doc,
                 identity: file_identity(path)
               })
             end) do
          {:ok, updated} -> {:ok, piece(updated, active)}
          error -> error
        end
      else
        _ ->
          {:error,
           "Choose an unclaimed local file to reconnect this missing writing. No identities were merged."}
      end
    end)
  end

  def adopt(location, relative) do
    with_location(location, fn active ->
      with {:ok, canonical, path, doc} <- manual_existing_file(active.folder, relative),
           nil <- Repo.get_by(Entry, collection_scope: active.scope, relative_path: canonical) do
        {:ok,
         piece(
           index_file(active, %{
             relative: canonical,
             document: doc,
             identity: file_identity(path)
           }),
           active
         )}
      else
        _ -> {:error, "This file is unavailable or already indexed."}
      end
    end)
  end

  # A case-insensitive or normalization-insensitive filesystem can open the same
  # file through several spellings. Resolve a writer-supplied existing path to
  # the names actually listed by its folders before checking database ownership.
  defp manual_existing_file(root, relative) do
    with {:ok, requested_path} <- safe_path(root, relative),
         {:ok, document} <- TextFile.read(requested_path),
         {:ok, canonical} <- listed_relative_path(root, relative),
         {:ok, canonical_path} <- safe_path(root, canonical),
         identity when is_binary(identity) <- file_identity(requested_path),
         true <- identity == file_identity(canonical_path) do
      {:ok, canonical, canonical_path, document}
    else
      _ -> {:error, :unrecognized_existing_file}
    end
  end

  defp listed_relative_path(root, relative) do
    relative
    |> String.split("/")
    |> Enum.reduce_while({:ok, root, []}, fn requested, {:ok, parent, listed} ->
      with {:ok, names} <- File.ls(parent),
           {:ok, name} <- listed_name(names, requested) do
        {:cont, {:ok, Path.join(parent, name), [name | listed]}}
      else
        _ -> {:halt, {:error, :unrecognized_existing_file}}
      end
    end)
    |> case do
      {:ok, _path, listed} -> {:ok, listed |> Enum.reverse() |> Path.join()}
      error -> error
    end
  end

  defp listed_name(names, requested) do
    if requested in names do
      {:ok, requested}
    else
      case spelling_key(requested) do
        nil ->
          {:error, :unrecognized_existing_file}

        key ->
          case Enum.filter(names, &(spelling_key(&1) == key)) do
            [name] -> {:ok, name}
            _ -> {:error, :unrecognized_existing_file}
          end
      end
    end
  end

  defp spelling_key(name) when is_binary(name) do
    if String.valid?(name), do: name |> String.normalize(:nfc) |> String.downcase()
  end

  def list_trash(location),
    do:
      with_location(location, fn active ->
        {:ok, Enum.map(rows(active.scope, true), &piece(&1, active))}
      end)

  def trash(location, existing) do
    with_location(location, fn active ->
      with {:ok, entry} <- open_snapshot(active, existing),
           {:ok, path} <- safe_path(active.folder, entry.relative_path),
           :ok <- fresh_disk(entry, path),
           prepared <- entry |> Changeset.change(pending: %{"kind" => "trash"}) |> persist!(),
           {:ok, trashed} <- complete_pending(active, prepared),
           do: {:ok, piece(trashed, active)}
    end)
  end

  def restore(location, id) do
    with_location(location, fn active ->
      with %Entry{trashed: true} = entry <-
             Repo.get_by(Entry, file_id: id, collection_scope: active.scope),
           {:ok, path} <- safe_path(active.folder, entry.relative_path),
           :ok <- fresh_disk(nil, path),
           {:ok, doc} <- TextFile.decode((entry.file_prefix || "") <> entry.body),
           {:ok, role} <- role_for(doc, entry.title_line),
           {:ok, prepared} <-
             prepare(
               active,
               %{entry | file_token: nil},
               id,
               entry.relative_path,
               doc,
               role,
               Map.put(
                 Map.take(entry, [:notebook_id, :notebook, :source_order, :list_label]),
                 :historical_source,
                 entry.source["historical_source"]
               )
             ),
           {:ok, finished} <- complete_pending(active, prepared),
           do: {:ok, piece(finished, active)}
    end)
  end

  def purge(location, id, token, confirmed?) do
    if confirmed? == true do
      with_location(location, fn active ->
        case Repo.get_by(Entry, file_id: id, collection_scope: active.scope, trashed: true) do
          %Entry{} = e ->
            if snapshot_token(e) == token do
              case Repo.transaction(fn ->
                     Repo.delete_all(from(v in Version, where: v.entry_id == ^e.id))
                     Repo.delete!(e)
                   end) do
                {:ok, _} -> :ok
                error -> error
              end
            else
              stale()
            end

          _ ->
            {:error, "Only writing already in Trash can be permanently removed."}
        end
      end)
    else
      {:error, "Permanent deletion requires explicit confirmation."}
    end
  end

  def permanently_delete(location, piece, confirmed?) when is_map(piece) do
    if confirmed? == true do
      with_location(location, fn active ->
        with :ok <- recover_pending(active, true),
             {:ok, %Entry{} = entry} <- open_snapshot(active, piece),
             {:ok, path} <- safe_path(active.folder, entry.relative_path),
             :ok <- fresh_disk(entry, path),
             identity = file_identity(path),
             true <- identity && identity == (entry.source || %{})["file_identity"],
             prepared <-
               entry
               |> Changeset.change(
                 pending: %{"kind" => "permanent_delete", "identity" => identity}
               )
               |> persist!(),
             {:ok, :deleted} <- complete_pending(active, prepared) do
          :ok
        else
          false ->
            stale()

          {:ok, nil} ->
            {:error, "Choose an existing saved List to delete."}

          {:error, reason} ->
            {:error, "The List could not be permanently deleted: #{inspect(reason)}"}

          _ ->
            stale()
        end
      end)
    else
      {:error, "Permanent deletion requires explicit confirmation."}
    end
  end

  def permanently_delete(_, _, _), do: {:error, "Choose a saved List to delete."}

  def from_historical(location, %{origin: "before", source_key: key} = entry)
      when is_binary(key) and key != "" do
    <<a::48, _::4, b::12, _::2, c::62, _::binary>> = :crypto.hash(:sha256, "still-source:" <> key)
    {:ok, id} = Ecto.UUID.load(<<a::48, 8::4, b::12, 2::2, c::62>>)
    active = Storage.collection_location()

    case Repo.get_by(Entry, file_id: id, collection_scope: active.scope) do
      %Entry{trashed: true} ->
        {:error, "This List already has a saved version in Trash. Restore it before continuing."}

      %Entry{} = saved ->
        if (saved.source || %{})["historical_source"] &&
             saved.source["historical_source"]["source_key"] == key,
           do: get(location, id),
           else:
             {:error,
              "This saved identity belongs to a different source. Its writing was left untouched."}

      nil ->
        body = if entry.title, do: entry.title <> "\n\n" <> entry.body, else: entry.body

        source = %{
          "kind" => "historical_list",
          "source_key" => key,
          "title" => entry.title,
          "notebook" => entry.notebook,
          "source_number" => Still.Writing.source_number(entry)
        }

        result =
          save(location, %{new(location) | id: id}, %{
            body: body,
            title_line: if(entry.title, do: 1),
            historical_source: source
          })

        case result do
          {:ok, _} ->
            result

          error ->
            if Repo.get_by(Entry, file_id: id, collection_scope: active.scope),
              do: get(location, id),
              else: error
        end
    end
  end

  def from_historical(_, _), do: {:error, "Choose a historical List to save."}

  defp rows(scope, trashed),
    do:
      Repo.all(
        from(e in Entry,
          where: e.collection_scope == ^scope and e.trashed == ^trashed,
          order_by: [asc: e.notebook, asc: e.source_order, asc: e.relative_path]
        )
      )

  defp piece(e, active) do
    %{
      id: e.file_id,
      entry_id: e.id,
      body: e.body,
      title: e.title,
      title_source:
        if(e.title_line && not e.title_needs_review, do: "explicit", else: "first_line"),
      title_in_body: true,
      title_line: e.title_line,
      title_needs_review: e.title_needs_review,
      token: snapshot_token(e),
      path: Path.join(active.folder, e.relative_path),
      relative_path: e.relative_path,
      scope: active.scope,
      notebook: e.notebook,
      notebook_id: e.notebook_id,
      list_label: e.list_label,
      source_order: e.source_order,
      historical_source: (e.source || %{})["historical_source"],
      created_at: DateTime.to_iso8601(e.inserted_at),
      updated_at: DateTime.to_iso8601(e.updated_at)
    }
  end

  defp snapshot_token(e),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary({e.file_token, e.lock_version}))
      |> Base.encode16(case: :lower)

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, s} -> "#{s.major_device}:#{s.minor_device}:#{s.inode}"
      _ -> nil
    end
  end

  defp database_backup?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        header = IO.binread(io, 16)
        File.close(io)
        header == <<"SQLite format 3", 0>>

      _ ->
        false
    end
  end

  defp safe_path(root, relative) when is_binary(relative) do
    path = Path.expand(relative, root)
    components = String.split(relative, "/")

    if Path.type(relative) != :relative or path == root or
         not String.starts_with?(path, root <> "/") or
         Enum.any?(components, &(&1 in ["", ".", ".."])) do
      {:error, "Choose a relative file path inside the writing folder."}
    else
      parts = Path.split(Path.relative_to(path, root))

      Enum.reduce_while(Enum.drop(parts, -1), {:ok, root}, fn part, {:ok, parent} ->
        next = Path.join(parent, part)

        case File.lstat(next) do
          {:ok, %{type: :directory}} ->
            {:cont, {:ok, next}}

          _ ->
            {:halt,
             {:error, "A parent folder is missing or symbolic. Create or reconnect it first."}}
        end
      end)
      |> case do
        {:ok, _} ->
          case File.lstat(path) do
            {:ok, %{type: :regular}} -> {:ok, path}
            {:error, :enoent} -> {:ok, path}
            _ -> {:error, "This path is not an ordinary text file."}
          end

        error ->
          error
      end
    end
  end

  defp safe_path(_, _), do: {:error, "Choose a relative filename."}

  defp with_location(location, fun) do
    active = Storage.collection_location()

    cond do
      not active.configured ->
        {:error, "Choose a collection folder before saving or reading files."}

      not active.available ->
        {:error,
         active.error ||
           "The selected collection folder is unavailable. Reconnect it or choose a usable location."}

      (is_map(location) and location[:scope]) && location.scope != active.scope ->
        {:error, "The active collection changed. Reopen this writing before continuing."}

      true ->
        CollectionLock.with_lock(Repo.config()[:database], fn -> fun.(active) end)
    end
  rescue
    e -> {:error, "Could not safely access this writing: #{Exception.message(e)}"}
  end

  defp stale,
    do:
      {:error,
       "This writing changed on disk or in another window since it was opened. Reopen it before saving. Your proposed words have not replaced the file."}

  defp same_location(active) do
    current = Storage.collection_location()

    if current.available and current.scope == active.scope and current.folder == active.folder,
      do: :ok,
      else:
        {:error,
         "The selected folder changed or became unavailable. No other collection was opened."}
  end

  defp sync_dir(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, io} ->
        r = :file.sync(io)
        :file.close(io)
        if r in [:ok, {:error, :eisdir}, {:error, :einval}, {:error, :enotsup}], do: :ok, else: r

      {:error, r} when r in [:eisdir, :einval, :enotsup] ->
        :ok

      error ->
        error
    end
  end
end

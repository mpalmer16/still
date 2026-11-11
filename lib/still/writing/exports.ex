defmodule Still.Writing.Exports do
  @moduledoc "Creates verifiable Markdown and PDF exports beside the selected writing folder."

  alias Still.{LocalRecord, Repo}
  alias Still.Writing.{Files, PoemReferences}

  @kind "writing_export"
  @formats %{markdown: {"md", "text/markdown"}, pdf: {"pdf", "application/pdf"}}

  @doc "Resolve a saved host and its linked source words into immutable export input."
  def prepare(location, piece, format) when format in [:markdown, :pdf] do
    Files.with_export_source(location, piece, fn active, current ->
      with {:ok, root} <- output_root(active.folder),
           {:ok, segments, dependencies} <- resolve_segments(active, current),
           relative <- relative_path(current.relative_path, format),
           source_token <- source_digest(current, segments, dependencies) do
        {:ok,
         %{
           segments: segments,
           title: Files.display_title(current),
           source_token: source_token,
           digest: source_token,
           format: format,
           path: Path.join(root, relative),
           relative_path: relative
         }}
      end
    end)
  end

  def prepare(_, _, _), do: {:error, "Choose Markdown or PDF."}

  @doc "Write a Markdown sibling export, replacing only an unchanged export Still owns."
  def markdown(location, piece) do
    with {:ok, prepared} <- prepare(location, piece, :markdown),
         {:ok, bytes} <- render_markdown(prepared.segments),
         {:ok, path} <- publish(location, piece, :markdown, bytes, prepared.digest) do
      {:ok, path}
    end
  end

  @doc "Publish PDF bytes only if the host and every expanded linked source still match preparation."
  def publish_pdf(location, piece, bytes, expected_source_token)
      when is_binary(bytes) and is_binary(expected_source_token) do
    if valid_pdf?(bytes),
      do: publish(location, piece, :pdf, bytes, expected_source_token),
      else: {:error, "The PDF is incomplete or larger than 20 MB; nothing was exported."}
  end

  def publish_pdf(_, _, _, _), do: {:error, "The PDF export could not be prepared safely."}

  @doc "Publish a context-owned PDF in the shared exports folder without replacing other files."
  def publish_artifact(location, key, relative, bytes, source_digest)
      when is_binary(key) and is_binary(relative) and is_binary(bytes) and
             is_binary(source_digest) do
    Files.with_collection_lock(location, fn active ->
      with true <- Path.extname(relative) == ".pdf" && valid_pdf?(bytes),
           {:ok, root} <- output_root(active.folder),
           {:ok, path} <- safe_output_path(root, relative),
           {:ok, _} <-
             save_owned_export(
               active.scope,
               %{id: key},
               :pdf,
               root,
               relative,
               path,
               bytes,
               source_digest
             ) do
        {:ok, path}
      else
        false -> {:error, "The PDF is incomplete or larger than 20 MB; nothing was exported."}
        error -> error
      end
    end)
  end

  @doc "The output path for a context-owned export, outside the writing collection."
  def artifact_path(location, relative) when is_binary(relative) do
    Files.with_collection_lock(location, fn active ->
      with {:ok, root} <- output_root(active.folder),
           true <- valid_export_relative?(relative) do
        {:ok, Path.join(root, relative)}
      else
        false -> {:error, "Choose an export path inside the exports folder."}
        error -> error
      end
    end)
  end

  defp publish(location, piece, format, bytes, expected_source_token) do
    Files.with_export_source(location, piece, fn active, current ->
      with {:ok, segments, dependencies} <- resolve_segments(active, current),
           source_token <- source_digest(current, segments, dependencies),
           true <- source_token == expected_source_token,
           {:ok, root} <- output_root(active.folder),
           relative <- relative_path(current.relative_path, format),
           {:ok, path} <- safe_output_path(root, relative),
           {:ok, _} <-
             save_owned_export(
               active.scope,
               current,
               format,
               root,
               relative,
               path,
               bytes,
               source_token
             ) do
        {:ok, path}
      else
        false -> stale()
        {:error, _} = error -> error
        _ -> {:error, "The export could not be written safely."}
      end
    end)
  end

  defp resolve_segments(active, current) do
    segments = PoemReferences.resolve(active, current.body, current_id: current.id)

    if Enum.any?(segments, fn
         %{kind: :reference, status: status} -> status != :available
         _ -> false
       end) do
      {:error, "A linked poem is unavailable. Reconnect its source before exporting."}
    else
      {resolved, dependencies} =
        Enum.reduce(segments, {[], []}, fn
          %{kind: :text, raw: raw}, {pieces, deps} ->
            {pieces ++ [%{kind: :text, body: raw}], deps}

          %{kind: :reference, source: source}, {pieces, deps} ->
            segment = %{kind: :poem, body: source.body}
            dependency = {source.id, source.token, source.relative_path}
            {pieces ++ [segment], deps ++ [dependency]}
        end)

      {:ok, resolved, dependencies}
    end
  end

  defp render_markdown(segments) do
    body =
      segments
      |> Enum.map(fn
        %{kind: :text, body: text} -> escape_markdown_text(text)
        %{kind: :poem, body: poem} -> fenced_text(poem)
      end)
      |> IO.iodata_to_binary()

    {:ok, body}
  end

  # A hard break keeps each authored line distinct in Markdown. Escaped punctuation
  # renders as the punctuation the writer typed; leading whitespace uses entities
  # so Markdown cannot reinterpret a stanza as a code block.
  defp escape_markdown_text(text) do
    Regex.split(~r/(\r\n|\r|\n)/u, text, include_captures: true, trim: false)
    |> Enum.chunk_every(2)
    |> Enum.map_join(fn
      [line, ending] -> escape_line(line) <> "  " <> ending
      [line] -> escape_line(line)
    end)
  end

  defp escape_line(line) do
    {indent, rest} = take_indent(line, "")

    indentation_columns =
      indent
      |> String.graphemes()
      |> Enum.reduce(0, fn
        "\t", column -> div(column, 8) * 8 + 8
        _, column -> column + 1
      end)

    encoded_indent = String.duplicate("&nbsp;", indentation_columns)

    escaped =
      rest
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> then(fn text ->
        Regex.replace(~r/[\\`*_{}\[\]()#+.!|~-]/u, text, fn punctuation ->
          "\\" <> punctuation
        end)
      end)

    encoded_indent <> escaped
  end

  defp take_indent(<<char::utf8, rest::binary>>, acc) when char in [32, 9],
    do: take_indent(rest, acc <> <<char::utf8>>)

  defp take_indent(rest, acc), do: {acc, rest}

  defp fenced_text(body) do
    fence = fence_for(body)
    newline = if String.contains?(body, "\r\n"), do: "\r\n", else: "\n"
    ending = if String.ends_with?(body, ["\r", "\n"]), do: "", else: newline
    fence <> "text" <> newline <> body <> ending <> fence <> newline
  end

  defp fence_for(body) do
    longest = Regex.scan(~r/`+/u, body) |> Enum.map(&byte_size(hd(&1))) |> Enum.max(fn -> 0 end)
    String.duplicate("`", max(3, longest + 1))
  end

  defp source_digest(current, segments, dependencies) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {current.token, current.relative_path, dependencies, segments},
        [:deterministic]
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp valid_pdf?(bytes) do
    byte_size(bytes) <= 20_000_000 and String.starts_with?(bytes, "%PDF-") and
      String.contains?(bytes, "%%EOF")
  end

  defp output_root(collection) do
    collection = Path.expand(collection)
    parent = Path.dirname(collection)
    name = Path.basename(collection)

    if collection == parent or name in ["", ".", "/"] do
      {:error, "The selected writing folder cannot have a sibling exports folder."}
    else
      {:ok, Path.join(parent, name <> " Exports")}
    end
  end

  defp relative_path(source, format) do
    {extension, _mime} = Map.fetch!(@formats, format)
    directory = Path.dirname(source)
    name = Path.basename(source)
    stem = if Path.extname(name) == "", do: name, else: Path.rootname(name)
    filename = stem <> "." <> extension
    if directory == ".", do: filename, else: Path.join(directory, filename)
  end

  defp safe_output_path(root, relative) do
    expanded = Path.expand(relative, root)
    components = String.split(relative, "/")

    cond do
      Path.type(relative) != :relative or expanded == root or
        not String.starts_with?(expanded, Path.expand(root) <> "/") or
          Enum.any?(components, &(&1 in ["", ".", ".."])) ->
        {:error, "The export path must stay inside the sibling exports folder."}

      true ->
        with :ok <- ensure_directories(root, Path.dirname(relative)),
             :ok <- ordinary_or_missing(expanded) do
          {:ok, expanded}
        end
    end
  end

  defp ensure_directories(root, relative_directory) do
    with :ok <- ensure_directory(root) do
      if relative_directory == "." do
        :ok
      else
        relative_directory
        |> String.split("/")
        |> Enum.reduce_while({:ok, root}, fn part, {:ok, parent} ->
          path = Path.join(parent, part)

          case ensure_directory(path) do
            :ok -> {:cont, {:ok, path}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, _path} -> :ok
          error -> error
        end
      end
    end
  end

  defp ensure_directory(path) do
    with :ok <- verify_existing_parents(path) do
      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          :ok

        {:error, :enoent} ->
          case File.mkdir(path) do
            :ok ->
              :ok

            {:error, :eexist} ->
              ensure_directory(path)

            {:error, reason} ->
              {:error, "Could not create the exports folder: #{inspect(reason)}."}
          end

        _ ->
          {:error, "An export folder is not an ordinary directory; it was left untouched."}
      end
    end
  end

  defp ordinary_or_missing(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> :ok
      _ -> {:error, "The export destination is not an ordinary file; it was left untouched."}
    end
  end

  defp save_owned_export(scope, current, format, root, relative, path, bytes, source_digest) do
    key = current.id <> ":" <> Atom.to_string(format)
    record = Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: key)
    previous = verified_owned_export(root, record)

    with {:ok, previous_export} <- previous,
         :ok <- target_available(path, relative, previous_export) do
      data = %{
        "relative_path" => relative,
        "sha256" => digest(bytes),
        "source_digest" => source_digest,
        "source_token" => source_digest,
        "format" => Atom.to_string(format)
      }

      attrs = %{scope: scope, kind: @kind, record_key: key, data: data, bytes: nil}
      changeset = LocalRecord.changeset(record || %LocalRecord{}, attrs)

      case Repo.transaction(fn ->
             case if(record, do: Repo.update(changeset), else: Repo.insert(changeset)) do
               {:ok, saved} ->
                 exclusive? = is_nil(previous_export) or previous_export.path != path

                 case write_export(path, bytes, exclusive?) do
                   :ok -> saved
                   {:error, message} -> Repo.rollback({:file_error, message})
                 end

               {:error, changeset} ->
                 Repo.rollback({:record_error, changeset})
             end
           end) do
        {:ok, saved} ->
          case remove_previous_export(previous_export, path) do
            :ok -> {:ok, saved}
            {:error, message} -> {:error, message}
          end

        {:error, reason} ->
          old_bytes =
            if previous_export && previous_export.path == path,
              do: previous_export.bytes,
              else: nil

          restore_after_failed_transaction(path, bytes, old_bytes)
          transaction_error(reason)
      end
    end
  end

  defp verified_owned_export(_root, nil), do: {:ok, nil}

  defp verified_owned_export(root, %LocalRecord{data: data}) do
    with %{"relative_path" => relative, "sha256" => expected} <- data,
         true <- valid_export_relative?(relative),
         path <- Path.join(root, relative),
         :ok <- verify_existing_parents(path) do
      case File.lstat(path) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, %{type: :regular}} ->
          with {:ok, bytes} <- File.read(path), true <- digest(bytes) == expected do
            {:ok, %{path: path, relative_path: relative, bytes: bytes}}
          else
            _ -> {:error, ownership_error()}
          end

        _ ->
          {:error, ownership_error()}
      end
    else
      _ -> {:error, ownership_error()}
    end
  end

  defp ownership_error,
    do: "The existing export changed or its ownership cannot be verified; it was left untouched."

  defp valid_export_relative?(relative) when is_binary(relative) do
    Path.type(relative) == :relative and
      not Enum.any?(String.split(relative, "/"), &(&1 in ["", ".", ".."]))
  end

  defp valid_export_relative?(_), do: false

  defp verify_existing_parents(path) do
    path
    |> Path.dirname()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, parent} ->
      candidate = if parent == "", do: part, else: Path.join(parent, part)

      case File.lstat(candidate) do
        {:ok, %{type: :directory}} -> {:cont, {:ok, candidate}}
        _ -> {:halt, {:error, :unsafe_parent}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      _ -> {:error, "An export folder is not an ordinary directory; it was left untouched."}
    end
  end

  defp target_available(path, _relative, nil) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        {:error, "A file already uses the export name; it was left untouched."}

      {:error, reason} ->
        {:error, "Could not inspect the export destination: #{inspect(reason)}."}
    end
  end

  defp target_available(path, relative, %{path: path, relative_path: relative}), do: :ok

  defp target_available(path, _relative, _previous) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        {:error, "A file already uses the new export name; it was left untouched."}

      {:error, reason} ->
        {:error, "Could not inspect the export destination: #{inspect(reason)}."}
    end
  end

  defp remove_previous_export(nil, _new_path), do: :ok
  defp remove_previous_export(%{path: path}, path), do: :ok

  defp remove_previous_export(%{path: path, bytes: expected}, _new_path) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == digest(expected),
         :ok <- File.rm(path) do
      :ok
    else
      _ ->
        {:error, "The new export was saved, but its previous copy changed and was left in place."}
    end
  end

  defp write_export(path, bytes, exclusive?) do
    staging = Path.join(Path.dirname(path), ".still-export-#{Ecto.UUID.generate()}.partial")

    try do
      with {:ok, file} <- File.open(staging, [:write, :exclusive, :binary]),
           :ok <- write_and_sync(file, bytes),
           :ok <- File.chmod(staging, 0o600),
           :ok <- if(exclusive?, do: File.ln(staging, path), else: File.rename(staging, path)) do
        :ok
      else
        {:error, :eexist} ->
          {:error, "A file appeared at the export destination; it was left untouched."}

        {:error, reason} ->
          {:error, "Could not write the export: #{inspect(reason)}."}
      end
    after
      File.rm(staging)
    end
  end

  defp write_and_sync(file, bytes) do
    try do
      with :ok <- IO.binwrite(file, bytes), do: :file.sync(file)
    after
      File.close(file)
    end
  end

  defp restore_after_failed_transaction(path, written, nil) do
    with {:ok, current} <- File.read(path),
         true <- digest(current) == digest(written),
         do: File.rm(path)
  end

  defp restore_after_failed_transaction(path, written, old_bytes) when is_binary(old_bytes) do
    with {:ok, current} <- File.read(path), true <- digest(current) == digest(written) do
      _ = write_export(path, old_bytes, false)
      :ok
    else
      _ -> :ok
    end
  end

  defp transaction_error({:file_error, message}), do: {:error, message}

  defp transaction_error({:record_error, changeset}),
    do: {:error, "Could not record export ownership: #{inspect(changeset.errors)}."}

  defp transaction_error(reason),
    do: {:error, "Could not safely record this export: #{inspect(reason)}."}

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp stale,
    do:
      {:error,
       "The writing or a linked source changed after export preparation. Reopen it and export again."}
end

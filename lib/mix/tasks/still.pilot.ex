defmodule Mix.Tasks.Still.Pilot do
  use Mix.Task

  alias Still.Writing.TextFile

  @shortdoc "Check ordinary local text and title roles without importing or changing files"
  @moduledoc """
  Runs the format pilot without starting Still or opening its database.

      mix still.pilot --synthetic
      mix still.pilot /absolute/path/to/prepared/text

  The synthetic pilot creates a disposable collection and removes it afterward.
  A supplied location is read only; nothing is imported, renamed, or converted.
  Unsupported files are reported individually and cause a nonzero exit status.
  Notebook and List labels are shown as paths, never inferred from timestamps.
  """

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [synthetic: :boolean]) do
      {[synthetic: true], [], []} -> synthetic()
      {[], [path], []} -> inspect_folder(Path.expand(path), false)
      _ -> Mix.raise("Use mix still.pilot --synthetic or mix still.pilot /path/to/prepared/text")
    end
  end

  defp synthetic do
    root =
      Path.join(System.tmp_dir!(), "still-format-pilot-#{:erlang.unique_integer([:positive])}")

    File.mkdir!(root)

    try do
      fixtures = [
        {"Current Notebooks/2026/Notebook 1/0001.txt",
         "House sounds\r\n\r\nrain: furnace:\r\n\tdog upstairs:\r\n"},
        {"Current Notebooks/2026/Notebook 1/0003a", "\n  An opening\n\n  another line\n"},
        {"Current Notebooks/2026/Notebook 1/0003b.txt", "rain\n\nrain\n\train\n"},
        {"Early Notebooks/Notebook 2/0010.md", "THE NIGHT\n\nand everything is breathing\n"},
        {"without a notebook", "words without a number\r\tand their space\r"},
        {"empty page", ""},
        {"UTF-8 with BOM", <<239, 187, 191>> <> "Snow — 雪\n\n\tbody\n"},
        {"needs preparation/older encoding", <<99, 97, 102, 233>>},
        {"needs preparation/word document", <<"PK", 3, 4, 0>>}
      ]

      Enum.each(fixtures, fn {relative, bytes} ->
        path = Path.join(root, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end)

      File.mkdir_p!(Path.join(root, "Current Notebooks/2026/Notebook 2"))
      inspect_folder(root, true)

      title_path = Path.join(root, "Current Notebooks/2026/Notebook 1/0001.txt")
      {:ok, original} = TextFile.read(title_path)
      {:ok, role} = TextFile.mark_title(original, 1)
      {:ok, fields} = TextFile.editor_parts(original, role)
      true = fields.before <> fields.title <> fields.after == original.body
      true = TextFile.copy_text(original) == original.body
      true = TextFile.encode(original) == File.read!(title_path)
      {:ok, edited, edited_role} = TextFile.replace_title(original, role, "House & rain")
      {:ok, "House & rain"} = TextFile.title(edited, edited_role)
      true = edited.body == "House & rain" <> fields.after

      Enum.each(fixtures, fn {relative, bytes} ->
        true = File.read!(Path.join(root, relative)) == bytes
      end)

      Mix.shell().info("Title marking, editor reassembly, title editing, and Copy text: exact.")

      Mix.shell().info(
        "All fixture files unchanged. No database opened. Disposable files removed on exit."
      )
    after
      File.rm_rf!(root)
    end
  end

  defp inspect_folder(root, synthetic?) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} ->
        :ok

      _ ->
        Mix.raise(
          "The selected location is unavailable or is not an ordinary local folder. Choose a usable location."
        )
    end

    Mix.shell().info("Ordinary text pilot (read only; no title inference)")
    {accepted, rejected} = walk(root, "")

    Mix.shell().info(
      "#{accepted} readable text files; #{rejected} files require preparation or review."
    )

    if rejected > 0 and not synthetic?,
      do:
        Mix.raise(
          "Files were left unchanged. Resolve the reported files before indexing this collection."
        )
  end

  defp walk(root, relative) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, []} ->
            Mix.shell().info("Empty folder: #{inspect(relative)}")
            {0, 0}

          {:ok, names} ->
            names
            |> Enum.sort()
            |> Enum.reduce({0, 0}, fn name, {accepted, rejected} ->
              {a, r} = walk(root, Path.join(relative, name))
              {accepted + a, rejected + r}
            end)

          {:error, reason} ->
            report_error(relative, reason)
        end

      _ ->
        case TextFile.read(path) do
          {:ok, document} ->
            bytes = TextFile.encode(document)
            endings = document |> TextFile.lines() |> Enum.map(& &1.ending) |> Enum.uniq()

            Mix.shell().info(
              "Text: #{inspect(relative)} · #{byte_size(bytes)} bytes · separators #{inspect(endings)} · no explicit title"
            )

            {1, 0}

          {:error, reason} ->
            report_error(relative, reason)
        end
    end
  end

  defp report_error(relative, reason) do
    Mix.shell().info("Needs review: #{inspect(relative)} · #{inspect(reason)}")
    {0, 1}
  end
end

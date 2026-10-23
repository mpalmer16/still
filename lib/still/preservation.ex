defmodule Still.Preservation do
  @moduledoc "Local, explicit copies of the complete database and portable writing."

  alias Still.{Repo, Writing}

  def backup!(dir \\ destination("backups")) do
    dir = prepare_dir(dir)
    path = Path.join(dir, filename("still", "db"))
    Repo.query!("VACUUM INTO ?", [path])
    File.chmod!(path, 0o600)
    path
  end

  def export!(dir \\ destination("exports")) do
    dir = prepare_dir(dir)
    path = Path.join(dir, filename("still-writing", "json"))

    entries =
      Writing.export_entries()
      |> Enum.map(fn entry ->
        %{
          id: entry.id,
          title: entry.title,
          body: entry.body,
          origin: entry.origin,
          created_at: if(entry.origin == "now", do: DateTime.to_iso8601(entry.inserted_at)),
          authored_at: if(entry.origin == "now", do: DateTime.to_iso8601(entry.inserted_at)),
          imported_at: if(entry.origin == "before", do: DateTime.to_iso8601(entry.inserted_at)),
          returned_at: if(entry.returned_at, do: DateTime.to_iso8601(entry.returned_at)),
          source_key: entry.source_key,
          source_group: entry.source_group,
          notebook: entry.notebook,
          source_order: entry.source_order,
          source: entry.source,
          beside_id: entry.beside_id,
          updated_at: DateTime.to_iso8601(entry.updated_at),
          earlier_versions:
            entry.versions
            |> Enum.sort_by(&{&1.inserted_at, &1.id})
            |> Enum.map(fn version ->
              %{
                title: version.title,
                body: version.body,
                saved_at: DateTime.to_iso8601(version.inserted_at)
              }
            end)
        }
      end)

    payload =
      Jason.encode_to_iodata!(%{
        format: "still-1",
        exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        entries: entries
      })

    partial = path <> ".partial"
    {:ok, file} = File.open(partial, [:write, :exclusive, :binary])

    try do
      IO.binwrite(file, payload)
      :ok = :file.sync(file)
    after
      File.close(file)
    end

    File.chmod!(partial, 0o600)
    File.rename!(partial, path)
    path
  end

  defp destination(name) do
    Repo.config()[:database] |> Path.dirname() |> Path.join(name)
  end

  defp prepare_dir(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp filename(prefix, extension) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    "#{prefix}-#{stamp}-#{System.unique_integer([:positive])}.#{extension}"
  end
end

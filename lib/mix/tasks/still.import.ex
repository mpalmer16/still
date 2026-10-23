defmodule Mix.Tasks.Still.Import do
  use Mix.Task

  @shortdoc "Bring a local Lists manifest into Still"

  @impl Mix.Task
  def run([path]) do
    previous_level = Logger.level()
    Logger.configure(level: :warning)

    try do
      Mix.Task.run("app.start")

      case Still.Writing.import_lists(path) do
        {:ok, %{inserted: inserted, skipped: skipped}} ->
          Mix.shell().info("Brought #{inserted} pieces into Still; #{skipped} already here.")

        {:error, reason} ->
          Mix.raise("Could not bring this manifest into Still: #{explain(reason)}")
      end
    after
      Logger.configure(level: previous_level)
    end
  end

  def run(_args), do: Mix.raise("Usage: mix still.import PATH_TO_LISTS_JSON")

  defp explain({:invalid_entry, position, %Ecto.Changeset{errors: errors}}) do
    fields = errors |> Keyword.keys() |> Enum.join(", ")
    "piece #{position} has invalid #{fields}"
  end

  defp explain({:invalid_entry, position, :missing_source_key}),
    do: "piece #{position} has no source identity"

  defp explain(%Jason.DecodeError{}), do: "the file is not readable JSON"
  defp explain(:invalid_manifest), do: "the file is not a still-lists-1 manifest"
  defp explain(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp explain(_reason), do: "the import could not be completed"
end

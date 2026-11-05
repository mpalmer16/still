defmodule Mix.Tasks.Still.Restore do
  use Mix.Task

  @shortdoc "Restore a verified backup to a new local database and reconcile a selected text folder"
  @moduledoc """
  With Still stopped, restore to a database path that does not yet exist:

      mix still.restore /path/still-backup.sqlite3 /local/state/still.db /path/to/text

  The text folder must already exist. Its words are never replaced. Backups
  containing several collection roots require `--collection UUID` to select
  the identity to reconnect. The application endpoint is not started.
  """
  @impl true
  def run(args) do
    if Process.whereis(Still.Repo), do: Mix.raise("Quit Still before restoring a database.")

    case OptionParser.parse(args, strict: [collection: :string]) do
      {options, [backup, destination, folder], []} ->
        restore(backup, destination, folder, options)

      _ ->
        Mix.raise(
          "Use mix still.restore BACKUP NEW_LOCAL_DATABASE EXISTING_TEXT_FOLDER [--collection UUID]"
        )
    end
  end

  defp restore(backup, destination, folder, options) do
    unless Path.type(destination) == :absolute and Path.type(folder) == :absolute and
             File.dir?(folder),
           do:
             Mix.raise("Choose an absolute new local database path and an available text folder.")

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)

    case Still.Storage.restore_backup(backup, destination, folder) do
      {:error, message} ->
        Mix.raise(message)

      {:ok, _} ->
        reconnect(destination, folder, options[:collection])
        config = Application.fetch_env!(:still, Still.Repo)
        Application.put_env(:still, Still.Repo, Keyword.put(config, :database, destination))
        {:ok, repo} = Still.Repo.start_link(log: false)

        try do
          with {:ok, _} <- Still.Storage.set_folder(folder),
               {:ok, pieces} <-
                 Still.Writing.Files.synchronize(Still.Storage.collection_location()) do
            Mix.shell().info(
              "Verified database restored to #{destination}; #{length(pieces)} current files reconciled. Source files were not changed."
            )
          else
            {:error, message} ->
              Mix.raise(
                "The verified database is restored at #{destination}. Folder reconciliation needs attention: #{message}"
              )
          end
        after
          GenServer.stop(repo)
          Application.put_env(:still, Still.Repo, config)
        end
    end
  end

  defp reconnect(destination, folder, requested) do
    {:ok, db} = Exqlite.start_link(database: destination, mode: :readwrite)

    try do
      rows = Exqlite.query!(db, "SELECT id FROM collection_folders").rows

      id =
        case {requested, rows} do
          {nil, [[only]]} -> only
          {chosen, _} when is_binary(chosen) -> if [chosen] in rows, do: chosen
          _ -> nil
        end

      if is_nil(id),
        do:
          Mix.raise(
            "Choose --collection UUID explicitly; the restored database is retained at #{destination}."
          )

      Exqlite.query!(db, "UPDATE collection_folders SET root = ? WHERE id = ?", [
        Path.expand(folder),
        id
      ])

      case Exqlite.query!(db, "PRAGMA integrity_check").rows do
        [["ok"]] -> :ok
        _ -> Mix.raise("The restored database needs an integrity review before opening.")
      end
    after
      GenServer.stop(db)
    end
  end
end

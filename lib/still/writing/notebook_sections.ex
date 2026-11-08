defmodule Still.Writing.NotebookSections do
  @moduledoc "Editable section labels and the destination for new Lists, without moving files."

  alias Still.{LocalRecord, Repo, Storage}
  alias Still.Writing.{Notebook, Notebooks}
  import Ecto.Query

  def settings(key) do
    scope = Storage.collection_location().scope

    records =
      Still.Writing.Discovery.memo({__MODULE__, scope}, fn ->
        Repo.all(
          from r in LocalRecord,
            where: r.scope == ^scope and r.kind == "notebook_sections",
            select: {r.record_key, r.data}
        )
        |> Map.new()
      end)

    Map.get(records, key, %{})
  end

  def label(key, section, fallback), do: get_in(settings(key), ["labels", section]) || fallback

  def rename(key, section, label) when is_binary(label) do
    label = String.trim(label)

    if label != "" and String.length(label) <= 200 do
      change(key, section, fn data ->
        Map.update(data, "labels", %{section => label}, &Map.put(&1, section, label))
      end)
    else
      {:error, "Use a section name between 1 and 200 characters."}
    end
  end

  def choose(key, section) do
    with %{id: id, managed: true} <- Notebooks.get(key) do
      Repo.transaction(fn ->
        with {:ok, _} <- change(key, section, &Map.put(&1, "current", section)),
             {:ok, _} <- Notebooks.choose_current(id) do
          section
        else
          {:error, message} -> Repo.rollback(message)
        end
      end)
    else
      _ -> {:error, "Choose a section in a local notebook."}
    end
  end

  def order(key, sections) when is_list(sections) and sections != [] do
    case Notebooks.get(key) do
      %{sections: existing} ->
        if Enum.sort(Enum.map(existing, & &1.key)) == Enum.sort(sections) do
          change(key, hd(sections), &Map.put(&1, "order", sections))
        else
          {:error, "The notebook sections changed. Reopen the notebook."}
        end

      _ ->
        {:error, "That notebook is unavailable."}
    end
  end

  def destination(%Notebook{} = notebook) do
    section = settings(notebook.key)["current"] || notebook.key

    cond do
      section == notebook.key ->
        notebook.relative_path

      String.starts_with?(section, notebook.key <> "/") ->
        Path.join(notebook.relative_path, String.replace_prefix(section, notebook.key <> "/", ""))

      true ->
        :unavailable
    end
  end

  defp change(key, section, fun) do
    location = Storage.collection_location()

    with true <- location.available,
         notebook when not is_nil(notebook) <- Notebooks.get(key),
         true <- Enum.any?(notebook.sections, &(&1.key == section)) do
      saved =
        record(key) ||
          %LocalRecord{
            scope: location.scope,
            kind: "notebook_sections",
            record_key: key,
            data: %{}
          }

      saved
      |> LocalRecord.changeset(%{data: fun.(saved.data)})
      |> Ecto.Changeset.optimistic_lock(:lock_version)
      |> Repo.insert_or_update()
      |> case do
        {:ok, _} -> {:ok, section}
        _ -> {:error, "The section could not be updated. Please try again."}
      end
    else
      _ -> {:error, "That section is unavailable. Reopen the notebook and try again."}
    end
  rescue
    Ecto.StaleEntryError ->
      {:error, "The section changed elsewhere. Reopen the notebook and try again."}
  end

  defp record(key) do
    Repo.get_by(LocalRecord,
      scope: Storage.collection_location().scope,
      kind: "notebook_sections",
      record_key: key
    )
  end
end

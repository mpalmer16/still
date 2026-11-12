defmodule Still.Writing.NotebookSections do
  @moduledoc "Editable section labels and the destination for new Lists, without moving files."

  alias Still.{LocalRecord, Repo, Storage}
  alias Still.Writing.{Notebook, Notebooks}
  import Ecto.Query

  def settings(key) do
    scope =
      Still.Writing.Discovery.memo({__MODULE__, :scope}, fn ->
        Storage.collection_location().scope
      end)

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

  @doc "The section key assigned to the notebook's unplaced folder, if one exists."
  def unplaced_section(%Notebook{} = notebook) do
    case settings(notebook.key)["unplaced"] do
      %{"section" => section} = role when is_binary(section) ->
        case resolve_unplaced(notebook, role) do
          %{folder: folder} when is_binary(folder) -> section_for_folder(notebook, folder)
          _ -> section
        end

      _ ->
        nil
    end
  end

  def unplaced_section(_), do: nil

  @doc "The resolved Unplaced folder's collection-relative path, or nil if unavailable."
  def unplaced_folder(%Notebook{} = notebook) do
    case resolve_unplaced(notebook) do
      %{folder: folder} when is_binary(folder) -> folder
      _ -> nil
    end
  end

  def unplaced_folder(_), do: nil

  def unplaced?(%Notebook{} = notebook, relative_file_path) when is_binary(relative_file_path) do
    case resolve_unplaced(notebook) do
      %{folder: folder} when is_binary(folder) ->
        path_folder = Path.dirname(relative_file_path)
        path_folder == folder or String.starts_with?(path_folder, folder <> "/")

      _ ->
        false
    end
  end

  def unplaced?(_, _), do: false

  @doc "Records the chosen unplaced folder for a notebook."
  def register_unplaced(
        %Notebook{relative_path: base} = notebook,
        relative_folder,
        folder_identity
      )
      when is_binary(base) and is_binary(relative_folder) do
    section = section_for_folder(notebook, relative_folder)
    location = Storage.collection_location()

    with true <- location.available,
         true <- is_nil(notebook.collection_scope) or notebook.collection_scope == location.scope,
         true <- relative_folder != "",
         true <- String.starts_with?(relative_folder, notebook.relative_path <> "/"),
         true <- Path.type(relative_folder) == :relative,
         true <- not Enum.any?(String.split(relative_folder, "/"), &(&1 in ["", ".", ".."])),
         true <- is_binary(section) do
      saved =
        record(notebook.key) ||
          %LocalRecord{
            scope: location.scope,
            kind: "notebook_sections",
            record_key: notebook.key,
            data: %{}
          }

      data =
        Map.put(saved.data || %{}, "unplaced", %{
          "section" => section,
          "relative_folder" => relative_folder,
          "folder_identity" => folder_identity
        })

      case saved
           |> LocalRecord.changeset(%{data: data})
           |> Ecto.Changeset.optimistic_lock(:lock_version)
           |> Repo.insert_or_update() do
        {:ok, _} ->
          invalidate_cache()
          {:ok, section}

        _ ->
          {:error, "The Unplaced folder could not be recorded. Please try again."}
      end
    else
      _ -> {:error, "Choose an Unplaced folder inside this notebook."}
    end
  rescue
    Ecto.StaleEntryError -> {:error, "The notebook changed elsewhere. Please try again."}
  end

  def register_unplaced(_, _, _), do: {:error, "That notebook is unavailable."}

  defp section_for_folder(notebook, folder) do
    if folder == notebook.relative_path,
      do: notebook.key,
      else: notebook.key <> String.replace_prefix(folder, notebook.relative_path, "")
  end

  defp resolve_unplaced(notebook),
    do: resolve_unplaced(notebook, settings(notebook.key)["unplaced"])

  defp resolve_unplaced(_notebook, nil), do: nil

  defp resolve_unplaced(notebook, %{"relative_folder" => folder} = role) when is_binary(folder) do
    Still.Writing.Discovery.memo(
      {__MODULE__, :resolved, notebook.id, notebook.relative_path, role},
      fn ->
        resolve_role_folder(notebook, folder, role["folder_identity"])
      end
    )
  end

  defp resolve_unplaced(_notebook, _), do: nil

  defp resolve_role_folder(notebook, folder, identity) do
    case folder_identity(notebook, folder) do
      ^identity when is_binary(identity) ->
        %{folder: folder}

      _ when not is_binary(identity) ->
        %{folder: folder}

      _ ->
        case locate_identity(notebook, identity) do
          path when is_binary(path) -> %{folder: path}
          _ -> %{folder: nil, unavailable: true}
        end
    end
  end

  defp folder_identity(notebook, relative) do
    with root when is_binary(root) <- Storage.collection_location().folder,
         :ok <- safe_real_directory(root, notebook.relative_path),
         :ok <- safe_real_directory(root, relative),
         {:ok, stat} <- File.lstat(Path.join(root, relative)),
         :directory <- stat.type do
      "#{stat.major_device}:#{stat.minor_device}:#{stat.inode}"
    else
      _ -> nil
    end
  end

  defp locate_identity(notebook, identity) do
    scope = Storage.collection_location().scope

    Still.Writing.Discovery.memo(
      {__MODULE__, :unplaced_identity, scope, notebook.key, identity},
      fn ->
        root = Storage.collection_location().folder
        base = Path.join(root, notebook.relative_path)

        if safe_real_directory(root, notebook.relative_path) == :ok do
          [base | Path.wildcard(Path.join(base, "**"), match_dot: true)]
          |> Enum.filter(&safe_candidate_directory?(root, notebook.relative_path, &1))
          |> Enum.find_value(fn path ->
            case File.lstat(path) do
              {:ok, stat} when stat.type == :directory ->
                if "#{stat.major_device}:#{stat.minor_device}:#{stat.inode}" == identity,
                  do: Path.relative_to(path, root)

              _ ->
                nil
            end
          end)
        end
      end
    )
  end

  defp safe_real_directory(root, relative) do
    Enum.reduce_while(String.split(relative, "/", trim: true), root, fn component, current ->
      case File.lstat(Path.join(current, component)) do
        {:ok, %{type: :directory}} -> {:cont, Path.join(current, component)}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, :unavailable}
      _ -> :ok
    end
  end

  defp safe_candidate_directory?(root, notebook_relative, path) do
    relative = Path.relative_to(path, root)

    String.starts_with?(relative, notebook_relative <> "/") and
      safe_real_directory(root, relative) == :ok
  end

  defp invalidate_cache do
    key = {Still.Writing.Discovery, :memo}
    if Process.get(key), do: Process.put(key, %{})
  end

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
    local = Notebooks.get(key)
    notebook = managed_notebook(key)
    role = settings(key)["unplaced"] || %{}

    with %{id: id, managed: true} <- local,
         %Notebook{} <- notebook,
         false <- section in [unplaced_section(notebook), role["section"]] do
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
    unplaced = unplaced_section(notebook)
    original_unplaced = get_in(settings(notebook.key), ["unplaced", "section"])

    cond do
      section in [unplaced, original_unplaced] ->
        notebook.relative_path

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

  defp managed_notebook(key) do
    scope = Storage.collection_location().scope

    Repo.one(
      from n in Notebook,
        where: n.key == ^key and (is_nil(n.collection_scope) or n.collection_scope == ^scope)
    )
  end
end

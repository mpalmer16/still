defmodule Still.Writing.ReadingPlace do
  @moduledoc "The durable place to return to after wandering through writing."

  alias Still.{LocalRecord, Repo, Storage}
  alias Still.Writing.{Entry, Geography, Version}

  @kind "reading_place"
  @last_key "last"

  def context(%Entry{} = entry, params \\ %{}) do
    from = if value(params, "from") == "notebook", do: "notebook", else: "find"

    notebook =
      if from == "notebook",
        do: clean_key(value(params, "notebook")) || physical_notebook(entry),
        else: nil

    query = Still.Writing.Search.query(value(params, "q") || "")
    version = valid_version(entry, value(params, "version"))

    %{
      "from" => from,
      "notebook" => notebook,
      "q" => query,
      "earlier" => boolean(value(params, "earlier")),
      "shown" => shown(value(params, "shown")),
      "at" => anchor(entry, value(params, "at"), version),
      "version" => version,
      "written" => boolean(value(params, "written"))
    }
  end

  def remember(%Entry{} = entry, params_or_context \\ %{}) do
    location = Storage.collection_location()

    if eligible?(entry, location) do
      context = context(entry, params_or_context)

      data = %{
        "entry_id" => entry.id,
        "version" => context["version"],
        "context" => context
      }

      Repo.transaction(fn ->
        :ok = put_record(location.scope, @last_key, data)

        case Geography.for_entry(entry).key do
          "now" ->
            :ok

          notebook ->
            put_record(location.scope, notebook_record_key(notebook), data)
            :ok
        end
      end)
      |> case do
        {:ok, :ok} -> {:ok, %{entry: entry, context: context}}
        {:error, reason} -> {:error, "Could not save this reading place: #{inspect(reason)}"}
      end
    else
      {:error, "This writing is no longer available in the active collection."}
    end
  end

  def last, do: load(@last_key, nil)

  def for_notebook(key) when is_binary(key) and byte_size(key) <= 1_024,
    do: load(notebook_record_key(key), key)

  def for_notebook(_), do: nil

  defp load(key, notebook_key) do
    location = Storage.collection_location()

    with %LocalRecord{data: data} <-
           Repo.get_by(LocalRecord, scope: location.scope, kind: @kind, record_key: key),
         {:ok, id, context} <- decode(data),
         %Entry{} = entry <- Repo.get(Entry, id),
         true <- eligible?(entry, location),
         true <- is_nil(notebook_key) or Geography.for_entry(entry).key == notebook_key,
         true <- version_exists?(entry, context["version"]) do
      %{entry: entry, context: context}
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp decode(%{"entry_id" => id, "version" => version, "context" => context})
       when is_integer(id) and (is_nil(version) or is_integer(version)) and is_map(context) do
    # Re-normalize persisted data so malformed records cannot inject arbitrary reader state.
    entry = Repo.get(Entry, id)
    normalized = if entry, do: context(entry, context), else: nil

    if normalized && version == Map.get(context, "version") &&
         (is_nil(version) or normalized["version"] == version),
       do: {:ok, id, normalized},
       else: :error
  end

  defp decode(_), do: :error

  defp eligible?(entry, location) do
    not entry.trashed and not entry.file_missing and
      (is_nil(entry.file_id) or
         (location.available and entry.collection_scope == location.scope))
  end

  defp valid_version(%Entry{id: id}, value) do
    case positive_int(value) do
      nil -> nil
      version_id -> if Repo.get_by(Version, id: version_id, entry_id: id), do: version_id
    end
  end

  defp version_exists?(_entry, nil), do: true
  defp version_exists?(entry, id), do: Repo.get_by(Version, id: id, entry_id: entry.id) != nil

  defp anchor(entry, value, version) when is_binary(value) do
    case Regex.run(~r/\A(current|version)-([1-9][0-9]*)\z/, value) do
      [_, "current", _id] -> value
      [_, "version", _id] -> value
      _ -> default_anchor(entry, version)
    end
  end

  defp anchor(entry, _value, version), do: default_anchor(entry, version)
  defp default_anchor(entry, nil), do: "current-#{entry.id}"
  defp default_anchor(_entry, version), do: "version-#{version}"

  defp shown(value) do
    n = positive_int(value) || 40
    n |> max(40) |> min(5_000) |> then(&(div(&1 + 39, 40) * 40))
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp positive_int(_), do: nil

  defp boolean(true), do: true
  defp boolean(value) when value in ["true", "1", 1, "on"], do: true
  defp boolean(_), do: false

  defp clean_key(key) when is_binary(key) and byte_size(key) in 1..1_024, do: key
  defp clean_key(_), do: nil

  defp physical_notebook(entry) do
    case Geography.for_entry(entry).key do
      "now" -> nil
      key -> key
    end
  end

  defp value(map, key) when is_map(map) do
    atom_key =
      case key do
        "from" -> :from
        "notebook" -> :notebook
        "q" -> :q
        "earlier" -> :earlier
        "shown" -> :shown
        "at" -> :at
        "version" -> :version
        "written" -> :written
      end

    Map.get(map, key, Map.get(map, atom_key))
  end

  defp value(_, _), do: nil

  defp put_record(scope, key, data) do
    attrs = %{scope: scope, kind: @kind, record_key: key, data: data, bytes: nil}
    existing = Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: key)

    case existing do
      nil -> Repo.insert!(LocalRecord.changeset(%LocalRecord{}, attrs))
      record -> Repo.update!(LocalRecord.changeset(record, attrs))
    end

    :ok
  end

  defp notebook_record_key(key),
    do: "notebook:" <> Base.encode16(:crypto.hash(:sha256, key), case: :lower)
end

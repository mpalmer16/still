defmodule Still.Writing.Notebooks do
  @moduledoc "An index of source notebooks, retaining each source section's own order."

  import Ecto.Query
  alias Still.Repo
  alias Still.Writing.{Entry, Geography}

  def all do
    headers()
    |> Enum.group_by(&Geography.for_entry(&1).key)
    |> Enum.map(fn {_key, entries} -> describe(entries, false) end)
    |> Enum.sort_by(&{region_order(&1.region), natural_key(&1.key)})
  end

  def get(key) when is_binary(key) and byte_size(key) <= 1_024 do
    sections =
      headers()
      |> Enum.filter(&(Geography.for_entry(&1).key == key))
      |> Enum.map(& &1.notebook)
      |> Enum.uniq()

    case sections do
      [] ->
        nil

      _ ->
        source_entries()
        |> where([e], e.notebook in ^sections)
        |> Repo.all()
        |> describe(true)
    end
  end

  def get(_key), do: nil

  def neighbors(%Entry{origin: "before"} = entry) do
    with notebook when not is_nil(notebook) <- get(Geography.for_entry(entry).key),
         index when is_integer(index) <- Enum.find_index(notebook.entries, &(&1.id == entry.id)) do
      %{
        previous: if(index > 0, do: Enum.at(notebook.entries, index - 1)),
        next: Enum.at(notebook.entries, index + 1),
        notebook: notebook.label
      }
    else
      _ -> nil
    end
  end

  def neighbors(_), do: nil

  defp source_entries do
    from e in Entry,
      where: e.origin == "before" and not is_nil(e.notebook) and e.notebook != ""
  end

  defp headers do
    source_entries()
    |> select([e], %{
      id: e.id,
      origin: e.origin,
      notebook: e.notebook,
      source_order: e.source_order,
      source_group: e.source_group,
      source_key: e.source_key,
      source: e.source
    })
    |> Repo.all()
  end

  defp describe([], _include_entries), do: nil

  defp describe(entries, include_entries) do
    representative = Enum.min_by(entries, &{natural_key(&1.notebook), source_position(&1)})
    place = Geography.for_entry(representative)
    place = Map.merge(place, %{x: place.anchor_x, y: place.anchor_y, corner: nil})

    sections =
      entries
      |> Enum.group_by(& &1.notebook)
      |> Enum.sort_by(fn {key, _entries} ->
        {if(key == place.key, do: 0, else: 1), natural_key(key)}
      end)
      |> Enum.map(fn {key, section_entries} ->
        section_place = Geography.for_entry(hd(section_entries))

        section = %{
          key: key,
          label: section_place.corner || place.label,
          count: length(section_entries)
        }

        if include_entries,
          do: Map.put(section, :entries, Enum.sort_by(section_entries, &source_position/1)),
          else: section
      end)

    notebook = %{
      key: place.key,
      label: place.label,
      region: place.region,
      count: length(entries),
      place: place,
      section_count: length(sections),
      sections: sections
    }

    if include_entries,
      do: Map.put(notebook, :entries, Enum.flat_map(sections, & &1.entries)),
      else: notebook
  end

  # The importer's order is an artifact position, not a filename number or a date.
  # Metadata can recover a position for older rows; otherwise they follow known
  # positions. Ties never depend on living edits, titles, or import timestamps.
  defp source_position(entry) do
    artifact = source_number(entry, "artifact_order")
    piece = source_number(entry, "piece_order")

    position =
      cond do
        is_integer(entry.source_order) -> {0, entry.source_order}
        is_integer(artifact) and is_integer(piece) -> {0, artifact * 100 + piece}
        true -> {1, 0}
      end

    {position, artifact || 0, piece || 0, entry.source_group || "", entry.source_key || "",
     entry.id}
  end

  defp source_number(entry, field) do
    value = (entry.source || %{})[field]
    if is_integer(value) and value >= 0, do: value
  end

  defp region_order(:early), do: 0
  defp region_order(:current), do: 1
  defp region_order(_region), do: 2

  defp natural_key(key) do
    parts =
      Regex.scan(~r/\d+|\D+/u, key)
      |> List.flatten()
      |> Enum.map(fn part ->
        case Integer.parse(part) do
          {number, ""} -> {0, number}
          _ -> {1, String.downcase(part)}
        end
      end)

    {parts, key}
  end
end

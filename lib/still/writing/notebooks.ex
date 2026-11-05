defmodule Still.Writing.Notebooks do
  @moduledoc "An index of source notebooks, retaining each source section's own order."

  import Ecto.Query
  alias Still.Repo
  alias Still.Writing.{Entry, Geography, Notebook}

  def create(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    attrs = if attrs["key"] in [nil, ""], do: Map.put(attrs, "key", attrs["label"]), else: attrs
    %Notebook{} |> Notebook.changeset(attrs) |> Repo.insert()
  end

  def update(%Notebook{} = notebook, attrs),
    do: notebook |> Notebook.changeset(attrs) |> Repo.update()

  def choose_current(id) do
    Repo.transaction(fn ->
      if id do
        case Repo.get(Notebook, id) do
          nil ->
            Repo.rollback(:not_found)

          notebook ->
            Repo.update_all(Notebook, set: [current: false])
            Repo.update!(Notebook.changeset(notebook, %{current: true}))
        end
      else
        Repo.update_all(Notebook, set: [current: false])
        nil
      end
    end)
  end

  def current do
    scope = Still.Storage.collection_location().scope

    Repo.all(
      from n in Notebook,
        where: n.current and (is_nil(n.collection_scope) or n.collection_scope == ^scope)
    )
    |> List.first()
  end

  def register_folder(location, relative, attrs),
    do: Still.Writing.Files.register_folder(location, relative, attrs)

  def create_folder(location, relative, attrs),
    do: Still.Writing.Files.create_folder(location, relative, attrs)

  def assign_entry(%Entry{} = entry, %Notebook{} = notebook, attrs \\ %{}) do
    changes =
      Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{"notebook_id" => notebook.id, "notebook" => notebook.key})

    entry
    |> Entry.changeset(changes)
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update()
  end

  def all do
    headers()
    |> Enum.group_by(&Geography.for_entry(&1).key)
    |> Enum.map(fn {_key, entries} -> describe(entries, false) end)
    |> then(fn historical ->
      scope = Still.Storage.collection_location().scope

      records =
        Repo.all(
          from(n in Notebook,
            where: is_nil(n.collection_scope) or n.collection_scope == ^scope,
            order_by: [asc: n.id]
          )
        )

      by_key = Map.new(records, &{&1.key, &1})
      known = MapSet.new(Enum.map(historical, & &1.key))

      historical =
        Enum.map(historical, fn item ->
          case by_key[item.key] do
            nil -> item
            record -> Map.merge(item, managed_fields(record))
          end
        end)

      historical ++
        (records |> Enum.reject(&MapSet.member?(known, &1.key)) |> Enum.map(&managed_summary/1))
    end)
    |> Enum.sort_by(&{region_order(&1.region), natural_key(&1.key)})
  end

  def get(key) when is_binary(key) and byte_size(key) <= 1_024 do
    matching_headers = Enum.filter(headers(), &(Geography.for_entry(&1).key == key))
    matching_ids = Enum.map(matching_headers, & &1.id)

    scope = Still.Storage.collection_location().scope

    managed =
      Repo.all(
        from n in Notebook,
          where: n.key == ^key and (is_nil(n.collection_scope) or n.collection_scope == ^scope)
      )
      |> List.first()

    case {matching_ids, managed} do
      {[], nil} ->
        nil

      {[], notebook} ->
        managed_detail(notebook)

      {_ids, notebook} ->
        source_entries()
        |> where([e], e.id in ^matching_ids)
        |> Repo.all()
        |> Enum.map(fn entry ->
          case Enum.find(matching_headers, &(&1.id == entry.id)) do
            nil -> entry
            header -> Map.put(entry, :notebook, header.notebook)
          end
        end)
        |> describe(true)
        |> maybe_managed(notebook)
    end
  end

  def get(_key), do: nil

  def neighbors(%Entry{} = entry) do
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

  defp maybe_managed(map, nil), do: map
  defp maybe_managed(map, notebook), do: Map.merge(map, managed_fields(notebook))

  defp managed_summary(notebook) do
    place = place_for(notebook.key)

    Map.merge(
      %{
        id: notebook.id,
        key: notebook.key,
        label: notebook.label,
        region: place.region,
        count: 0,
        place: place,
        section_count: 0,
        sections: [],
        current: notebook.current,
        numbered: notebook.numbered,
        series: notebook.series,
        year: notebook.year,
        number_label: notebook.number_label,
        description: notebook.description,
        pen: notebook.pen,
        managed: true
      },
      %{}
    )
  end

  defp managed_detail(notebook) do
    place = place_for(notebook.key)
    Map.merge(managed_summary(notebook), %{place: place, entries: [], sections: []})
  end

  defp managed_fields(notebook) do
    Map.take(managed_summary(notebook), [
      :id,
      :label,
      :current,
      :numbered,
      :series,
      :year,
      :number_label,
      :description,
      :pen,
      :managed
    ])
  end

  defp place_for(key) do
    place = Geography.for_entry(%{origin: "before", notebook: key, source_group: key})
    Map.merge(place, %{x: place.anchor_x, y: place.anchor_y, corner: nil})
  end

  defp source_entries do
    active_scope = Still.Writing.Files.discovery_scope()

    query =
      from(e in Entry,
        where: (e.origin == "before" and not is_nil(e.notebook)) or not is_nil(e.notebook_id)
      )

    if active_scope do
      where(
        query,
        [e],
        is_nil(e.file_id) or
          (e.collection_scope == ^active_scope and not e.file_missing and not e.trashed)
      )
    else
      where(query, [e], is_nil(e.file_id))
    end
  end

  defp headers do
    source_entries()
    |> join(:left, [e], n in Notebook, on: n.id == e.notebook_id)
    |> where([e, _n], (not is_nil(e.notebook) and e.notebook != "") or not is_nil(e.notebook_id))
    |> select([e, n], %{
      id: e.id,
      file_id: e.file_id,
      relative_path: e.relative_path,
      notebook_id: e.notebook_id,
      physical_notebook: n.key,
      origin: e.origin,
      notebook:
        fragment(
          "CASE WHEN ? IS NOT NULL THEN ? ELSE COALESCE(?, ?) END",
          e.file_id,
          e.notebook,
          n.key,
          e.notebook
        ),
      source_order: e.source_order,
      source_group: e.source_group,
      source_key: e.source_key,
      list_label: e.list_label,
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
        is_integer(entry.source_order) ->
          {0, entry.source_order}

        is_integer(artifact) and is_integer(piece) ->
          {0, artifact * 100 + piece}

        is_binary(entry.list_label) and entry.list_label != "" ->
          {1, natural_key(entry.list_label)}

        true ->
          {2, 0}
      end

    file_label = if Map.get(entry, :file_id), do: natural_key(entry.list_label || ""), else: nil

    unnumbered_path =
      if position == {2, 0}, do: natural_key(Map.get(entry, :relative_path) || ""), else: []

    {position, file_label, unnumbered_path, artifact || 0, piece || 0, entry.source_group || "",
     entry.source_key || "", entry.list_label || "", entry.id}
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

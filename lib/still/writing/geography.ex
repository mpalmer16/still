defmodule Still.Writing.Geography do
  @moduledoc "Stable places made from source provenance, without assigning time to Before."
  import Ecto.Query
  alias Still.Repo
  alias Still.Writing.{Entry, Notebook}

  def reference_label(place, number \\ nil) do
    notebook = Regex.replace(~r/^Lists\s+(\d.*)$/u, place.label, "Notebook \\1")

    label =
      case Map.get(place, :region) do
        :early -> "Early/" <> notebook
        :current -> "Current/" <> notebook
        _ -> notebook
      end

    section = Map.get(place, :corner)
    label = if section, do: label <> ", " <> section, else: label

    if number in [nil, ""], do: label, else: label <> ", No. " <> to_string(number)
  end

  def for_entry(nil), do: now()

  def for_entry(entry) do
    notebook = notebook_key(entry)

    if Map.get(entry, :origin) == "now" and is_nil(notebook) do
      now()
    else
      notebook = notebook || "Before"
      key = Map.get(entry, :physical_notebook) || physical_notebook_for(entry, notebook)
      region = region(key)
      seed = :erlang.phash2(key, 10_000)
      {anchor_x, anchor_y} = anchor(key, region, seed)
      source = Map.get(entry, :source_group) || key
      source_seed = :erlang.phash2(source, 10_000)
      angle = source_seed / 10_000 * :math.pi() * 2
      radius = 1.2 + rem(source_seed, 17) / 10

      %{
        key: key,
        group: key,
        label: label(key),
        region: region,
        x: Float.round(anchor_x + :math.cos(angle) * radius, 2),
        y: Float.round(anchor_y + :math.sin(angle) * radius, 2),
        anchor_x: anchor_x,
        anchor_y: anchor_y,
        tone: rem(seed, 17) - 8,
        corner:
          if(notebook != key,
            do:
              Still.Writing.NotebookSections.label(
                key,
                notebook,
                notebook |> String.split("/") |> List.last()
              )
          )
      }
    end
  end

  def places do
    active_scope = Still.Writing.Files.discovery_scope()

    query =
      from(e in Entry,
        left_join: n in Notebook,
        on: n.id == e.notebook_id,
        where: e.origin == "before" or not is_nil(e.file_id),
        select: %{
          id: e.id,
          origin: e.origin,
          notebook: fragment("COALESCE(?, ?)", n.key, e.notebook),
          source_group: e.source_group,
          source_order: e.source_order
        }
      )

    query =
      if active_scope do
        where(
          query,
          [e, _n],
          is_nil(e.file_id) or
            (e.collection_scope == ^active_scope and not e.file_missing and not e.trashed)
        )
      else
        where(query, [e, _n], is_nil(e.file_id))
      end

    Repo.all(query)
    |> Enum.reject(&is_nil(&1.notebook))
    |> Enum.group_by(&physical_notebook(&1.notebook))
    |> Enum.map(fn {_key, entries} ->
      representative = Enum.min_by(entries, &{&1.source_order || 0, &1.id})
      place = for_entry(representative)
      Map.merge(place, %{x: place.anchor_x, y: place.anchor_y, entry_id: representative.id})
    end)
    |> Enum.sort_by(&{&1.region, &1.label})
  end

  defp notebook_key(entry) do
    cond do
      is_binary(Map.get(entry, :notebook)) and Map.get(entry, :notebook) != "" ->
        Map.get(entry, :notebook)

      is_integer(Map.get(entry, :notebook_id)) ->
        case Repo.get(Notebook, entry.notebook_id) do
          nil -> nil
          notebook -> notebook.key
        end

      true ->
        nil
    end
  end

  defp physical_notebook_for(%{notebook_id: id, file_id: file_id}, notebook)
       when is_integer(id) and is_binary(file_id) do
    case Repo.get(Notebook, id) do
      %Notebook{key: key} -> key
      _ -> physical_notebook(notebook)
    end
  end

  defp physical_notebook_for(_entry, notebook), do: physical_notebook(notebook)

  def distance(left, right) do
    cond do
      now?(left) or now?(right) ->
        :now

      same_source?(left, right) ->
        :same_source

      is_binary(Map.get(left, :notebook)) and is_binary(Map.get(right, :notebook)) and
          for_entry(left).key == for_entry(right).key ->
        :same_notebook

      for_entry(left).region == for_entry(right).region ->
        :same_region

      true ->
        :far
    end
  end

  defp same_source?(left, right) do
    source = Map.get(left, :source_group)
    is_binary(source) and source == Map.get(right, :source_group)
  end

  defp now?(nil), do: true
  defp now?(entry), do: Map.get(entry, :origin) == "now" and is_nil(notebook_key(entry))

  defp now do
    %{
      key: "now",
      group: "now",
      label: "Write",
      region: :now,
      x: 50.0,
      y: 72.0,
      anchor_x: 50.0,
      anchor_y: 72.0,
      tone: 0,
      corner: nil
    }
  end

  defp physical_notebook("Current Notebooks/2026/Notebook 1/" <> _corner),
    do: "Current Notebooks/2026/Notebook 1"

  defp physical_notebook(notebook), do: notebook
  defp label(key), do: key |> String.split("/") |> List.last()
  defp region("Early Notebooks/" <> _), do: :early
  defp region("Current Notebooks/" <> _), do: :current
  defp region(_), do: :elsewhere

  # These are locations in a room, not points along a timeline.
  defp anchor("Early Notebooks/Lists " <> number, :early, seed) do
    case Integer.parse(number) do
      {index, ""} when index in 1..8 ->
        Enum.at(
          [
            {12.0, 20.0},
            {20.0, 39.0},
            {14.0, 58.0},
            {29.0, 65.0},
            {38.0, 52.0},
            {38.0, 29.0},
            {50.0, 17.0},
            {55.0, 46.0}
          ],
          index - 1
        )

      _ ->
        anchor("", :elsewhere, seed)
    end
  end

  defp anchor("Current Notebooks/2026/Notebook 1", :current, _seed), do: {75.0, 44.0}
  defp anchor("Current Notebooks/2025 Oct - Dec", :current, _seed), do: {71.0, 20.0}

  defp anchor(_key, _region, seed) do
    angle = seed / 10_000 * :math.pi() * 2
    {Float.round(50 + :math.cos(angle) * 28, 2), Float.round(37 + :math.sin(angle) * 27, 2)}
  end
end

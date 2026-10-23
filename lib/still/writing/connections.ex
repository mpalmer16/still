defmodule Still.Writing.Connections do
  @moduledoc "Literal, local ways of moving between writings, without interpreting them."
  import Ecto.Query
  alias Still.{Repo, Writing}
  alias Still.Writing.{Entry, Geography, Gravity}

  def source_siblings(%Entry{source_group: nil}), do: []

  def source_siblings(%Entry{id: id, source_group: group}) do
    Repo.all(
      from e in Entry,
        where: e.source_group == ^group and e.id != ^id,
        order_by: [asc: e.source_order, asc: e.id]
    )
  end

  def nearby(entry, opts \\ [])

  def nearby(%Entry{notebook: nil}, _opts), do: nil

  def nearby(%Entry{id: id, notebook: notebook, source_order: source_order} = entry, opts) do
    siblings = source_siblings(entry) |> Enum.map(& &1.id)
    excluded = Keyword.get(opts, :exclude_ids, [])

    key = Geography.for_entry(entry).key

    query =
      from e in Entry,
        where: e.id != ^id and e.id not in ^siblings and e.id not in ^excluded

    query =
      if key == "Current Notebooks/2026/Notebook 1" do
        prefix = key <> "/"

        where(
          query,
          [e],
          e.notebook == ^key or
            fragment("substr(?, 1, ?) = ?", e.notebook, ^String.length(prefix), ^prefix)
        )
      else
        where(query, [e], e.notebook == ^notebook)
      end

    query =
      if is_integer(source_order) do
        order_by(query, [e],
          asc: fragment("abs(COALESCE(?, ?) - ?)", e.source_order, ^source_order, ^source_order),
          asc: e.id
        )
      else
        order_by(query, [e], asc: e.id)
      end

    Repo.one(from e in query, limit: 1)
  end

  def for_entry(%Entry{} = entry) do
    siblings = source_siblings(entry)
    recent = Writing.recent_entries(limit: 16) |> Enum.map(& &1.id)
    near = nearby(entry, exclude_ids: recent) || nearby(entry)
    companions = Writing.companions(entry)

    echo_avoid =
      recent ++ Enum.map(siblings ++ companions, & &1.id) ++ if(near, do: [near.id], else: [])

    echo = echo(entry, avoid_ids: echo_avoid)

    excluded =
      [entry | siblings ++ companions]
      |> then(fn entries -> if near, do: [near | entries], else: entries end)
      |> then(fn entries -> if echo, do: [echo.entry | entries], else: entries end)
      |> Enum.map(& &1.id)

    far =
      wander_entry(exclude_ids: excluded, avoid_ids: recent, exclude_notebook: entry.notebook) ||
        wander_entry(exclude_ids: excluded, avoid_ids: recent)

    %{siblings: siblings, nearby: near, echo: echo, far: far}
  end

  @doc "A living literal echo, including writings created here and their exact authored line."
  def echo(entry, opts \\ []), do: Gravity.echo(entry, opts)

  @doc "Start somewhere in the collection, avoiding the recent path when another place is available."
  def wander_entry(opts \\ []) do
    excluded = Keyword.get(opts, :exclude_ids, [])

    recent =
      Keyword.get_lazy(opts, :avoid_ids, fn ->
        Writing.recent_entries(limit: 16) |> Enum.map(& &1.id)
      end)

    query = from e in Entry, where: e.id not in ^excluded

    query =
      case Keyword.get(opts, :exclude_notebook) do
        nil ->
          query

        notebook ->
          key = Geography.for_entry(%{origin: "before", notebook: notebook}).key
          query = where(query, [e], is_nil(e.notebook) or e.notebook != ^key)

          if key == "Current Notebooks/2026/Notebook 1" do
            prefix = key <> "/"

            where(
              query,
              [e],
              is_nil(e.notebook) or
                fragment("substr(?, 1, ?) != ?", e.notebook, ^String.length(prefix), ^prefix)
            )
          else
            query
          end
      end

    Repo.one(
      from e in query, where: e.id not in ^recent, order_by: fragment("RANDOM()"), limit: 1
    ) ||
      Repo.one(from e in query, order_by: fragment("RANDOM()"), limit: 1)
  end
end

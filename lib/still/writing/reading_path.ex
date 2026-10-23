defmodule Still.Writing.ReadingPath do
  @moduledoc "A bounded way back through reading, independent of the current writing."
  alias Still.Repo
  alias Still.Writing.{Entry, RoomState}
  @limit 32

  def visit(%Entry{} = entry, opts \\ []) do
    place = %{
      "id" => entry.id,
      "version" => Keyword.get(opts, :version),
      "query" => Still.Writing.Search.query(Keyword.get(opts, :query, "")),
      "earlier" => Keyword.get(opts, :earlier, false),
      "written" => Keyword.get(opts, :written, false)
    }

    update(fn recent ->
      path = path(recent)
      path = if same?(List.first(path), place), do: [place | tl(path)], else: [place | path]
      {Map.put(recent, "reading_path", Enum.take(path, @limit)), :ok}
    end)
  end

  def previous(entry, version \\ nil) do
    current = %{"id" => entry.id, "version" => version}
    state = Repo.get(RoomState, 1)
    after_current(path(if(state, do: state.recent, else: %{})), current) |> List.first()
  end

  def back(entry, version \\ nil) do
    current = %{"id" => entry.id, "version" => version}

    update(fn recent ->
      remaining = after_current(path(recent), current)

      if remaining == [],
        do: {recent, nil},
        else: {Map.put(recent, "reading_path", remaining), hd(remaining)}
    end)
  end

  defp path(recent) do
    recent
    |> Map.get("reading_path", [])
    |> Enum.take(@limit)
    |> Enum.filter(fn place ->
      is_map(place) && is_integer(place["id"]) && Repo.get(Entry, place["id"]) != nil
    end)
  end

  defp after_current(path, current) do
    case Enum.drop_while(path, &(!same?(&1, current))) do
      [] -> []
      [_ | rest] -> rest
    end
  end

  defp same?(nil, _), do: false
  defp same?(left, right), do: left["id"] == right["id"] && left["version"] == right["version"]

  defp update(fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        state = Repo.get(RoomState, 1) || %RoomState{id: 1}
        {recent, result} = fun.(state.recent)

        Repo.insert!(%RoomState{id: 1, recent: recent},
          on_conflict: [set: [recent: recent]],
          conflict_target: :id
        )

        result
      end)

    result
  end
end

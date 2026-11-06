defmodule Still.SearchPerformanceTest do
  use Still.DataCase

  alias Still.Writing.{Entry, Search, Version}

  test "a Find window preserves literal order and earlier-word boundaries beyond 100 results" do
    now = DateTime.utc_now()

    rows =
      for number <- 1..160 do
        %{
          body: "Café needle #{number}",
          origin: "now",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Entry, rows)

    [first | _] = Repo.all(from e in Entry, order_by: e.id)

    for _ <- 1..2 do
      Repo.insert!(%Version{
        entry_id: first.id,
        title: "Earlier title",
        body: "Earlier café needle"
      })
    end

    split = Repo.insert!(%Entry{body: "Current words"})
    Repo.insert!(%Version{entry_id: split.id, body: "Café without the other word"})
    Repo.insert!(%Version{entry_id: split.id, body: "Needle without the first word"})

    opts = [query: "cafe needle", earlier: true]
    first_page = Search.find(opts ++ [limit: 100])
    next_page = Search.find(opts ++ [offset: 100, limit: 100])
    window = Search.find_window(opts ++ [limit: 1_000])

    assert length(first_page) == 100
    assert length(window) == 161
    assert Enum.map(window, & &1.id) == Enum.map(first_page ++ next_page, & &1.id)
    assert Enum.count(window, &(&1.version != nil)) == 1
    refute Enum.any?(window, &(&1.entry.id == split.id))
  end
end

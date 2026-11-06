defmodule StillWeb.ArchiveQueryBudgetTest do
  use StillWeb.ConnCase
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Still.Repo
  alias Still.Writing.{Entry, Version}

  test "showing more current and earlier matches scans the collection once", %{conn: conn} do
    now = DateTime.utc_now()

    rows =
      for number <- 1..160 do
        %{
          body: "Synthetic café needle #{number}",
          origin: "now",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Entry, rows)

    Repo.all(from e in Entry, select: e.id)
    |> Enum.map(&%{entry_id: &1, body: "Earlier café needle", inserted_at: now})
    |> then(&Repo.insert_all(Version, &1))

    {:ok, view, _} = live(conn, ~p"/pages?q=cafe+needle&earlier=1")

    for _ <- 1..2 do
      view |> element("#more-pages") |> render_click()
    end

    queries = :atomics.new(2, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:still, :repo, :query],
        fn _, _, metadata, counter ->
          case metadata.source do
            "entries" -> :atomics.add(counter, 1, 1)
            "versions" -> :atomics.add(counter, 2, 1)
            _ -> :ok
          end
        end,
        queries
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    view |> element("#more-pages") |> render_click()

    visible =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".entry-row")
      |> LazyHTML.attribute("id")

    assert length(visible) == 160
    assert length(Enum.uniq(visible)) == 160
    assert :atomics.get(queries, 1) == 1
    assert :atomics.get(queries, 2) == 1
  end
end

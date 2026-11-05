defmodule StillWeb.CorrespondenceQueryBudgetTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Correspondence, Poems, Storage}

  @moduletag :tmp_dir

  test "tab queries stay bounded as the collection grows and external words remain visible", %{
    conn: conn,
    tmp_dir: root
  } do
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)

    for n <- 1..50,
        do: File.write!(Path.join(folder, "#{n}"), "Synthetic page #{n}\nOriginal words\n")

    assert {:ok, _} = Storage.set_folder(folder)
    assert {:ok, pieces} = Poems.list(Storage.collection_location())
    assert length(pieces) == 50
    location = Storage.collection_location()
    for piece <- pieces, do: assert(:ok = Correspondence.set_focus(location, piece.id, true))

    for n <- 1..50,
        do:
          assert(
            {:ok, _} =
              Correspondence.save_journal(Storage.collection_location(), %{
                name: "Synthetic place #{n}"
              })
          )

    {:ok, view, _} = live(conn, ~p"/correspondence")

    count = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:still, :repo, :query],
        fn _, _, _, counter ->
          :atomics.add(counter, 1, 1)
        end,
        count
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {label, path} <- [
          {"Works", "/correspondence/writing"},
          {"Places", "/correspondence/journals"},
          {"Packets", "/correspondence/packets"},
          {"Home", "/correspondence"}
        ] do
      :atomics.put(count, 1, 0)

      {elapsed, _} =
        :timer.tc(fn ->
          view |> element("nav[aria-label='Correspondence'] a", label) |> render_click()
        end)

      assert_patch(view, path)
      queries = :atomics.get(count, 1)
      assert queries < 80, "#{label} used #{queries} queries for 50 pieces"

      if System.get_env("STILL_PROFILE_CLICKS"),
        do: IO.puts("CLICK #{label}: #{Float.round(elapsed / 1000, 1)}ms #{queries} queries")
    end

    view |> element("nav[aria-label='Correspondence'] a", "Works") |> render_click()

    visible =
      render(view)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".corr-library-piece")
      |> LazyHTML.attribute("id")

    assert length(visible) == 40
    hidden = Enum.find(pieces, &(!("correspondence-work-#{&1.id}" in visible)))
    assert hidden

    view
    |> element("#correspondence-search")
    |> render_change(%{"search" => Poems.display_title(hidden)})

    assert has_element?(view, "#correspondence-work-#{hidden.id}")
    view |> element("#correspondence-search") |> render_change(%{"search" => ""})
    :atomics.put(count, 1, 0)
    view |> element("#more-works") |> render_click()
    assert :atomics.get(count, 1) == 0
    assert has_element?(view, "#correspondence-work-#{hidden.id}")
    refute has_element?(view, "#more-works")
    view |> element("nav[aria-label='Correspondence'] a", "Home") |> render_click()

    File.write!(Path.join(folder, "1"), "Changed outside Still\nCurrent external words\n")
    view |> element("nav[aria-label='Correspondence'] a", "Works") |> render_click()
    assert has_element?(view, ".corr-library-piece", "Changed outside Still")
    original = Enum.find(pieces, &(&1.relative_path == "1"))

    refute has_element?(
             view,
             ".corr-work-title[href='/correspondence/writing/#{original.id}']",
             "Synthetic page 1"
           )
  end
end

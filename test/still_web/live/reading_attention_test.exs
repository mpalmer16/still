defmodule StillWeb.ReadingAttentionTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "listening to a stanza changes its echo and Listen to the whole List restores it", %{
    conn: conn
  } do
    pad_corpus()
    source_group = Ecto.UUID.generate()
    first = historical("opal quartz orchard")
    second = historical("lantern compass resting")
    sibling = historical("lantern compass resting", source_group: source_group)

    anchor =
      historical("opal quartz orchard\n\nlantern compass resting", source_group: source_group)

    {:ok, current_writing} = Writing.save_entry(nil, "A current thought")
    {:ok, _} = Writing.remember_writing(current_writing)

    {:ok, view, _} = live(conn, ~p"/w/#{anchor.id}?read=1")

    assert has_element?(view, "#drawn-before-#{first.id}")
    refute has_element?(view, "#drawn-before-#{sibling.id}")

    render_click(element(view, "#listen-passage-3"))
    release_transition(view, anchor.id, anchor.body)

    assert has_element?(view, "#drawn-before-#{second.id}")
    refute has_element?(view, "#drawn-before-#{sibling.id}")

    render_click(element(view, "#listen-whole"))
    release_transition(view, anchor.id, anchor.body)

    assert has_element?(view, "#drawn-before-#{first.id}")
    refute has_element?(view, "#drawn-before-#{second.id}")

    assert Writing.get_entry!(anchor.id) == anchor
    assert Writing.get_entry!(first.id) == first
    assert Writing.get_entry!(second.id) == second
    assert Writing.get_entry!(sibling.id) == sibling
    assert Writing.list_versions(anchor) == []
    assert Writing.current_writing().id == current_writing.id
  end

  test "blank separators and invalid passage lines leave the listening choice unchanged", %{
    conn: conn
  } do
    first = historical("opal quartz orchard")
    second = historical("lantern compass resting")
    anchor = historical("opal quartz orchard\n\nlantern compass resting")

    {:ok, view, _} = live(conn, ~p"/w/#{anchor.id}?read=1")
    assert has_element?(view, "#drawn-before-#{first.id}")

    render_click(view, "listen_passage", %{"line" => "2"})
    assert has_element?(view, "#drawn-before-#{first.id}")

    render_click(view, "listen_passage", %{"line" => "999"})
    assert has_element?(view, "#drawn-before-#{first.id}")
    refute has_element?(view, "#drawn-before-#{second.id}")
  end

  test "the editor attention signal follows a caret stanza only for the unchanged saved body", %{
    conn: conn
  } do
    pad_corpus()
    first = historical("opal quartz orchard")
    second = historical("lantern compass resting")
    anchor = historical("opal quartz orchard\n\nlantern compass resting")
    {:ok, view, _} = live(conn, ~p"/w/#{anchor.id}?read=1")

    render_click(element(view, "button", "Change these words"))

    render_hook(view, "echo_attention", %{
      "id" => anchor.id,
      "body" => anchor.body,
      "start" => 21,
      "end" => 21
    })

    send(view.pid, {:settle_before, anchor.id, anchor.body})
    render(view)
    previous_transition = :sys.get_state(view.pid).socket.assigns.field_transition
    assert is_reference(previous_transition)

    render_hook(view, "echo_attention", %{
      "id" => anchor.id,
      "body" => anchor.body,
      "start" => 0,
      "end" => 0
    })

    send(view.pid, {:release_before, anchor.id, anchor.body, previous_transition})
    render(view)
    assert :sys.get_state(view.pid).socket.assigns.field_transition == nil
    assert :sys.get_state(view.pid).socket.assigns.field_waiting == []

    send(view.pid, {:settle_before, anchor.id, anchor.body})
    release_transition(view, anchor.id, anchor.body)
    assert has_element?(view, "#drawn-before-#{first.id}")
    refute has_element?(view, "#drawn-before-#{second.id}")

    render_hook(view, "echo_attention", %{
      "id" => anchor.id,
      "body" => "a different local draft",
      "start" => 0,
      "end" => 0
    })

    send(view.pid, {:settle_before, anchor.id, anchor.body})
    release_transition(view, anchor.id, anchor.body)
    assert has_element?(view, "#drawn-before-#{first.id}")
  end

  test "switching entries clears the active passage", %{conn: conn} do
    pad_corpus()
    first = historical("opal quartz orchard")
    second = historical("lantern compass resting")
    anchor = historical("opal quartz orchard\n\nlantern compass resting")

    {:ok, view, _} = live(conn, ~p"/w/#{anchor.id}?read=1")
    render_click(element(view, "#listen-passage-3"))
    release_transition(view, anchor.id, anchor.body)
    assert has_element?(view, "#drawn-before-#{second.id}")

    {:ok, next, _} = live(conn, ~p"/w/#{first.id}?read=1")
    assert has_element?(next, "#reading-#{first.id}")
    assert has_element?(next, "#drawn-before-#{anchor.id}")
    refute has_element?(next, "#drawn-before-#{second.id}")
  end

  defp historical(body, opts \\ []) do
    %Entry{}
    |> Entry.changeset(%{
      origin: "before",
      title: Keyword.get(opts, :title),
      body: body,
      source_group: Keyword.get(opts, :source_group),
      notebook: "Early Notebooks/Lists 1",
      source_order: System.unique_integer([:positive]),
      source_key: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp release_transition(view, id, body) do
    render(view)
    transition = :sys.get_state(view.pid).socket.assigns.field_transition
    if transition, do: send(view.pid, {:release_before, id, body, transition})
    render(view)
  end

  defp pad_corpus do
    Enum.each(1..48, fn index ->
      historical("unrelatedfiller#{index} distantwords#{index}")
    end)
  end
end

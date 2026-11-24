defmodule StillWeb.CorrespondenceAppearanceTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.Storage
  alias Still.Correspondence.Appearance
  alias Still.Writing.Appearance, as: WritingAppearance

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)
    end)

    %{folder: folder}
  end

  test "dark colors and optional light are remembered independently of the writing room", %{
    conn: conn,
    folder: folder
  } do
    path = Path.join(folder, "A page")
    bytes = "Exact words\r\n\n\t  A line stays here.\n"
    File.write!(path, bytes)
    {:ok, _} = WritingAppearance.set_color("forest")

    {:ok, view, _} = live(conn, ~p"/correspondence")
    assert has_element?(view, ".correspondence-room[data-color=graphite]:not(.is-light)")

    assert has_element?(view, "#correspondence-color option[value=sepia]", "Sepia")

    for color <- ~w(blue forest plum graphite sepia) do
      view
      |> form("#correspondence-color-form", appearance: %{color: color})
      |> render_change()

      assert has_element?(view, ".correspondence-frame[data-color=#{color}]")
      assert has_element?(view, ".correspondence-room[data-color=#{color}]:not(.is-light)")
      assert has_element?(view, "#correspondence-color option[value=#{color}][selected]")
    end

    view |> element(".corr-theme") |> render_click()
    assert Appearance.current() == %{color: "sepia", light?: true}
    assert has_element?(view, ".correspondence-frame[data-color=light]")

    {:ok, writing, _} = live(conn, ~p"/pages")
    assert has_element?(writing, ".writing-frame[data-color=forest]")
    writing |> element("#light-toggle") |> render_click()

    writing
    |> form("#room-light-form", appearance: %{color: "plum"})
    |> render_change()

    assert has_element?(writing, ".writing-frame[data-color=plum]")
    assert Appearance.current() == %{color: "sepia", light?: true}

    {:ok, reopened, _} = live(conn, ~p"/correspondence/journals")
    assert has_element?(reopened, ".correspondence-room[data-color=sepia].is-light")
    reopened |> element(".corr-theme") |> render_click()
    assert has_element?(reopened, ".correspondence-room[data-color=sepia]:not(.is-light)")

    assert {:error, :invalid_color} = Appearance.choose_color("unknown")
    assert Appearance.current() == %{color: "sepia", light?: false}
    assert WritingAppearance.color() == "plum"
    assert File.read!(path) == bytes
  end
end

defmodule StillWeb.CorrespondenceAppearanceTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Storage, Writing}
  alias Still.Correspondence.Appearance

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
    {:ok, _} = Writing.set_room_light(214)

    {:ok, view, _} = live(conn, ~p"/correspondence")
    assert has_element?(view, ".correspondence-room[data-color=graphite]:not(.is-light)")

    for color <- ~w(blue forest plum) do
      view
      |> form("#correspondence-color-form", appearance: %{color: color})
      |> render_change()

      assert has_element?(view, ".correspondence-room[data-color=#{color}]:not(.is-light)")
      assert has_element?(view, "#correspondence-color option[value=#{color}][selected]")
    end

    view |> element(".corr-theme") |> render_click()
    assert Appearance.current() == %{color: "plum", light?: true}

    {:ok, reopened, _} = live(conn, ~p"/correspondence/journals")
    assert has_element?(reopened, ".correspondence-room[data-color=plum].is-light")
    reopened |> element(".corr-theme") |> render_click()
    assert has_element?(reopened, ".correspondence-room[data-color=plum]:not(.is-light)")

    assert {:error, :invalid_color} = Appearance.choose_color("unknown")
    assert Appearance.current() == %{color: "plum", light?: false}
    assert Writing.room_light() == 214
    assert File.read!(path) == bytes
  end
end

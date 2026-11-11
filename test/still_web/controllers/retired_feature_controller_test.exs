defmodule StillWeb.RetiredFeatureControllerTest do
  use StillWeb.ConnCase

  test "old Threads links return to writing", %{conn: conn} do
    assert conn |> get(~p"/threads?word=window") |> redirected_to() == ~p"/"
  end

  test "the room offers no Threads entry points", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    refute html =~ "open-threads"
    refute html =~ "Follow a word"
  end
end

defmodule StillWeb.NativeStorageControllerTest do
  use StillWeb.ConnCase

  alias Still.Storage
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous_token = Application.get_env(:still, :native_control_token)
    previous_state = Application.get_env(:still, :storage_state_directory)
    token = Base.encode16(:crypto.strong_rand_bytes(32))
    Application.put_env(:still, :native_control_token, token)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    folder = Path.join(root, "backups")
    File.mkdir_p!(folder)

    on_exit(fn ->
      Application.put_env(:still, :native_control_token, previous_token)
      Application.put_env(:still, :storage_state_directory, previous_state)
    end)

    %{token: token, folder: folder}
  end

  test "native status and mutations reject absent, wrong, or disabled tokens", %{
    conn: conn,
    folder: folder
  } do
    assert conn |> get(~p"/native/storage") |> json_response(403)

    assert conn
           |> put_req_header("x-still-native-token", "wrong")
           |> put(~p"/native/storage", %{folder: folder})
           |> json_response(403)

    assert Storage.status().folder == nil
    Application.delete_env(:still, :native_control_token)
    assert conn |> get(~p"/native/storage") |> json_response(403)
  end

  test "authorized native controls share persistent browser configuration and backup status", %{
    conn: conn,
    token: token,
    folder: folder
  } do
    authorized = put_req_header(conn, "x-still-native-token", token)
    initial = authorized |> get(~p"/native/storage") |> json_response(200)
    refute initial["configured"]
    configured = authorized |> put(~p"/native/storage", %{folder: folder}) |> json_response(200)
    assert configured["folder"] == folder
    backed = authorized |> post(~p"/native/backup", %{}) |> json_response(200)
    assert File.regular?(backed["last_backup"]["path"])
    refute backed["changed"]
    assert Storage.status().last_backup.path == backed["last_backup"]["path"]
    cleared = authorized |> delete(~p"/native/storage") |> json_response(200)
    refute cleared["configured"]
    assert cleared["last_backup"] == nil
  end

  test "failed native backup is an error, never a success response", %{conn: conn, token: token} do
    response =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/backup", %{})
      |> json_response(422)

    assert is_binary(response["error"])
    assert Storage.status().last_backup == nil
  end
end

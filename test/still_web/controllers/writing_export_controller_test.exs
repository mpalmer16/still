defmodule StillWeb.WritingExportControllerTest do
  use StillWeb.ConnCase
  alias Still.{Poems, Storage}
  alias Still.Writing.Exports
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.get_env(:still, :storage_state_directory)
    previous_token = Application.get_env(:still, :native_control_token)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    token = String.duplicate("synthetic-native-token-", 3)
    Application.put_env(:still, :native_control_token, token)
    folder = Path.join(root, "writing")
    File.mkdir_p!(folder)
    {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      Application.put_env(:still, :storage_state_directory, previous)
      Application.put_env(:still, :native_control_token, previous_token)
    end)

    location = Storage.collection_location()

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        body: "Exact original words",
        relative_path: "Essay.txt"
      })

    {:ok, prepared} = Exports.prepare(location, piece, :pdf)

    ticket =
      Phoenix.Token.sign(StillWeb.Endpoint, "writing-pdf-export", %{
        id: piece.id,
        scope: location.scope,
        source_token: prepared.source_token
      })

    %{token: token, ticket: ticket, piece: piece, prepared: prepared}
  end

  test "requires native authorization and a valid source-bound export request", %{
    conn: conn,
    ticket: ticket,
    token: token
  } do
    body = %{ticket: ticket, pdf: Base.encode64("%PDF-1.4\nSynthetic fixture\n%%EOF")}
    assert conn |> post(~p"/native/exports/pdf", body) |> json_response(403)

    result =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf", %{body | ticket: "invalid"})
      |> json_response(422)

    assert result["error"] =~ "expired"
  end

  test "writes the native PDF bytes outside writing and leaves the original exact", %{
    conn: conn,
    token: token,
    ticket: ticket,
    piece: piece,
    prepared: prepared
  } do
    bytes = "%PDF-1.4\nSynthetic fixture\n%%EOF"

    result =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf", %{ticket: ticket, pdf: Base.encode64(bytes)})
      |> json_response(200)

    assert result["path"] == prepared.path
    assert File.read!(prepared.path) == bytes
    assert File.read!(piece.path) == piece.body
  end

  test "native renderer fetches verified input instead of accepting page-supplied words", %{
    conn: conn,
    token: token,
    ticket: ticket,
    piece: piece
  } do
    assert conn |> post(~p"/native/exports/pdf/input", %{ticket: ticket}) |> json_response(403)

    result =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf/input", %{
        ticket: ticket,
        segments: [%{body: "Altered client words"}]
      })
      |> json_response(200)

    assert Enum.map_join(result["segments"], & &1["body"]) == piece.body
  end

  test "refuses a PDF if the writing changed after preparation", %{
    conn: conn,
    token: token,
    ticket: ticket,
    piece: piece,
    prepared: prepared
  } do
    File.write!(piece.path, "Changed outside Still")

    result =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf", %{
        ticket: ticket,
        pdf: Base.encode64("%PDF-1.4\nFixture\n%%EOF")
      })
      |> json_response(422)

    assert result["error"] =~ "changed"
    refute File.exists?(prepared.path)
    assert File.read!(piece.path) == "Changed outside Still"
  end
end

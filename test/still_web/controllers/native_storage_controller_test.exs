defmodule StillWeb.NativeStorageControllerTest do
  use StillWeb.ConnCase

  alias Still.{Correspondence, Poems, Storage}
  alias Still.Correspondence.PacketExports
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

  test "packet PDF input is source-bound and returns ordered manuscripts with page breaks", %{
    conn: conn,
    token: token,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, first} = Poems.save(location, Poems.new(location), %{body: "First manuscript"})
    {:ok, second} = Poems.save(location, Poems.new(location), %{body: "Second manuscript"})
    {:ok, journal} = Correspondence.save_journal(location, %{name: "Synthetic journal"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Packet title",
        journal_id: journal.id,
        piece_ids: [first.id, second.id],
        preparation_notes: "Private note",
        cover_letter: "Private letter"
      })

    {:ok, prepared} = PacketExports.prepare(location, packet.id)

    ticket =
      Phoenix.Token.sign(StillWeb.Endpoint, "writing-pdf-export", %{
        scope: location.scope,
        id: packet.id,
        source_token: prepared.source_token,
        request_id: Ecto.UUID.generate(),
        kind: "packet"
      })

    result =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf/input", %{ticket: ticket})
      |> json_response(200)

    assert result["title"] == "Packet title"
    assert Enum.map(result["segments"], & &1["body"]) == [first.body, second.body]
    assert Enum.map(result["segments"], & &1["page_break_before"]) == [false, true]
    refute inspect(result) =~ "Private"

    bytes = "%PDF-1.4\nSynthetic packet\n%%EOF"

    assert {:ok, published_path} =
             PacketExports.publish_pdf(location, packet.id, bytes, prepared.source_token)

    assert published_path == prepared.path

    saved =
      recycle(conn)
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf", %{
        ticket: ticket,
        pdf: Base.encode64(bytes)
      })
      |> json_response(200)

    assert saved["path"] == prepared.path
    assert File.read!(prepared.path) == "%PDF-1.4\nSynthetic packet\n%%EOF"
  end

  test "packet ticket rejects another collection and stale reviewed writing", %{
    conn: conn,
    token: token,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, piece} = Poems.save(location, Poems.new(location), %{body: "Original words"})
    {:ok, journal} = Correspondence.save_journal(location, %{name: "Synthetic journal"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Stale packet",
        journal_id: journal.id,
        piece_ids: [piece.id]
      })

    {:ok, prepared} = PacketExports.prepare(location, packet.id)

    ticket =
      Phoenix.Token.sign(StillWeb.Endpoint, "writing-pdf-export", %{
        scope: "other-collection",
        id: packet.id,
        source_token: prepared.source_token,
        request_id: Ecto.UUID.generate(),
        kind: "packet"
      })

    wrong_scope =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf/input", %{ticket: ticket})
      |> json_response(422)

    assert wrong_scope["error"] =~ "expired"

    File.write!(piece.path, "Changed without packet review")

    stale_ticket =
      Phoenix.Token.sign(StillWeb.Endpoint, "writing-pdf-export", %{
        scope: location.scope,
        id: packet.id,
        source_token: prepared.source_token,
        request_id: Ecto.UUID.generate(),
        kind: "packet"
      })

    stale =
      recycle(conn)
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf/input", %{ticket: stale_ticket})
      |> json_response(422)

    assert stale["error"] =~ "changed after packet preparation"
  end

  test "packet ticket keeps submitted words available after source removal", %{
    conn: conn,
    token: token,
    folder: folder
  } do
    {:ok, _} = Storage.set_folder(folder)
    location = Storage.collection_location()
    {:ok, piece} = Poems.save(location, Poems.new(location), %{body: "Frozen words"})
    {:ok, journal} = Correspondence.save_journal(location, %{name: "Synthetic journal"})

    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: "Frozen packet",
        journal_id: journal.id,
        piece_ids: [piece.id]
      })

    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-11-11")
    {:ok, prepared} = PacketExports.prepare(location, sent.id)
    File.rm!(piece.path)

    ticket =
      Phoenix.Token.sign(StillWeb.Endpoint, "writing-pdf-export", %{
        scope: location.scope,
        id: sent.id,
        source_token: prepared.source_token,
        request_id: Ecto.UUID.generate(),
        kind: "packet"
      })

    result =
      conn
      |> put_req_header("x-still-native-token", token)
      |> post(~p"/native/exports/pdf/input", %{ticket: ticket})
      |> json_response(200)

    assert result["segments"] |> hd() |> Map.fetch!("body") == "Frozen words"
  end
end

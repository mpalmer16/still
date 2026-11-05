defmodule Still.Correspondence.PlaceImportTest do
  use Still.DataCase, async: false
  alias Still.{Correspondence, LocalRecord, Repo, Poems, Storage}
  alias Still.Correspondence.PlaceImport

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    old = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    collection = Path.join(root, "collection")
    File.mkdir_p!(collection)
    {:ok, _} = Storage.set_folder(collection)
    on_exit(fn -> Application.put_env(:still, :storage_state_directory, old) end)
    %{root: root, collection: collection, location: Storage.collection_location()}
  end

  test "examples match, validation is read-only, and names-only import survives reopening", %{
    location: location,
    collection: folder
  } do
    assert Jason.decode!(PlaceImport.example()) ==
             Jason.decode!(File.read!("docs/places-import-example.json"))

    json =
      Jason.encode!([
        %{name: "  Synthetic Review  ", notes: "Two lines\n  and an indent — é", website: ""}
      ])

    assert {:ok, plan} = PlaceImport.preview(location, json)
    refute File.exists?(Path.join(folder, "correspondence"))
    assert %{imported: ["Synthetic Review"], skipped: [], error: nil} = PlaceImport.commit(plan)
    assert {:ok, [journal]} = Correspondence.journals(Storage.collection_location())
    assert journal.notes == "Two lines\n  and an indent — é"
    assert journal.website == nil
    refute journal.verified
    refute journal.inactive
    assert {:ok, same} = Correspondence.journal(location, journal.id)
    assert same == journal
    assert %{imported: [], skipped: ["Synthetic Review"], error: nil} = PlaceImport.commit(plan)
  end

  test "whole-file validation rejects malformed, unknown, mistyped, unsafe, and oversized input",
       %{location: location, collection: folder} do
    for json <- [
          "[",
          "[]",
          "{}",
          Jason.encode!([%{name: "Good"}, %{name: "Bad", verified: true}]),
          Jason.encode!([%{name: ""}]),
          Jason.encode!([%{name: "A", notes: nil}]),
          Jason.encode!([%{name: "A", shortlisted: "true"}]),
          Jason.encode!([%{name: "A", website: "file:///tmp/no"}]),
          Jason.encode!([%{name: "A", simultaneous_policy: "maybe"}]),
          Jason.encode!([%{name: "A", notes: "\0"}]),
          Jason.encode!([%{name: "A", inactive: true}]),
          Jason.encode!(["A"]),
          Jason.encode!(List.duplicate(%{name: "A"}, 201)),
          String.duplicate(" ", 1_048_577),
          <<255>>
        ] do
      assert {:error, _} = PlaceImport.preview(location, json)
      refute File.exists?(Path.join(folder, "correspondence"))
    end

    assert {:error, "Place 2: " <> _} = PlaceImport.parse(~s([{"name":"Good"},{}]))
  end

  test "existing and repeated names are skipped including inactive places, never updated", %{
    location: location
  } do
    {:ok, old} =
      Correspondence.save_journal(location, %{name: "Existing", notes: "keep me", inactive: true})

    assert {:ok, plan} =
             PlaceImport.preview(
               location,
               Jason.encode!([
                 %{name: " existing ", notes: "replace"},
                 %{name: "New"},
                 %{name: "NEW"}
               ])
             )

    assert plan.skipped == ["existing", "NEW"]
    assert %{imported: ["New"], error: nil} = PlaceImport.commit(plan)
    assert {:ok, unchanged} = Correspondence.journal(location, old.id)
    assert unchanged == old
  end

  test "concurrent additions are skipped and stale or missing collections cannot receive an import",
       %{location: location, root: root, collection: folder} do
    {:ok, plan} = PlaceImport.preview(location, ~s([{"name":"Concurrent"}]))
    {:ok, existing} = Correspondence.save_journal(location, %{name: "Concurrent", notes: "keep"})
    assert %{imported: [], skipped: ["Concurrent"], error: nil} = PlaceImport.commit(plan)
    assert {:ok, ^existing} = Correspondence.journal(location, existing.id)
    {:ok, plan} = PlaceImport.preview(location, ~s([{"name":"Later"}]))
    File.rename!(folder, folder <> "-offline")
    assert %{imported: [], error: error} = PlaceImport.commit(plan)
    assert is_binary(error)
    File.rename!(folder <> "-offline", folder)
    other = Path.join(root, "other")
    File.mkdir_p!(other)
    {:ok, _} = Storage.set_folder(other)
    assert %{imported: [], error: error} = PlaceImport.commit(plan)
    assert is_binary(error)
    assert File.ls!(other) == []

    assert {:error, _} =
             PlaceImport.preview(
               Storage.collection_location() |> Map.put(:configured, false),
               "[]"
             )

    {:ok, _} = Storage.clear_folder()

    assert {:error, _} =
             PlaceImport.preview(Storage.collection_location(), ~s([{"name":"No folder"}]))
  end

  test "a failed addition reports actual completed work and preserves earlier additions", %{
    location: location
  } do
    {:ok, plan} =
      PlaceImport.preview(location, ~s([{"name":"First"},{"name":"Second"},{"name":"Third"}]))

    [first, second, third] = plan.places

    # Simulate a later save being rejected; the completed prefix must never be rolled back or reported as total success.
    plan = %{plan | places: [first, %{second | website: "invalid"}, third]}
    assert %{imported: ["First"], error: error} = PlaceImport.commit(plan)
    assert error =~ "Could not add Second"
    assert {:ok, [%{name: "First"}]} = Correspondence.journals(location)

    {:ok, retry} =
      PlaceImport.preview(location, ~s([{"name":"First"},{"name":"Second"},{"name":"Third"}]))

    assert %{imported: ["Second", "Third"], skipped: ["First"], error: nil} =
             PlaceImport.commit(retry)
  end

  test "deactivation retains sent snapshots and responses, rejects stale toggles, and is reversible",
       %{location: location} do
    {:ok, journal} =
      Correspondence.save_journal(location, %{name: "Past Place", shortlisted: true})

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{title: "Synthetic", body: "Exact\n  words"})

    attrs = %{journal_id: journal.id, piece_ids: [piece.id], title: "Synthetic packet"}
    {:ok, packet} = Correspondence.save_packet(location, attrs)
    {:ok, sent} = Correspondence.submit(location, packet.id, packet.token, "2026-10-24")
    {:ok, draft} = Correspondence.save_packet(location, attrs)

    assert {:ok, inactive} =
             Correspondence.set_journal_active(location, journal.id, journal.token, false)

    assert inactive.inactive
    assert inactive.id == journal.id
    assert inactive.shortlisted

    assert {:error, _} =
             Correspondence.set_journal_active(location, journal.id, journal.token, true)

    assert {:error, _} = Correspondence.save_packet(location, attrs)
    assert {:error, _} = Correspondence.submit(location, draft.id, draft.token, "2026-10-24")

    assert {:ok, replied} =
             Correspondence.respond(
               location,
               sent.id,
               sent.token,
               "declined",
               "Later",
               "2026-10-24"
             )

    assert replied.snapshot == sent.snapshot
    assert replied.snapshot.pieces |> hd() |> Map.fetch!(:body) == piece.body

    assert {:ok, edited} =
             Correspondence.save_journal(
               location,
               %{name: "Past Place", notes: "Updated notes"},
               inactive.id,
               inactive.token
             )

    assert edited.inactive

    assert {:ok, active} =
             Correspondence.set_journal_active(location, edited.id, edited.token, true)

    refute active.inactive
    assert {:ok, _} = Correspondence.save_packet(location, attrs)
  end

  test "an unavailable collection leaves existing places intact and reports the failed import", %{
    location: location,
    collection: folder
  } do
    {:ok, existing} =
      Correspondence.save_journal(location, %{name: "Keep", notes: "Exact existing notes"})

    {:ok, plan} = PlaceImport.preview(location, ~s([{"name":"New"}]))
    moved = folder <> "-moved"
    File.rename!(folder, moved)
    assert %{imported: [], error: error} = PlaceImport.commit(plan)
    assert is_binary(error)
    File.rename!(moved, folder)
    assert {:ok, [^existing]} = Correspondence.journals(Storage.collection_location())
    {:ok, valid_plan} = PlaceImport.preview(location, ~s([{"name":"New"}]))
    assert %{imported: ["New"], error: nil} = PlaceImport.commit(valid_plan)
  end

  test "legacy shaped place data defaults to active and malformed flags are rejected", %{
    location: location
  } do
    {:ok, journal} = Correspondence.save_journal(location, %{name: "Older Place"})

    row =
      Repo.get_by!(LocalRecord, scope: location.scope, kind: "journal", record_key: journal.id)

    row |> LocalRecord.changeset(%{data: Map.delete(row.data, "inactive")}) |> Repo.update!()
    assert {:ok, old} = Correspondence.journal(location, journal.id)
    refute old.inactive
    malformed = Map.put(Map.delete(row.data, "inactive"), "inactive", "false")

    Repo.get_by!(LocalRecord, scope: location.scope, kind: "journal", record_key: journal.id)
    |> LocalRecord.changeset(%{data: malformed})
    |> Repo.update!()

    assert {:error, _} = Correspondence.journal(location, journal.id)
  end

  test "keywords and reach import, explain literal echoes, and persist personal possibilities", %{
    location: location
  } do
    json =
      Jason.encode!([
        %{
          name: "Echo Review",
          keywords: "winter, rural life, art, café, WINTER",
          reach: "stretch",
          reach_note: "Read an issue first"
        }
      ])

    {:ok, plan} = PlaceImport.preview(location, json)
    assert %{imported: ["Echo Review"], error: nil} = PlaceImport.commit(plan)
    {:ok, [journal]} = Correspondence.journals(location)

    {:ok, piece} =
      Poems.save(location, Poems.new(location), %{
        title: "WINTER",
        body: "Rural life beside the café. A cart."
      })

    {:ok, other} =
      Poems.save(location, Poems.new(location), %{title: "Elsewhere", body: "Quiet water"})

    assert Correspondence.matching_keywords(journal, piece) == ["winter", "rural life", "café"]
    assert Correspondence.matching_keywords(journal, other) == []

    assert [%{piece: ^piece, manual: false}] =
             Correspondence.pieces_to_consider(journal, [piece, other])

    assert [%{journal: ^journal}] = Correspondence.places_to_consider([journal], piece)
    assert [] = Correspondence.places_to_consider([%{journal | inactive: true}], piece)

    assert {:error, _} =
             Correspondence.set_possible_piece(
               location,
               journal.id,
               journal.token,
               Ecto.UUID.generate(),
               true
             )

    {:ok, kept} =
      Correspondence.set_possible_piece(location, journal.id, journal.token, other.id, true)

    assert {:error, _} =
             Correspondence.set_possible_piece(
               location,
               journal.id,
               journal.token,
               piece.id,
               true
             )

    {:ok, duplicate} =
      Correspondence.set_possible_piece(location, kept.id, kept.token, other.id, true)

    assert duplicate.possible_piece_ids == [other.id]
    # An editor that does not send the new fields must preserve them.
    {:ok, edited} =
      Correspondence.save_journal(
        location,
        %{name: "Echo Review", notes: "New note"},
        duplicate.id,
        duplicate.token
      )

    assert edited.keywords == journal.keywords
    assert edited.reach == "stretch"
    assert edited.reach_note == "Read an issue first"
    assert edited.possible_piece_ids == [other.id]
    {:ok, reopened} = Correspondence.journal(location, journal.id)
    assert [%{manual: true, keywords: []}] = Correspondence.pieces_to_consider(reopened, [other])

    {:ok, inactive} =
      Correspondence.set_journal_active(location, reopened.id, reopened.token, false)

    assert inactive.possible_piece_ids == [other.id]

    {:ok, removed} =
      Correspondence.set_possible_piece(location, inactive.id, inactive.token, other.id, false)

    assert Correspondence.pieces_to_consider(removed, [other]) == []
    assert {:ok, ^piece} = Poems.get(location, piece.id)

    row =
      Repo.get_by!(LocalRecord, scope: location.scope, kind: "journal", record_key: journal.id)

    legacy_data = Map.drop(row.data, ["keywords", "reach", "reach_note", "possible_piece_ids"])
    row |> LocalRecord.changeset(%{data: legacy_data}) |> Repo.update!()
    assert {:ok, legacy} = Correspondence.journal(location, journal.id)
    assert legacy.keywords == nil
    assert legacy.reach == "unknown"
    assert legacy.possible_piece_ids == []

    for {key, value} <- [
          {"keywords", []},
          {"reach", "easy"},
          {"reach_note", false},
          {"possible_piece_ids", ["bad"]}
        ] do
      current =
        Repo.get_by!(LocalRecord, scope: location.scope, kind: "journal", record_key: journal.id)

      current
      |> LocalRecord.changeset(%{data: Map.put(legacy_data, key, value)})
      |> Repo.update!()

      assert {:error, _} = Correspondence.journal(location, journal.id)
    end
  end

  test "new import fields reject invalid types and leave an empty collection untouched", %{
    location: location,
    collection: folder
  } do
    for fields <- [
          %{keywords: []},
          %{reach: "easy"},
          %{reach_note: true},
          %{possible_piece_ids: []}
        ] do
      assert {:error, _} =
               PlaceImport.preview(location, Jason.encode!([Map.put(fields, :name, "Bad")]))

      refute File.exists?(Path.join(folder, "correspondence"))
    end
  end
end

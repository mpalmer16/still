defmodule Still.ListInterpretationTest do
  use Still.DataCase

  alias Still.{Preservation, Repo, Writing}
  alias Still.Writing.{Entry, RoomState, Version}

  test "a suggested title leaves mixed words and shape untouched" do
    body =
      "rain: furnace: refrigerator:\n\tdog moving upstairs:\n• a comma, another comma\n\nexcept sometimes it isn't really quiet at all\n"

    raw = "Things I notice when everything is quiet\n\n" <> body

    assert %{original_body: ^raw, title: "Things I notice when everything is quiet", body: ^body} =
             Writing.list_interpretation(raw)

    bullets = "• rain\n• furnace\n\nplain writing stays here"
    assert %{body: ^bullets} = Writing.list_interpretation("House sounds\n" <> bullets)

    assert %{body: "rain, furnace, refrigerator"} =
             Writing.list_interpretation("House sounds\n\nrain, furnace, refrigerator")
  end

  test "title suggestions preserve punctuation and line endings rather than historical conventions" do
    raw = "House & rain — near 4am\r\n\r\nwater: waiting:\r\n\t—not a removable dash\r\n"

    assert %{original_body: ^raw, title: "House & rain — near 4am", body: body} =
             Writing.list_interpretation(raw)

    assert body == "water: waiting:\r\n\t—not a removable dash\r\n"
  end

  test "ambiguous prose, verse openings, list items, times and URLs remain ordinary writing" do
    for raw <- [
          "water:\nwaiting:\n",
          "The night is wide\nand everything is breathing\n",
          "An opening.\n\nrain: wind:",
          "A thought\n\nit was raining, and I stayed home",
          "Links\n\nhttps://example.test/water\nmailto:writer@example.test",
          "Hours\n\n04:30\n12:45",
          "One short opening\n• one possible item",
          "Only words",
          "",
          "\nAn opening\n\nwater: waiting:"
        ] do
      assert Writing.list_interpretation(raw) == nil
    end
  end

  test "List intent is optional metadata and does not constrain prose or replace provenance" do
    source = %{"original_body" => "earlier source", "artifacts" => [%{"path" => "old.doc"}]}
    entry = Repo.insert!(%Entry{body: "water:", source: source})

    {:ok, list} =
      Writing.save_entry(entry, "water:\nexcept it became prose", writing_form: "list")

    assert Writing.list_entry?(list)
    assert list.source == Map.put(source, "writing_form", "list")

    {:ok, same} = Writing.save_entry(list, list.body, source: %{"original_body" => "discarded"})
    assert same.source == list.source
    assert same.lock_version == list.lock_version

    {:ok, plain} = Writing.save_entry(nil, "plain writing")
    refute Writing.list_entry?(plain)
    assert plain.source == %{}
    assert Writing.list_entry?(%Entry{origin: "before"})

    assert {:error, :invalid_writing_form} =
             Writing.save_entry(list, "cannot overwrite", writing_form: "items")

    assert Writing.get_entry!(list.id).body == list.body
  end

  @tag :tmp_dir
  test "accepting before first autosave checkpoints complete pasted words and exports them", %{
    tmp_dir: dir
  } do
    raw = "House sounds\n\nrain: furnace:\n\tdog moving upstairs:\n\nprose <still belongs>\n"
    {:ok, interpreted} = Writing.accept_list_title(nil, raw)

    assert interpreted.title == "House sounds"
    assert interpreted.body == "rain: furnace:\n\tdog moving upstairs:\n\nprose <still belongs>\n"
    assert interpreted.origin == "now"
    assert Writing.list_entry?(interpreted)
    assert Repo.aggregate(Entry, :count) == 1
    assert [%{body: ^raw, title: nil} = original] = Writing.list_versions(interpreted)

    export = dir |> Preservation.export!() |> File.read!() |> Jason.decode!()
    assert export["format"] == "still-1"

    assert [
             %{
               "body" => body,
               "source" => %{"writing_form" => "list"},
               "earlier_versions" => versions
             }
           ] =
             export["entries"]

    assert body == interpreted.body
    assert [%{"body" => ^raw, "title" => nil}] = versions

    {:ok, restored} = Writing.restore_version(interpreted, original.id)
    assert restored.body == raw
    assert restored.title == nil
    assert Writing.list_entry?(restored)
    assert Enum.any?(Writing.list_versions(restored), &(&1.body == interpreted.body))
  end

  test "accepting saves the latest unsaved text before extracting its title" do
    {:ok, saved} = Writing.save_entry(nil, "House sounds\n\nrain:", writing_form: "list")
    raw = saved.body <> " furnace:\n\tnew words not yet autosaved\n"
    {:ok, interpreted} = Writing.accept_list_title(saved, raw)

    versions = Writing.list_versions(interpreted)
    assert Enum.any?(versions, &(&1.body == raw and &1.title == nil))
    assert Enum.any?(versions, &(&1.body == saved.body))
    assert interpreted.body == "rain: furnace:\n\tnew words not yet autosaved\n"
  end

  test "a title already written by the writer is never replaced by a suggestion" do
    raw = "House sounds\n\nrain: furnace:"
    assert {:error, :title_already_set} = Writing.accept_list_title(nil, raw, title: "My title")
    assert Repo.aggregate(Entry, :count) == 0

    {:ok, entry} = Writing.save_entry(nil, raw, title: "My title")
    assert {:error, :title_already_set} = Writing.accept_list_title(entry, raw, title: "")
    assert Writing.get_entry!(entry.id).title == "My title"
    assert Writing.list_versions(entry) == []
  end

  test "stale acceptance cannot replace current words or add an interpretation checkpoint" do
    raw = "House sounds\n\nrain: furnace:"
    {:ok, seen} = Writing.save_entry(nil, raw)
    {:ok, current} = Writing.save_entry(seen, raw <> "\nSomeone continued writing")
    count = Repo.aggregate(Version, :count)

    assert {:error, {:stale, latest}} = Writing.accept_list_title(seen, raw)
    assert latest.id == current.id
    assert latest.body == current.body
    assert latest.title == nil
    assert Repo.aggregate(Version, :count) == count
    assert Writing.get_entry!(current.id).source == %{}
  end

  test "failed interpretation leaves no partial entry or checkpoint" do
    assert {:error, :no_title_suggestion} = Writing.accept_list_title(nil, "simply keep writing")
    oversized = "House sounds\n\n" <> String.duplicate("water: ", 15_000)
    assert {:error, %Ecto.Changeset{}} = Writing.accept_list_title(nil, oversized)
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(Version, :count) == 0
  end

  test "a pending List survives visits while room settings and the recent path remain independent" do
    {:ok, old_writer} = Writing.save_entry(nil, "a saved page")
    {:ok, visited} = Writing.save_entry(nil, "a page to wander through")
    {:ok, _} = Writing.set_room_light(156)
    {:ok, _} = Writing.set_room_letters(29)
    {:ok, _} = Writing.remember_visit(old_writer)
    {:ok, _} = Writing.remember_writing(old_writer)
    {:ok, _} = Writing.begin_writing(nil, writing_form: "list")

    assert Writing.current_writing() == nil
    assert Writing.current_list_draft?()
    {:ok, _} = Writing.remember_visit(visited)
    assert Writing.current_list_draft?()
    assert Enum.map(Writing.recent_entries(), & &1.id) == [visited.id, old_writer.id]
    assert Writing.room_light() == 156
    assert Writing.room_letters() == 29

    {:ok, list} = Writing.save_entry(nil, "water:", writing_form: "list")
    {:ok, _} = Writing.remember_writing(list)
    refute Writing.current_list_draft?()
    assert Writing.current_writing().id == list.id
    assert Repo.get!(RoomState, 1).recent["ids"] == [visited.id, old_writer.id]

    {:ok, _} = Writing.begin_writing(nil, writing_form: "list")
    {:ok, _} = Writing.begin_writing()
    refute Writing.current_list_draft?()
    assert Writing.room_light() == 156
    assert Writing.room_letters() == 29
  end

  test "pending List beside intent survives visits and rejects invalid forms without changing the cursor" do
    {:ok, source} = Writing.save_entry(nil, "an older echo")
    {:ok, _} = Writing.begin_writing(source, writing_form: "list")
    {:ok, _} = Writing.remember_visit(source)
    assert Writing.current_beside().id == source.id
    assert Writing.current_list_draft?()

    assert {:error, :invalid_writing_form} = Writing.begin_writing(nil, writing_form: "items")
    assert Writing.current_beside().id == source.id
    assert Writing.current_list_draft?()
    assert Repo.aggregate(Entry, :count) == 1
  end
end

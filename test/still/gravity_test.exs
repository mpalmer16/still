defmodule Still.GravityTest do
  use Still.DataCase
  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "synthetic uncommon language draws a piece while ordinary writing stays quiet" do
    Still.SyntheticCorpus.import!()

    for {words, title} <- [
          {"cobalt zeppelin sprocket", "Cobalt:Zeppelin:Sprocket:"},
          {"saffron anvil prism", "Saffron:Anvil:Prism:"},
          {"zircon caliper lattice", "Zircon:Caliper:Lattice:"},
          {"amber turbine spindle", "Amber:Turbine:Spindle:"}
        ] do
      assert drawn = Writing.gravity(words)
      assert drawn.entry.title == title
      assert drawn.line in String.split(drawn.entry.body, "\n")
      assert drawn.strength > 0
    end

    for words <- [
          "I am making dinner and thinking about the world.",
          "This meeting starts tomorrow at four.",
          "I bought a new umbrella for the rainy season.",
          "I want to follow the trees home.",
          "I remember the way the city looked when",
          "My doctor appointment is tomorrow morning.",
          "sprocket sprocket sprocket sprocket"
        ] do
      assert Writing.gravity(words) == nil
    end

    assert Repo.aggregate(Entry, :count) == 540
    assert Repo.aggregate(Still.Writing.Version, :count) == 0
    assert Writing.last_visited() == nil
    assert Writing.current_writing() == nil
  end

  test "a strong attraction recedes as the words move elsewhere" do
    source = piece("An:Orchard:", "opal quartz orchard\nA line to remain unchanged")
    words = "The opal quartz orchard."
    original = Writing.gravity(words)
    assert original.entry.id == source.id

    still_near =
      Writing.gravity(words <> String.duplicate(" unwrittenword", 15),
        previous_id: original.entry.id
      )

    assert still_near.entry.id == original.entry.id
    assert still_near.strength < original.strength

    assert Writing.gravity(words <> String.duplicate(" unwrittenword", 80),
             previous_id: original.entry.id
           ) == nil

    assert Writing.gravity("", previous_id: original.entry.id) == nil
  end

  test "comparable echoes hold still but changed words can pull something else close" do
    first = piece("Opal:Quartz:", "opal quartz orchard")
    other = piece("Another:Orchard:", "opal quartz orchard lantern compass")
    assert Writing.gravity("opal quartz orchard").entry.id == first.id
    uncertain = "lantern " <> String.duplicate("unwrittenword ", 20) <> "opal quartz orchard"
    assert Writing.gravity(uncertain).entry.id == other.id
    assert Writing.gravity(uncertain, previous_id: first.id).entry.id == first.id
    assert Writing.gravity("lantern compass", previous_id: first.id).entry.id == other.id
    assert Writing.gravity("lantern compass", exclude_ids: [other.id]) == nil
  end

  test "the field admits two independent pulls and keeps their homes as emphasis changes" do
    first = piece("An:Orchard:", "opal quartz orchard")
    other = piece("A:Lantern:", "lantern compass resting")
    third = piece("A:Telescope:", "celluloid telescopes unfolding")
    words = "opal quartz orchard. lantern compass resting."
    field = Writing.gravity_field(words)
    assert MapSet.new(Enum.map(field, & &1.entry.id)) == MapSet.new([first.id, other.id])

    shifted =
      Writing.gravity_field("lantern compass resting. opal quartz orchard.", previous: field)

    assert length(shifted) == 2

    for fragment <- shifted do
      prior = Enum.find(field, &(&1.entry.id == fragment.entry.id))
      assert fragment.side == prior.side
      assert fragment.height == prior.height
      assert fragment.line in String.split(fragment.entry.body, "\n")
    end

    crowded =
      Writing.gravity_field(words <> " celluloid telescopes unfolding.", previous: shifted)

    assert length(crowded) <= 2
    assert Enum.all?(crowded, &(&1.entry.id in [first.id, other.id, third.id]))
    [remaining] = Writing.gravity_field(words, previous: shifted, exclude_ids: [first.id])
    prior = Enum.find(field, &(&1.entry.id == other.id))
    assert remaining.entry.id == other.id
    assert {remaining.side, remaining.height} == {prior.side, prior.height}
    assert Repo.aggregate(Still.Writing.Version, :count) == 0
    assert Writing.current_writing() == nil
    assert Writing.last_visited() == nil
  end

  test "source siblings and repeated language do not fill a second peripheral place" do
    piece("First:", "opal quartz orchard", source_group: "shared-page")
    piece("Second:", "lantern compass resting", source_group: "shared-page")
    assert length(Writing.gravity_field("opal quartz orchard. lantern compass resting.")) == 1

    piece("Another:Lantern:", "lantern compass resting")
    assert length(Writing.gravity_field("lantern compass resting")) == 1
    assert Writing.gravity_field("resting resting resting resting") == []
  end

  test "an admitted fragment can recede through a small continuation before it disappears" do
    earlier = piece("An:Orchard:", "opal quartz orchard")
    piece("A:Lantern:", "lantern compass resting")
    words = "opal quartz. lantern compass resting."
    field = Writing.gravity_field(words)
    assert length(field) == 2
    before = Enum.find(field, &(&1.entry.id == earlier.id))
    continued = words <> " lantern compass resting."
    assert length(Writing.gravity_field(continued)) == 1
    remembered = Writing.gravity_field(continued, previous: field)
    assert length(remembered) == 2
    receding = Enum.find(remembered, &(&1.entry.id == earlier.id))
    assert receding.motion == :receding
    assert receding.strength < before.strength
    assert {receding.side, receding.height} == {before.side, before.height}

    [remaining] =
      Writing.gravity_field(continued <> String.duplicate(" lantern compass resting", 10),
        previous: remembered
      )

    assert remaining.entry.id != earlier.id
  end

  test "a held fragment changes gently but follows an erased thought and living source edits" do
    entry = piece("An:Orchard:", "opal quartz orchard\nlantern compass resting")
    [original] = Writing.gravity_field("opal quartz orchard")
    assert original.line == "opal quartz orchard"
    changed = "opal quartz orchard. lantern compass resting."
    assert Writing.gravity(changed).line == "lantern compass resting"
    [held] = Writing.gravity_field(changed, previous: [original])
    assert held.line == original.line

    [moved] = Writing.gravity_field("lantern compass resting", previous: [held])
    assert moved.line == "lantern compass resting"
    receding_words = changed <> String.duplicate(" unwrittenword", 30)
    raw = Writing.gravity(receding_words)
    [receding] = Writing.gravity_field(receding_words, previous: [held])
    assert receding.motion == :receding
    assert receding.strength < held.strength
    assert receding.strength > raw.strength
    assert Writing.gravity_field("", previous: [receding]) == []

    {:ok, edited} = Writing.save_entry(entry, "celluloid telescopes unfolding", title: "Changed:")
    assert Writing.gravity_field(changed, previous: [held]) == []
    [living] = Writing.gravity_field("celluloid telescopes unfolding", previous: [held])
    assert living.line == edited.body
    [original_words] = Writing.list_versions(edited)
    {:ok, _} = Writing.restore_version(edited, original_words.id)
    assert Writing.gravity_field("celluloid telescopes unfolding", previous: [living]) == []
    [restored] = Writing.gravity_field(changed)
    assert restored.entry.id == entry.id

    removable = piece("Elsewhere:", "sapphire platypus accordion")
    removed_field = Writing.gravity_field(removable.body)
    Repo.delete!(removable)
    assert Writing.gravity_field(removable.body, previous: removed_field) == []
  end

  test "independent synthetic Lists inhabit both sides without duplicating a single source" do
    Still.SyntheticCorpus.import!()

    for {words, titles} <- [
          {"cobalt zeppelin sprocket. saffron anvil prism.",
           ["Cobalt:Zeppelin:Sprocket:", "Saffron:Anvil:Prism:"]},
          {"zircon caliper lattice. amber turbine spindle.",
           ["Zircon:Caliper:Lattice:", "Amber:Turbine:Spindle:"]},
          {"indigo pulley socket. ochre piston flange.",
           ["Indigo:Pulley:Socket:", "Ochre:Piston:Flange:"]}
        ] do
      field = Writing.gravity_field(words)
      assert Enum.map(field, & &1.entry.title) |> Enum.sort() == Enum.sort(titles)
      assert Enum.all?(field, &(&1.line in String.split(&1.entry.body, "\n")))
      assert Enum.map(field, & &1.entry.source_group) |> Enum.uniq() |> length() == 2
    end

    field = Writing.gravity_field("cobalt zeppelin sprocket. saffron anvil prism.")
    assert field |> Enum.map(& &1.side) |> Enum.sort() == [:left, :right]

    for words <- ["cobalt zeppelin", "saffron anvil", "zircon caliper lattice cobalt"] do
      assert length(Writing.gravity_field(words)) == 1
    end
  end

  test "the cached past follows living edits and restoration and forgets removed writing" do
    entry = piece("An:Orchard:", "opal quartz orchard")
    other = piece("A:Lantern:", "lantern compass resting")
    assert Writing.gravity("opal quartz orchard").entry.id == entry.id
    assert Writing.gravity("lantern compass resting").entry.id == other.id

    {:ok, edited} = Writing.save_entry(entry, "celluloid telescopes unfolding", title: "Changed:")
    assert Writing.gravity("opal quartz orchard") == nil
    assert Writing.gravity("celluloid telescopes unfolding").entry.id == entry.id
    [original] = Writing.list_versions(edited)
    {:ok, _} = Writing.restore_version(edited, original.id)
    assert Writing.gravity("opal quartz orchard").entry.id == entry.id
    assert Writing.gravity("celluloid telescopes unfolding") == nil

    Repo.delete!(other)
    assert Writing.gravity("lantern compass resting") == nil
  end

  test "source geography remains a place when the words return to now" do
    first =
      piece("First:", "first source words",
        notebook: "Early Notebooks/Lists 3",
        source_group: "one-page"
      )

    sibling =
      piece("Sibling:", "another source voice",
        notebook: "Early Notebooks/Lists 3",
        source_group: "one-page"
      )

    neighbor =
      piece("Neighbor:", "different page",
        notebook: "Early Notebooks/Lists 3",
        source_group: "other-page"
      )

    distant = piece("Elsewhere:", "distant words", notebook: "Early Notebooks/Lists 8")

    current_notebook =
      piece("Current:", "not dated", notebook: "Current Notebooks/2026/Notebook 1")

    notebook_corner =
      piece("Corner:", "also not dated", notebook: "Current Notebooks/2026/Notebook 1/Jan - Mar")

    place = Writing.geography(first)
    assert Writing.geography(sibling) == place
    assert Writing.geography(neighbor).key == place.key
    assert Writing.geography(neighbor).anchor_x == place.anchor_x
    assert Writing.place_distance(first, sibling) == :same_source
    assert Writing.place_distance(first, neighbor) == :same_notebook
    assert Writing.place_distance(first, distant) == :same_region
    assert Writing.place_distance(first, current_notebook) == :far
    assert Writing.place_distance(first, nil) == :now
    assert Writing.geography(current_notebook).key == Writing.geography(notebook_corner).key
    assert Writing.place_distance(current_notebook, notebook_corner) == :same_notebook

    {:ok, returned} = Writing.save_entry(first, "new words from today", title: "Returning:")
    assert returned.returned_at
    assert Writing.geography(returned) == place
  end

  test "synthetic landscape contains physical notebooks rather than a folder hierarchy" do
    Still.SyntheticCorpus.import!()
    places = Writing.places()
    assert length(places) == 10
    assert Enum.count(places, &(&1.label == "Notebook 1")) == 1
    assert Enum.map(places, & &1.key) |> Enum.uniq() |> length() == 10

    for place <- places do
      assert Writing.geography(Writing.get_entry!(place.entry_id)).key == place.key
      assert place.x >= 0 and place.x <= 100
      assert place.y >= 0 and place.y <= 100
      assert abs(place.tone) <= 8
    end
  end

  test "light and the current writing survive wandering without replacing each other" do
    {:ok, now} = Writing.save_entry(nil, "The writing I will return to")
    before = piece("Before:", "another place")
    assert Writing.room_light() == 38
    assert Writing.current_writing() == nil
    assert {:ok, 247} = Writing.set_room_light(247)
    assert {:ok, _} = Writing.remember_writing(now)
    Writing.remember_visit(before)
    assert Writing.current_writing().id == now.id
    assert Writing.last_visited().id == before.id
    assert Writing.room_light() == 247
    assert {:error, :not_now} = Writing.remember_writing(before)
    assert {:error, :invalid_light} = Writing.set_room_light("bright")
    assert Writing.room_light() == 247
    assert {:ok, 0} = Writing.set_room_light(-30)
    assert {:ok, 360} = Writing.set_room_light(390)
    assert Writing.current_writing().id == now.id
    assert Writing.last_visited().id == before.id
  end

  test "a fresh draft remembers its source without replacing earlier writing or room state" do
    {:ok, previous} = Writing.save_entry(nil, "Earlier saved writing", title: "Earlier:")
    {:ok, previous} = Writing.save_entry(previous, "The saved writing I left", title: "Saved:")
    before = piece("Beside:", "A source to write beside")
    {:ok, _} = Writing.remember_writing(previous)
    {:ok, _} = Writing.set_room_light(213)
    {:ok, _} = Writing.remember_visit(before)
    versions = Writing.list_versions(previous)

    assert {:ok, _} = Writing.begin_writing(before)
    assert Writing.current_writing() == nil
    assert Writing.current_beside().id == before.id
    assert Writing.room_light() == 213
    assert Writing.last_visited().id == before.id
    assert Writing.get_entry!(previous.id) == previous
    assert Writing.list_versions(previous) == versions
    assert Repo.aggregate(Entry, :count) == 2

    assert {:ok, _} = Writing.begin_writing()
    assert Writing.current_writing() == nil
    assert Writing.current_beside() == nil
    assert Writing.get_entry!(previous.id) == previous
    assert Writing.list_versions(previous) == versions
    assert Writing.room_light() == 213
    assert Writing.last_visited().id == before.id

    assert {:ok, _} = Writing.begin_writing(before)
    {:ok, saved} = Writing.save_entry(nil, "Fresh words saved here", beside_id: before.id)
    assert {:ok, _} = Writing.remember_writing(saved)
    assert Writing.current_writing().id == saved.id
    assert Writing.current_beside() == nil
    assert Repo.get!(Still.Writing.RoomState, 1).draft_beside_id == nil
    assert saved.beside_id == before.id
    assert Writing.get_entry!(previous.id) == previous
  end

  test "the unsaved beside cursor is a foreign key and disappears with its source" do
    before = piece("Beside:", "Words still in the source")
    assert {:ok, _} = Writing.begin_writing(before)
    assert Repo.aggregate(Still.Writing.Version, :count) == 0
    assert Writing.last_visited() == nil
    assert {:error, :invalid_beside} = Writing.begin_writing(%Entry{})
    assert Writing.current_beside().id == before.id

    Repo.delete!(before)
    assert Writing.current_beside() == nil
    assert Repo.get!(Still.Writing.RoomState, 1).draft_beside_id == nil
    assert Writing.current_writing() == nil
    assert Repo.aggregate(Entry, :count) == 0

    {:ok, previous} = Writing.save_entry(nil, "The saved writing remains here")
    {:ok, _} = Writing.remember_writing(previous)
    assert {:error, :missing_beside} = Writing.begin_writing(before)
    assert Writing.current_beside() == nil
    assert Writing.current_writing().id == previous.id
    assert Writing.get_entry!(previous.id).body == previous.body
  end

  defp piece(title, body, attrs \\ []) do
    %Entry{}
    |> Entry.changeset(
      Map.merge(
        %{
          title: title,
          body: body,
          origin: "before",
          notebook: "Early Notebooks/Lists 1",
          source_group: Ecto.UUID.generate()
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end
end

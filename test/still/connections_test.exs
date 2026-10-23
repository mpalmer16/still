defmodule Still.ConnectionsTest do
  use Still.DataCase
  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "a deliberate item begins quietly and two items can meet in a different writing" do
    before = piece("Water:", "water: white stone:")
    {:ok, recent} = Writing.save_entry(nil, "water:\nwaiting:", writing_form: "list")
    assert Writing.gravity_field("water:") == []
    [single] = Writing.gravity_field("water:", list: true)
    assert single.entry.id == before.id
    assert single.distance == :far
    assert single.strength < 0.4
    assert single.line == before.body

    [meeting] = Writing.gravity_field("water:\nwaiting:", list: true, previous: [single])
    assert meeting.entry.id == recent.id
    assert meeting.line in String.split(recent.body, "\n")

    assert Writing.gravity_field("water:\nwaiting:", list: true, entry_id: recent.id)
           |> Enum.all?(&(&1.entry.id != recent.id))

    assert Writing.gravity_field("and: the:", list: true) == []

    assert Writing.gravity_field("water:",
             list: true,
             entry_id: before.id,
             exclude_ids: [recent.id]
           ) == []
  end

  test "one living engine leads old writing to recent writing and back without changing either" do
    before = piece("An:Orchard:", "opal quartz orchard")
    {:ok, recent} = Writing.save_entry(nil, "opal quartz orchard")
    {:ok, _} = Writing.remember_writing(recent)
    [forward] = Writing.gravity_field(before.body, reading: true, entry_id: before.id)
    [back] = Writing.gravity_field(recent.body, reading: true, entry_id: recent.id)
    assert forward.entry.id == recent.id
    assert back.entry.id == before.id
    assert forward.phrase == recent.body
    assert forward.line == recent.body
    assert Writing.echo(before).entry.id == recent.id
    assert Writing.echo(recent).entry.id == before.id
    assert Writing.current_writing().id == recent.id
    assert Repo.aggregate(Still.Writing.Version, :count) == 0
    assert Writing.get_entry!(before.id).body == before.body
    assert Writing.get_entry!(recent.id).body == recent.body
  end

  test "crossing origins needs comparable literal evidence and follows changed current words" do
    before = piece("A:Meeting:", "opal quartz orchard. lantern compass resting.")
    neighbor = piece("An:Orchard:", "opal quartz orchard")
    {:ok, recent} = Writing.save_entry(nil, "unrelated sandstone steps")
    [initial] = Writing.gravity_field(before.body, reading: true, entry_id: before.id)
    assert initial.entry.id == neighbor.id

    {:ok, edited} = Writing.save_entry(recent, "lantern compass resting")
    [crossing] = Writing.gravity_field(before.body, reading: true, entry_id: before.id)
    assert crossing.entry.id == recent.id
    assert crossing.line == edited.body
    assert Writing.echo(before).entry.id == recent.id

    [original] = Writing.list_versions(edited)
    {:ok, restored} = Writing.restore_version(edited, original.id)
    [back] = Writing.gravity_field(before.body, reading: true, entry_id: before.id)
    assert back.entry.id == neighbor.id
    assert Writing.echo(before).entry.id == neighbor.id
    assert restored.body == recent.body
  end

  test "a reading looks through the whole piece while prose still follows its newest words" do
    older = piece("A:Lantern:", "lantern compass resting")

    {:ok, recent} =
      Writing.save_entry(
        nil,
        "lantern compass resting" <> String.duplicate(" unwrittenword", 150)
      )

    assert Writing.gravity_field(recent.body, entry_id: recent.id) == []
    [reading] = Writing.gravity_field(recent.body, reading: true, entry_id: recent.id)
    assert reading.entry.id == older.id
    assert Writing.echo(recent).entry.id == older.id
  end

  test "title evidence remains authored title text and grammar does not become an echo" do
    {:ok, titled} =
      Writing.save_entry(nil, "Words about something else", title: "Opal:Quartz:Orchard:")

    [drawn] = Writing.gravity_field("", title: "opal quartz orchard")
    assert drawn.entry.id == titled.id
    assert drawn.line == titled.title

    anchor = piece("First:", "I seemed to wait in an empty room")
    piece("Second:", "She seemed to leave at once")
    assert Writing.echo(anchor) == nil

    actual = piece("A:Voice:", "Her blue accordion sleeps.")
    other = piece("Another:Voice:", "A BLUE accordion waits.")
    echo = Writing.echo(actual)
    assert echo.entry.id == other.id
    assert echo.phrase == "BLUE accordion"
    assert echo.line == other.body
  end

  test "wandering can start among recent writing and keeps going after its bounded path fills" do
    {:ok, recent} = Writing.save_entry(nil, "Unrelated sandstone steps")
    assert Writing.wander_entry().id == recent.id
    {:ok, _} = Writing.remember_visit(recent)
    before = piece("Before:", "Different celluloid telescopes")
    assert Writing.wander_entry().id == before.id
    assert Writing.connections(before).far.id == recent.id
    assert Writing.connections(recent).far.id == before.id
    {:ok, _} = Writing.remember_visit(before)
    assert Writing.wander_entry().id in [recent.id, before.id]
    assert Writing.wander_entry(exclude_ids: [recent.id, before.id]) == nil
    assert Writing.wander_entry(exclude_ids: [before.id]).id == recent.id
  end

  test "the two Notebook 1 corners are nearby rather than a fabricated far crossing" do
    root = piece("One:", "source root words", notebook: "Current Notebooks/2026/Notebook 1")

    corner =
      piece("Two:", "different corner language",
        notebook: "Current Notebooks/2026/Notebook 1/Jan - Mar"
      )

    {:ok, recent} = Writing.save_entry(nil, "Unrelated celluloid telescope")
    assert Writing.nearby(root).id == corner.id
    assert Writing.nearby(corner).id == root.id
    assert Writing.connections(root).far.id == recent.id
    assert Writing.wander_entry(exclude_notebook: corner.notebook).id == recent.id
  end

  test "a weak synthetic list item strengthens, repeated singles stay quiet, and origins cross" do
    Still.SyntheticCorpus.import!()
    [single] = Writing.gravity_field("sprocket:", list: true)
    assert single.distance == :far
    assert single.strength < 0.4
    [together] = Writing.gravity_field("sprocket:\nzephyr:", list: true, previous: [single])
    evidence = together.entry.body <> "\n" <> (together.entry.title || "")
    assert Regex.match?(~r/\bsprocket\b/iu, evidence)
    assert Regex.match?(~r/\bzephyr\b/iu, evidence)
    assert together.strength > single.strength

    assert together.line in String.split(together.entry.body, "\n") or
             together.line == together.entry.title

    for words <- [
          "I am making dinner and thinking about the world.",
          "This meeting starts tomorrow at four.",
          "I bought a new umbrella for the rainy season."
        ] do
      assert Writing.gravity_field(words) == []
    end

    assert Writing.gravity_field("sprocket:\nzephyr:") == []
    assert Writing.gravity_field("sprocket:\nsprocket:", list: true) |> length() == 1

    old = Repo.get_by!(Entry, title: "Zircon:Caliper:Lattice:")
    {:ok, recent} = Writing.save_entry(nil, old.body, writing_form: "list")
    [crossing] = Writing.gravity_field(old.body, reading: true, entry_id: old.id, list: true)
    assert crossing.entry.id == recent.id
    assert Writing.echo(old).entry.id == recent.id

    [returning] =
      Writing.gravity_field(recent.body, reading: true, entry_id: recent.id, list: true)

    assert returning.entry.id == old.id
  end

  defp piece(title, body, opts \\ []) do
    %Entry{}
    |> Entry.changeset(%{
      title: title,
      body: body,
      origin: "before",
      notebook: Keyword.get(opts, :notebook, "Early Notebooks/Lists 1"),
      source_group: Ecto.UUID.generate(),
      source_order: 100
    })
    |> Repo.insert!()
  end
end

defmodule Still.NotebooksTest do
  use Still.DataCase
  alias Still.{Repo, Writing}
  alias Still.Writing.{Entry, RoomState, Version}

  @lists "Early Notebooks/Lists 1"
  @notebook "Current Notebooks/2026/Notebook 1"
  @corner @notebook <> "/Jan - Mar"

  test "an empty collection and unknown keys are harmless reads" do
    assert Writing.notebooks() == []

    for key <- [
          nil,
          1,
          %{},
          "",
          @lists,
          "../../data/still.db",
          "' OR 1=1 --",
          String.duplicate("x", 1_025),
          <<255>>
        ] do
      assert Writing.notebook(key) == nil
    end

    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(Version, :count) == 0
    assert Repo.all(RoomState) == []
  end

  test "the whole source notebook remains ordered after living edits, beyond Find limits" do
    entries =
      for position <- Enum.reverse(0..136) do
        piece("Source #{position}:", notebook: @lists, source_order: position * 100)
      end

    expected = entries |> Enum.reverse() |> Enum.map(& &1.id)
    first = Writing.get_entry!(hd(expected))
    last = Writing.get_entry!(List.last(expected))
    {:ok, changed} = Writing.save_entry(first, "Changed words", title: "A new title:")
    assert changed.returned_at

    {:ok, current} =
      Writing.save_entry(nil, "A newly written List:", writing_form: "list", beside_id: first.id)

    {:ok, _} = Writing.remember_writing(current)
    {:ok, _} = Writing.remember_visit(last)
    room = Repo.all(RoomState)
    counts = {Repo.aggregate(Entry, :count), Repo.aggregate(Version, :count)}

    [catalog] = Writing.notebooks()
    assert catalog.count == 137
    assert catalog.section_count == 1
    assert catalog.sections == [%{key: @lists, label: "Lists 1", count: 137}]
    refute Map.has_key?(catalog, :entries)

    notebook = Writing.notebook(@lists)
    assert Enum.map(notebook.entries, & &1.id) == expected
    assert hd(notebook.entries).title == changed.title
    assert hd(notebook.entries).body == changed.body
    assert List.last(notebook.entries).id == last.id
    assert hd(notebook.sections).entries == notebook.entries
    refute Enum.any?(notebook.entries, &(&1.id == current.id))

    for key <- [@lists <> "/missing", "../../data/still.db", "' OR 1=1 --", "now"] do
      assert Writing.notebook(key) == nil
    end

    assert Repo.all(RoomState) == room
    assert {Repo.aggregate(Entry, :count), Repo.aggregate(Version, :count)} == counts
  end

  test "physical notebooks have natural catalogue order and independent source sections" do
    root_later = piece("Root later:", notebook: @notebook, source_order: 100)
    corner_first = piece("Corner first:", notebook: @corner, source_order: 0)
    root_first = piece("Root first:", notebook: @notebook, source_order: 0)
    corner_later = piece("Corner later:", notebook: @corner, source_order: 100)
    ten = piece("Ten:", notebook: "Current Notebooks/2026/Notebook 10", source_order: 0)
    piece("Earlier current:", notebook: "Current Notebooks/2025 Oct - Dec", source_order: 0)

    for number <- [10, 2, 1] do
      piece("List #{number}:", notebook: "Early Notebooks/Lists #{number}", source_order: 0)
    end

    piece("No source place:", notebook: nil, source_order: 0)

    assert Enum.map(Writing.notebooks(), & &1.key) == [
             @lists,
             "Early Notebooks/Lists 2",
             "Early Notebooks/Lists 10",
             "Current Notebooks/2025 Oct - Dec",
             @notebook,
             "Current Notebooks/2026/Notebook 10"
           ]

    notebook = Writing.notebook(@notebook)
    assert notebook.count == 4
    assert notebook.region == :current
    assert notebook.section_count == 2
    assert notebook.place.key == @notebook
    assert notebook.place.corner == nil
    assert notebook.place.x == notebook.place.anchor_x
    assert notebook.place.y == notebook.place.anchor_y
    [root, corner] = notebook.sections
    assert {root.key, root.label} == {@notebook, "Notebook 1"}
    assert {corner.key, corner.label} == {@corner, "Jan - Mar"}
    assert Enum.map(root.entries, & &1.id) == [root_first.id, root_later.id]
    assert Enum.map(corner.entries, & &1.id) == [corner_first.id, corner_later.id]

    assert Enum.map(notebook.entries, & &1.id) ==
             [root_first.id, root_later.id, corner_first.id, corner_later.id]

    assert Writing.notebook(@corner) == nil
    assert Writing.notebook(@notebook <> "/") == nil
    assert Writing.notebook("Current Notebooks/2026/Notebook 10").entries == [ten]
  end

  test "split pieces and tied or missing positions have deterministic source order" do
    last_piece =
      piece("Split last:",
        source_order: 100,
        source_group: "split",
        source: %{"artifact_order" => 1, "piece_order" => 2}
      )

    first_piece =
      piece("Split first:",
        source_order: 100,
        source_group: "split",
        source: %{"artifact_order" => 1, "piece_order" => 0}
      )

    middle_piece =
      piece("Split middle:",
        source_order: 100,
        source_group: "split",
        source: %{"artifact_order" => 1, "piece_order" => 1}
      )

    later = piece("Later source:", source_order: 300)

    recovered =
      piece("Metadata position:",
        source_order: nil,
        source: %{"artifact_order" => 2, "piece_order" => 0}
      )

    tie_first = piece("Tie first:", source_order: 400, source_group: nil, source_key: nil)
    tie_last = piece("Tie last:", source_order: 400, source_group: nil, source_key: nil)
    missing_first = piece("Unknown first:", source_order: nil, source_group: nil, source_key: nil)

    missing_last =
      piece("Unknown last:",
        source_order: nil,
        source_group: nil,
        source_key: nil,
        source: %{"artifact_order" => "0", "piece_order" => -1}
      )

    expected =
      Enum.map(
        [
          first_piece,
          middle_piece,
          last_piece,
          recovered,
          later,
          tie_first,
          tie_last,
          missing_first,
          missing_last
        ],
        & &1.id
      )

    assert Enum.map(Writing.notebook(@lists).entries, & &1.id) == expected
    assert Enum.map(Writing.notebook(@lists).entries, & &1.id) == expected
  end

  test "the synthetic complete catalog preserves both ends, sections, and read-only state" do
    Still.SyntheticCorpus.import!()
    counts = {Repo.aggregate(Entry, :count), Repo.aggregate(Version, :count)}
    catalog = Writing.notebooks()
    assert length(catalog) == 10
    assert Enum.sum(Enum.map(catalog, & &1.count)) == 540
    assert Enum.map(Enum.take(catalog, 8), & &1.label) == Enum.map(1..8, &"Lists #{&1}")

    first = Writing.notebook(@lists)
    assert first.count == 137
    assert hd(first.entries).title == "Cobalt:Zeppelin:Sprocket:"
    assert List.last(first.entries).title == "Synthetic List One 136:"
    assert hd(first.entries).source_order == 0
    assert List.last(first.entries).source_order == 13_600
    assert length(Enum.uniq_by(first.entries, & &1.source_group)) == 73

    physical = Writing.notebook(@notebook)
    assert physical.count == 40
    assert Enum.map(physical.sections, &{&1.key, &1.count}) == [{@notebook, 2}, {@corner, 38}]

    indexed =
      Enum.flat_map(catalog, fn notebook ->
        detail = Writing.notebook(notebook.key)

        for section <- detail.sections do
          positions = Enum.map(section.entries, & &1.source_order)
          assert positions == Enum.sort(positions)
        end

        Enum.map(detail.entries, & &1.id)
      end)

    assert length(indexed) == 540
    assert length(Enum.uniq(indexed)) == 540
    assert {Repo.aggregate(Entry, :count), Repo.aggregate(Version, :count)} == counts
    assert Repo.all(RoomState) == []
  end

  defp piece(title, opts) do
    %Entry{}
    |> Entry.changeset(%{
      title: title,
      body: "Words of #{title}",
      origin: "before",
      notebook: Keyword.get(opts, :notebook, @lists),
      source_order: Keyword.get(opts, :source_order, 0),
      source_group: Keyword.get(opts, :source_group, Ecto.UUID.generate()),
      source_key: Keyword.get(opts, :source_key, Ecto.UUID.generate()),
      source: Keyword.get(opts, :source, %{})
    })
    |> Repo.insert!()
  end
end

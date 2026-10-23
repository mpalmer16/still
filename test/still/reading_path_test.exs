defmodule Still.ReadingPathTest do
  use Still.DataCase
  alias Still.Writing
  alias Still.Writing.RoomState

  test "reading retraces repeated visits without looping, preserving Now and earlier words" do
    {:ok, now} = Writing.save_entry(nil, "Now is waiting")
    {:ok, a} = Writing.save_entry(nil, "A")
    {:ok, b} = Writing.save_entry(nil, "B")
    Writing.remember_writing(now)
    Writing.remember_visit(now)
    for entry <- [a, b, a, a], do: Writing.remember_reading(entry)
    assert Writing.previous_reading(a)["id"] == b.id
    assert Writing.back_reading(a)["id"] == b.id
    Writing.remember_reading(b)
    assert Writing.back_reading(b)["id"] == a.id
    Writing.remember_reading(a)
    assert Writing.back_reading(a) == nil
    assert Writing.current_writing().id == now.id
    assert Writing.recent_entries() == [now]
    assert Writing.list_versions(now) == []
    assert Writing.get_entry!(now.id) == now
  end

  test "historical and search places survive a return; a pending List stays pending" do
    {:ok, a} = Writing.save_entry(nil, "A heron")
    {:ok, b} = Writing.save_entry(nil, "B")
    Writing.begin_writing(a, writing_form: "list")
    Writing.remember_reading(a, version: 123, query: "heron", earlier: true)
    Writing.remember_reading(b)

    assert Writing.back_reading(b) == %{
             "id" => a.id,
             "version" => 123,
             "query" => "heron",
             "earlier" => true,
             "written" => false
           }

    assert Writing.current_writing() == nil
    assert Writing.current_beside().id == a.id
    assert Writing.current_list_draft?()
    assert Writing.list_versions(a) == []
  end

  test "path is bounded and missing pages are skipped" do
    pieces = for n <- 1..37, do: elem(Writing.save_entry(nil, "Piece #{n}"), 1)
    for entry <- pieces, do: Writing.remember_reading(entry)
    assert length(Repo.get!(RoomState, 1).recent["reading_path"]) == 32
    last = List.last(pieces)
    previous = Enum.at(pieces, -2)
    Repo.delete!(previous)
    assert Writing.previous_reading(last)["id"] == Enum.at(pieces, -3).id
    assert Writing.previous_reading(hd(pieces)) == nil
  end
end

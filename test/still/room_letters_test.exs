defmodule Still.RoomLettersTest do
  use Still.DataCase

  alias Still.Writing
  alias Still.Writing.RoomState

  test "letters have a quiet default without creating room state or writing" do
    assert Writing.room_letters() == 50
    assert Repo.get(RoomState, 1) == nil
    assert Writing.list_entries() == []
  end

  test "changing letters preserves the light, return path, recent writing and earlier words" do
    {:ok, entry} = Writing.save_entry(nil, "First words\n\tand their continuation")
    {:ok, current} = Writing.save_entry(entry, "Later words", checkpoint: true)
    {:ok, _} = Writing.remember_writing(current)
    {:ok, _} = Writing.remember_visit(current)
    {:ok, 214} = Writing.set_room_light(214)
    previous = Repo.get!(RoomState, 1)
    versions = Writing.list_versions(current)

    assert {:ok, 23} = Writing.set_room_letters(23)
    assert Writing.room_letters() == 23
    assert Repo.get!(RoomState, 1) == %{previous | letters: 23}
    assert Writing.get_entry!(current.id) == current
    assert Writing.list_versions(current) == versions

    # Subsequent changes to other room fields must not reset the chosen letters.
    assert {:ok, 130} = Writing.set_room_light(130)
    assert {:ok, _} = Writing.begin_writing(current)
    assert {:ok, _} = Writing.remember_visit(current)
    assert Writing.room_letters() == 23
    assert Writing.room_light() == 130
    assert Writing.current_writing() == nil
    assert Writing.current_beside().id == current.id
    assert Writing.recent_entries() == [current]
    assert Writing.get_entry!(current.id) == current
    assert Writing.list_versions(current) == versions
  end

  test "letters stay within their useful range and reject malformed values" do
    assert {:ok, 0} = Writing.set_room_letters(-20)
    assert Writing.room_letters() == 0
    assert {:ok, 100} = Writing.set_room_letters(130)
    assert Writing.room_letters() == 100

    for value <- ["small", "50", 50.5, nil] do
      assert {:error, :invalid_letters} = Writing.set_room_letters(value)
      assert Writing.room_letters() == 100
    end

    assert Writing.room_light() == 38
    assert Writing.list_entries() == []
  end
end

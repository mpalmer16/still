defmodule StillWeb.CalendarTimeTest do
  use ExUnit.Case, async: true

  alias StillWeb.CalendarTime

  test "formats midnight, noon, morning, and afternoon times" do
    assert CalendarTime.format("00:00") == "12:00 am"
    assert CalendarTime.format("12:00") == "12:00 pm"
    assert CalendarTime.format("06:05") == "6:05 am"
    assert CalendarTime.format("18:30") == "6:30 pm"
  end

  test "returns nil for missing or malformed times" do
    assert CalendarTime.format(nil) == nil
    assert CalendarTime.format("") == nil
    assert CalendarTime.format("6:30") == nil
    assert CalendarTime.format("24:00") == nil
  end
end

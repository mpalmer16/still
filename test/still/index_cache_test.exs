defmodule Still.Writing.IndexCacheTest do
  use ExUnit.Case, async: true

  alias Still.Writing.IndexCache

  test "a value written by one process is readable by another" do
    key = {__MODULE__, make_ref()}
    stamp = {:source, 1}
    value = %{derived: [:word, :another]}

    assert ^value = IndexCache.put(key, stamp, value)

    assert Task.async(fn -> IndexCache.get(key) end)
           |> Task.await() == {stamp, value}
  end

  test "the same key can replace an older exact source stamp" do
    key = {__MODULE__, make_ref()}
    IndexCache.put(key, {:body, "old"}, :old_index)
    IndexCache.put(key, {:body, "new"}, :new_index)

    assert IndexCache.get(key) == {{:body, "new"}, :new_index}
  end
end

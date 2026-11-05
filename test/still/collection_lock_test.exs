defmodule Still.Writing.CollectionLockTest do
  use ExUnit.Case, async: true

  alias Still.Writing.CollectionLock

  test "a second process waits for the database lock and crash releases it" do
    directory = temp_dir()
    on_exit(fn -> File.rm_rf!(directory) end)
    database = Path.join(directory, "still.sqlite3")
    parent = self()

    owner =
      spawn(fn ->
        CollectionLock.with_lock(database, fn ->
          send(parent, :owner_has_lock)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :owner_has_lock

    waiter =
      Task.async(fn ->
        send(parent, :waiter_started)

        CollectionLock.with_lock(database, fn ->
          send(parent, {:waiter_finished, :yes})
          :acquired
        end)
      end)

    assert_receive :waiter_started
    refute_receive {:waiter_finished, _}, 100
    Process.exit(owner, :kill)

    assert :acquired = Task.await(waiter, 5_000)
  end

  test "different databases in the same parent folder have independent locks" do
    directory = temp_dir()
    on_exit(fn -> File.rm_rf!(directory) end)
    first_database = Path.join(directory, "first.sqlite3")
    second_database = Path.join(directory, "second.sqlite3")
    parent = self()

    first =
      spawn(fn ->
        result =
          CollectionLock.with_lock(first_database, fn ->
            send(parent, :first_has_lock)

            receive do
              :release -> :released
            end
          end)

        send(parent, {:first_finished, result})
      end)

    assert_receive :first_has_lock

    assert :second_acquired =
             CollectionLock.with_lock(second_database, fn -> :second_acquired end)

    send(first, :release)
    assert_receive {:first_finished, :released}
  end

  test "nested operations and symlinked paths reuse the current process lock" do
    directory = temp_dir()
    on_exit(fn -> File.rm_rf!(directory) end)
    actual = Path.join(directory, "actual")
    alias_dir = Path.join(directory, "alias")
    File.mkdir_p!(actual)
    File.ln_s!(actual, alias_dir)

    database = Path.join(actual, "still.sqlite3")
    database_alias = Path.join(alias_dir, "still.sqlite3")

    assert :outer =
             CollectionLock.with_lock(database, fn ->
               assert :nested = CollectionLock.with_lock(database_alias, fn -> :nested end)
               :outer
             end)
  end

  defp temp_dir do
    path = Path.join(System.tmp_dir!(), "still-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end

defmodule Still.DeskTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Still.Desk
  alias Still.Repo

  setup do
    root =
      Path.join(System.tmp_dir!(), "still-desk-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:still, :storage_state_directory, previous),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "an unsaved cursor survives configuring a collection and stores no writing words", %{
    root: root
  } do
    cursor = %{id: Ecto.UUID.generate(), saved: false, beside: 17}

    assert :ok = Desk.remember(unconfigured(), cursor)
    assert {:ok, ^cursor} = Desk.current(configured("a"))

    [path] = Path.wildcard(Path.join(root, "desk-*.json"))
    payload = File.read!(path)

    assert payload =~ cursor.id
    assert payload =~ "beside"
    refute payload =~ "words"
    refute payload =~ "title"
    refute payload =~ root
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert (mode &&& 0o777) == 0o600
  end

  test "saved cursors stay separate by collection and resume when switching back" do
    first = configured("a")
    second = configured("b")
    first_cursor = %{id: Ecto.UUID.generate(), saved: true, beside: nil}
    second_cursor = %{id: Ecto.UUID.generate(), saved: true, beside: 4}

    assert :ok = Desk.remember(first, first_cursor)
    assert :ok = Desk.remember(second, second_cursor)

    assert {:ok, ^first_cursor} = Desk.current(first)
    assert {:ok, ^second_cursor} = Desk.current(second)
    assert {:ok, nil} = Desk.current(configured("c"))
  end

  test "a new local page becomes current over a saved page, then adopts its collection on save" do
    location = configured("a")
    previous = %{id: Ecto.UUID.generate(), saved: true, beside: nil}
    new_page = %{id: Ecto.UUID.generate(), saved: false, beside: nil}

    assert :ok = Desk.remember(location, previous)
    assert :ok = Desk.remember(unconfigured(), new_page)
    assert {:ok, ^new_page} = Desk.current(location)

    saved_page = %{new_page | saved: true}
    assert :ok = Desk.remember(location, saved_page)
    assert {:ok, ^saved_page} = Desk.current(location)
    assert {:ok, nil} = Desk.current(configured("b"))
  end

  test "clearing a stale id preserves the cursor and clearing a matching id leaves other collections" do
    first = configured("a")
    second = configured("b")
    first_cursor = %{id: Ecto.UUID.generate(), saved: true, beside: nil}
    second_cursor = %{id: Ecto.UUID.generate(), saved: true, beside: nil}

    assert :ok = Desk.remember(first, first_cursor)
    assert :ok = Desk.remember(second, second_cursor)
    assert :ok = Desk.clear(first, Ecto.UUID.generate())
    assert {:ok, ^first_cursor} = Desk.current(first)

    assert :ok = Desk.clear(first, first_cursor.id)
    assert {:ok, nil} = Desk.current(first)
    assert {:ok, ^second_cursor} = Desk.current(second)
  end

  test "corrupt cursor state is reported and never replaced" do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not json")

    assert {:error, message} = Desk.current(configured("a"))
    assert message =~ "damaged"

    assert {:error, ^message} =
             Desk.remember(configured("a"), %{id: Ecto.UUID.generate(), saved: true, beside: nil})

    assert File.read!(path) == "{not json"
  end

  test "a saved cursor requires a configured collection" do
    cursor = %{id: Ecto.UUID.generate(), saved: true, beside: nil}

    assert {:error, message} = Desk.remember(unconfigured(), cursor)
    assert message =~ "configured collection"
    assert {:ok, nil} = Desk.current(unconfigured())
  end

  defp unconfigured, do: %{configured: false, scope: String.duplicate("0", 64)}

  defp configured(label) do
    scope = :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)
    %{configured: true, scope: scope}
  end

  defp state_path do
    database = Repo.config()[:database] |> Path.expand() |> then(&:crypto.hash(:sha256, &1))
    database_hash = Base.encode16(database, case: :lower)
    root = Application.fetch_env!(:still, :storage_state_directory)
    Path.join(root, "desk-#{database_hash}.json")
  end
end

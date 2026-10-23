defmodule Still.WritingTest do
  use Still.DataCase

  alias Still.{Repo, Writing}
  alias Still.Writing.Entry

  test "creating, editing and restoring keeps earlier words" do
    assert {:error, _} = Writing.save_entry(nil, "   ")
    assert Writing.list_entries() == []

    {:ok, first} = Writing.save_entry(nil, "A note about rain")

    {:ok, second} =
      Writing.save_entry(first, "A note about rain and the empty street", checkpoint: true)

    assert second.lock_version == first.lock_version + 1
    assert Writing.get_entry!(first.id).body == second.body
    assert [%{body: "A note about rain"} = version] = Writing.list_versions(second)

    assert {:error, {:stale, _}} = Writing.save_entry(first, "A conflicting edit")
    assert {:error, {:stale, _}} = Writing.save_entry(first, first.body)
    assert Writing.get_entry!(first.id).body == second.body

    {:ok, restored} = Writing.restore_version(second, version.id)
    assert restored.body == first.body
    assert Enum.any?(Writing.list_versions(restored), &(&1.body == second.body))
  end

  test "search is literal, paginated, and works across untitled writing" do
    {:ok, one} = Writing.save_entry(nil, "The blue accordion was in the hallway")
    {:ok, _} = Writing.save_entry(nil, "A blue morning")
    {:ok, _} = Writing.save_entry(nil, "The % character")

    assert Enum.map(Writing.list_entries(query: "accordion"), & &1.id) == [one.id]
    assert length(Writing.list_entries(query: "%")) == 1
    assert length(Writing.list_entries(limit: 1)) == 1
    assert length(Writing.list_entries(limit: 1, offset: 1)) == 1
  end

  test "the quiet return only chooses writing older than four weeks" do
    {:ok, recent} = Writing.save_entry(nil, "Today")
    assert Writing.remember_one() == nil

    older = DateTime.utc_now() |> DateTime.add(-40, :day)
    Repo.update_all(from(e in Entry, where: e.id == ^recent.id), set: [inserted_at: older])

    assert Writing.remember_one(~D[2026-09-29]).id == recent.id
    assert Writing.remember_one(~D[2026-09-29]).id == recent.id
  end

  test "a version cannot be restored onto another page" do
    {:ok, one} = Writing.save_entry(nil, "first")
    {:ok, one} = Writing.save_entry(one, "first revised", checkpoint: true)
    {:ok, two} = Writing.save_entry(nil, "second")
    [version] = Writing.list_versions(one)

    assert {:error, :missing} = Writing.restore_version(two, version.id)
    assert Writing.get_entry!(two.id).body == "second"
  end

  @tag :tmp_dir
  test "Lists import preserves shape and source and never overwrites a living edit", %{
    tmp_dir: dir
  } do
    body = "one line - interrupts / another\n\n\tbranch\n    another branch\n\"a voice\""
    source = source("shape", "Shape:Of:A:List:", body)
    path = manifest(dir, [source])

    assert {:ok, %{inserted: 1, skipped: 0}} = Writing.import_lists(path)
    imported = Repo.get_by!(Entry, source_key: "shape")
    assert imported.body == body
    assert imported.origin == "before"
    assert imported.returned_at == nil
    assert imported.source == source["source"]
    assert Writing.opening(imported) == "Shape:Of:A:List:"

    {:ok, edited} = Writing.save_entry(imported, body <> "\nnow", title: "Returned:Title:")
    assert edited.returned_at
    assert [%{title: "Shape:Of:A:List:", body: ^body} = original] = Writing.list_versions(edited)
    assert {:ok, %{inserted: 0, skipped: 1}} = Writing.import_lists(path)
    assert Writing.get_entry!(edited.id).body == edited.body
    assert Writing.get_entry!(edited.id).title == "Returned:Title:"
    assert Writing.get_entry!(edited.id).source == source["source"]

    {:ok, restored} = Writing.restore_version(edited, original.id)
    assert restored.title == imported.title
    assert restored.body == imported.body
    assert restored.returned_at == edited.returned_at
    assert Enum.any?(Writing.list_versions(restored), &(&1.title == "Returned:Title:"))
  end

  @tag :tmp_dir
  test "title edits search literally and reject stale titles without changing the body", %{
    tmp_dir: dir
  } do
    path = manifest(dir, [source("title", "The:Way:You:Hold:Your:Hair:", "same words")])
    {:ok, _counts} = Writing.import_lists(path)
    entry = Repo.get_by!(Entry, source_key: "title")

    assert [found] = Writing.list_entries(query: "way you hold")
    assert found.id == entry.id
    assert [found] = Writing.list_entries(query: "Way:You:Hold:")
    assert found.id == entry.id

    {:ok, same} = Writing.save_entry(entry, entry.body, title: entry.title)
    assert same.returned_at == nil
    assert Writing.list_versions(same) == []
    {:ok, changed} = Writing.save_entry(same, same.body, title: "Another:Way:")
    assert changed.body == entry.body
    assert changed.returned_at
    assert changed.lock_version == entry.lock_version + 1

    assert {:error, {:stale, current}} =
             Writing.save_entry(entry, entry.body, title: "Old:Title:")

    assert current.title == changed.title
    assert {:error, {:stale, _}} = Writing.save_entry(entry, entry.body)
    assert [%{title: "The:Way:You:Hold:Your:Hair:"}] = Writing.list_versions(changed)
  end

  @tag :tmp_dir
  test "invalid Lists import rolls back the entire manifest", %{tmp_dir: dir} do
    path = manifest(dir, [source("valid", "Valid:", "words"), %{"body" => "missing identity"}])
    assert {:error, {:invalid_entry, 2, :missing_source_key}} = Writing.import_lists(path)
    assert Writing.list_entries() == []
  end

  @tag :tmp_dir
  test "before can quietly return immediately and cannot displace writing from now", %{
    tmp_dir: dir
  } do
    {:ok, now} = Writing.save_entry(nil, "written now")

    {:ok, _} =
      Writing.import_lists(
        manifest(dir, [
          source("later", "Later:In:The:Notebook:", "before", order: 20),
          source("earlier", "Earlier:In:The:Notebook:", "before", order: 10)
        ])
      )

    assert [first, earlier, later] = Writing.list_entries()
    assert first.id == now.id
    assert earlier.source_key == "earlier"
    assert later.source_key == "later"
    resurfaced = Writing.remember_one(~D[2026-10-01])
    assert resurfaced.origin == "before"
    assert Writing.remember_one(~D[2026-10-01]).id == resurfaced.id
    {:ok, returned} = Writing.save_entry(earlier, earlier.body <> " returned")
    assert hd(Writing.list_entries()).id == returned.id
    assert Writing.list_entries(origin: "now") |> Enum.map(& &1.id) == [now.id]
  end

  @tag :tmp_dir
  test "wandering follows truthful source and notebook relationships and literal echoes", %{
    tmp_dir: dir
  } do
    sources = [
      source("one", "One:", "A blue accordion waits", group: "page", order: 10),
      source("sibling", "Two:", "A different voice", group: "page", order: 11),
      source("near", "Near:", "Nothing shared here", order: 12),
      source("echo", "Echo:", "Underneath, a blue accordion sleeps",
        notebook: "elsewhere",
        order: 1
      ),
      source("far", "Far:", "Distant sandstone steps", notebook: "far away", order: 1)
    ]

    {:ok, _} = Writing.import_lists(manifest(dir, sources))
    one = Repo.get_by!(Entry, source_key: "one")
    sibling = Repo.get_by!(Entry, source_key: "sibling")
    near = Repo.get_by!(Entry, source_key: "near")
    echo = Repo.get_by!(Entry, source_key: "echo")
    far = Repo.get_by!(Entry, source_key: "far")

    assert Enum.map(Writing.source_siblings(one), & &1.id) == [sibling.id]
    assert Writing.nearby(one).id == near.id
    assert %{entry: %{id: echo_id}, phrase: phrase} = Writing.echo(one)
    assert echo_id == echo.id
    assert String.contains?(String.downcase(one.body), String.downcase(phrase))
    assert String.contains?(String.downcase(echo.body), String.downcase(phrase))

    assert %{siblings: [_], nearby: %{id: near_id}, echo: %{}, far: %{id: far_id}} =
             Writing.connections(one)

    assert near_id == near.id
    assert far_id == far.id
    assert Writing.before_entry(exclude_ids: [one.id, sibling.id, near.id, echo.id]).id == far.id
    assert Writing.before_entry(exclude_ids: Enum.map(Writing.list_entries(), & &1.id)) == nil
  end

  test "writing beside a piece and returning to it remain explicit and local" do
    {:ok, old} = Writing.save_entry(nil, "Older words")
    {:ok, new} = Writing.save_entry(nil, "Words written here", beside_id: old.id)
    assert Enum.map(Writing.companions(old), & &1.id) == [new.id]
    assert Enum.map(Writing.companions(new), & &1.id) == [old.id]
    assert Writing.last_visited() == nil
    Writing.remember_visit(old)
    Writing.remember_visit(new)
    Writing.remember_visit(old)
    assert Writing.last_visited().id == old.id
    assert Enum.map(Writing.recent_entries(), & &1.id) == [old.id, new.id]
    assert Writing.connections(new) == %{siblings: [], nearby: nil, echo: nil, far: nil}
  end

  @tag :tmp_dir
  test "the recent path lets nearby movement continue through a notebook", %{tmp_dir: dir} do
    {:ok, _} =
      Writing.import_lists(
        manifest(dir, [
          source("a", "A:", "opal resting", order: 100),
          source("b", "B:", "quartz rising", order: 200),
          source("c", "C:", "citrine moving", order: 300),
          source("d", "D:", "quartz waiting", order: 400)
        ])
      )

    a = Repo.get_by!(Entry, source_key: "a")
    b = Repo.get_by!(Entry, source_key: "b")
    c = Repo.get_by!(Entry, source_key: "c")
    d = Repo.get_by!(Entry, source_key: "d")
    Writing.remember_visit(a)
    assert Writing.connections(a).nearby.id == b.id
    Writing.remember_visit(b)
    assert Writing.connections(b).nearby.id == c.id
    assert Writing.connections(b).echo.entry.id == d.id
    Writing.remember_visit(c)
    assert Writing.connections(c).nearby.id == d.id
    Writing.remember_visit(d)
    assert Writing.connections(d).nearby.id == c.id
  end

  defp source(key, title, body, opts \\ []) do
    %{
      "source_key" => key,
      "title" => title,
      "body" => body,
      "source_group" => Keyword.get(opts, :group, key),
      "notebook" => Keyword.get(opts, :notebook, "notebook"),
      "source_order" => Keyword.get(opts, :order, 1),
      "source" => %{
        "original_title" => String.replace(title, ":", " "),
        "original_body" => "- " <> body,
        "preamble" => "words copied before the List",
        "artifacts" => [%{"path" => key <> ".doc", "sha256" => "source-hash", "format" => "doc"}]
      }
    }
  end

  defp manifest(dir, sources) do
    path = Path.join(dir, "lists.json")
    File.write!(path, Jason.encode!(%{format: "still-lists-1", entries: sources}))
    path
  end
end

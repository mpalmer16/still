defmodule Still.SearchTest do
  use Still.DataCase
  alias Still.Writing
  alias Still.Writing.{Search, Version}

  test "remembered words cross punctuation, case, accents, title and separate passages" do
    {:ok, piece} =
      Writing.save_entry(nil, "The café was quiet.\nMuch later, a BLUE accordion.",
        title: "Across:The:River:"
      )

    {:ok, _} = Writing.save_entry(nil, "A blue room, with no instrument")

    for query <- [
          "accordion cafe",
          "CAFE, blue!",
          "river accordion",
          "Across the river",
          "café BLUE"
        ] do
      assert Enum.map(Writing.list_entries(query: query), & &1.id) == [piece.id]
    end

    assert Writing.list_entries(query: "cafe missing") == []
    assert Writing.get_entry!(piece.id) == piece
  end

  test "symbols remain literal and cannot become a wildcard" do
    {:ok, percent} = Writing.save_entry(nil, "100% is an impossible promise")
    {:ok, _} = Writing.save_entry(nil, "Another promise")
    assert [^percent] = Writing.list_entries(query: "%")
    assert Writing.list_entries(query: "_") == []
    assert Writing.list_entries(query: "' OR 1=1 --") == []
  end

  test "earlier words are opt in, distinct, scoped, and never joined across versions" do
    {:ok, entry} = Writing.save_entry(nil, "The vanished heron", title: "Riverbank")
    {:ok, entry} = Writing.save_entry(entry, "The living fox", checkpoint: true)
    Repo.insert!(%Version{entry_id: entry.id, title: "Riverbank", body: "The vanished heron"})
    assert Writing.find_entries(query: "heron") == []
    assert [result] = Writing.find_entries(query: "heron riverbank", earlier: true)
    assert result.version.body == "The vanished heron"
    assert result.entry.id == entry.id
    assert Writing.find_entries(query: "heron fox", earlier: true) == []
    assert Writing.get_version(entry, to_string(result.version.id)) == result.version
    {:ok, other} = Writing.save_entry(nil, "Other words")
    assert Writing.get_version(other, to_string(result.version.id)) == nil

    for id <- ["0", "-1", "invalid", "99999999999999999999999", "2 OR 1=1", nil] do
      assert Writing.get_version(entry, id) == nil
    end

    assert Writing.get_entry!(entry.id) == entry
    assert length(Writing.list_versions(entry)) == 2
  end

  test "matched excerpts find words deep into a piece without changing indentation or markup" do
    body =
      String.duplicate("An opening without the remembered words.\n", 60) <>
        "\tA café <script>heron</script>\n  A final line"

    {:ok, entry} = Writing.save_entry(nil, body)
    [result] = Writing.find_entries(query: "cafe heron")
    assert result.entry.id == entry.id
    assert result.line == 61
    assert result.excerpt =~ "\tA café <script>heron</script>"
    parts = Search.parts("\tCafé <script>heron</script>", "cafe heron")
    assert Enum.map_join(parts, & &1.text) == "\tCafé <script>heron</script>"
    assert Enum.filter(parts, & &1.match) |> Enum.map(& &1.text) == ["Café", "heron"]
    assert Writing.get_entry!(entry.id).body == body
    long = String.duplicate("opening ", 120) <> "heron waits quietly"
    assert Search.passage(long, "heron").excerpt =~ "heron"
  end

  test "browsing untitled pages does not repeat the opening as its excerpt" do
    {:ok, entry} = Writing.save_entry(nil, "An opening\nA continuation")
    [result] = Writing.find_entries()
    assert result.entry.id == entry.id
    assert result.title == "An opening"
    assert result.excerpt == "A continuation"
    assert Search.parts("  exact\twords", "") == [%{text: "  exact\twords", match: false}]
  end

  test "pagination remains complete with current and earlier results" do
    for index <- 1..47 do
      {:ok, entry} = Writing.save_entry(nil, "old needle #{index}")
      Writing.save_entry(entry, "new needle #{index}", checkpoint: true)
    end

    results =
      Writing.find_entries(query: "needle", earlier: true, limit: 40) ++
        Writing.find_entries(query: "needle", earlier: true, offset: 40, limit: 40) ++
        Writing.find_entries(query: "needle", earlier: true, offset: 80, limit: 40)

    assert length(results) == 94
    assert length(Enum.uniq_by(results, & &1.id)) == 94
    assert length(Writing.find_entries(query: "needle", limit: 100)) == 47
  end

  test "derived folded text refreshes when current or earlier words change at the same timestamp" do
    {:ok, entry} = Writing.save_entry(nil, "currentword opening")
    assert [%{entry: %{id: id}}] = Writing.find_entries(query: "currentword")
    assert id == entry.id
    original_updated_at = entry.updated_at

    Repo.update_all(from(e in Still.Writing.Entry, where: e.id == ^entry.id),
      set: [body: "replacementword opening"]
    )

    assert Repo.get!(Still.Writing.Entry, entry.id).updated_at == original_updated_at
    assert Writing.find_entries(query: "currentword") == []
    assert [%{entry: %{id: id}}] = Writing.find_entries(query: "replacementword")
    assert id == entry.id

    {:ok, current} = Writing.save_entry(nil, "presentday phrase")

    {:ok, version} =
      Repo.insert(%Version{
        entry_id: current.id,
        title: "Past title",
        body: "earlierword remains"
      })

    assert [%{version: %{id: found_version}}] =
             Writing.find_entries(query: "earlierword", earlier: true)

    Repo.update_all(from(v in Version, where: v.id == ^version.id),
      set: [body: "revisedword remains"]
    )

    assert Writing.find_entries(query: "earlierword", earlier: true) == []

    assert [%{entry: %{id: entry_id}, version: %{id: version_id}}] =
             Writing.find_entries(query: "revisedword", earlier: true)

    assert {entry_id, version_id, found_version} == {current.id, version.id, version.id}
  end
end

defmodule Still.PreservationTest do
  use Still.DataCase

  alias Still.{Preservation, Writing}

  @tag :tmp_dir
  test "portable export contains current writing and earlier versions", %{tmp_dir: dir} do
    {:ok, entry} = Writing.save_entry(nil, "one line <script>carefully escaped</script>")
    {:ok, _} = Writing.save_entry(entry, "new words", checkpoint: true)

    path = Preservation.export!(dir)
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

    payload = path |> File.read!() |> Jason.decode!()
    assert payload["format"] == "still-1"

    assert [%{"body" => "new words", "earlier_versions" => [%{"body" => old}]}] =
             payload["entries"]

    assert old == "one line <script>carefully escaped</script>"
  end

  @tag :tmp_dir
  test "export records undated writing as before and preserves its source and titled revisions",
       %{tmp_dir: dir} do
    manifest = Path.join(dir, "lists.json")

    File.write!(
      manifest,
      Jason.encode!(%{
        format: "still-lists-1",
        entries: [
          %{
            title: "From:Before:",
            body: "old\n\twords",
            source_key: "before",
            source_group: "page",
            notebook: "notebook",
            source_order: 3,
            source: %{
              original_title: "From before",
              original_body: "- old\n\twords",
              artifacts: [%{path: "source.doc", sha256: "hash", format: "doc"}]
            }
          }
        ]
      })
    )

    {:ok, _} = Writing.import_lists(manifest)
    [entry] = Writing.list_entries()
    {:ok, edited} = Writing.save_entry(entry, "old words returned", title: "Returned:")
    {:ok, _new} = Writing.save_entry(nil, "beside", beside_id: edited.id)

    payload = dir |> Preservation.export!() |> File.read!() |> Jason.decode!()
    before = Enum.find(payload["entries"], &(&1["origin"] == "before"))
    now = Enum.find(payload["entries"], &(&1["origin"] == "now"))

    assert before["created_at"] == nil
    assert before["authored_at"] == nil
    assert before["imported_at"]
    assert before["returned_at"]
    assert before["source"]["original_body"] == "- old\n\twords"
    assert [%{"title" => "From:Before:", "body" => "old\n\twords"}] = before["earlier_versions"]
    assert now["created_at"] == now["authored_at"]
    assert now["beside_id"] == before["id"]
  end
end

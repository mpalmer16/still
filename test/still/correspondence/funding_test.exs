defmodule Still.Correspondence.FundingTest do
  use Still.DataCase, async: false
  import Ecto.Query

  alias Still.Correspondence.{Funding, FundingImport}
  alias Still.{LocalRecord, Repo, Storage}

  setup do
    root = Path.join(System.tmp_dir!(), "still-funding-#{System.unique_integer([:positive])}")
    folder = Path.join(root, "collection")
    File.mkdir_p!(folder)
    old_state = Application.get_env(:still, :storage_state_directory)
    Application.put_env(:still, :storage_state_directory, Path.join(root, "state"))
    assert {:ok, _} = Storage.set_folder(folder)

    on_exit(fn ->
      if old_state,
        do: Application.put_env(:still, :storage_state_directory, old_state),
        else: Application.delete_env(:still, :storage_state_directory)

      File.rm_rf!(root)
    end)

    %{location: Storage.collection_location()}
  end

  defp opportunity(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "name" => "North Star Grant",
          "funder" => "Arts Council",
          "kind" => "grant",
          "cycle" => "2027",
          "highlighted" => false
        },
        overrides
      )

  defp json(rows), do: Jason.encode!(rows)

  test "validates unsafe or malformed imports without writing", %{location: location} do
    for row <- [
          opportunity(%{"script" => "x"}),
          opportunity(%{"source_url" => "javascript:alert(1)"}),
          opportunity(%{"application_url" => "https://user:pass@example.org/apply"}),
          opportunity(%{"deadline_time" => "17:00"}),
          opportunity(%{
            "kind" => "grant",
            "deadline" => "2027-01-02",
            "opens_on" => "2027-01-03"
          }),
          opportunity(%{"highlighted" => "yes"}),
          opportunity(%{"highlighted" => "true"})
        ] do
      assert {:error, _} = FundingImport.parse(json([row]))
    end

    assert {:ok, []} = Funding.list(location)
  end

  test "normalizes identity, previews duplicates, and reimport is add-only", %{location: location} do
    input = opportunity()
    {:ok, plan} = FundingImport.preview(location, json([input]))
    assert [%{name: "North Star Grant", cycle: "2027", highlighted: false}] = plan.opportunities
    assert {:ok, %{imported: ["North Star Grant"], skipped: []}} = FundingImport.commit(plan)
    duplicate = opportunity(%{"name" => "  NORTH   STAR grant ", "funder" => "ARTS COUNCIL"})
    {:ok, duplicate_plan} = FundingImport.preview(location, json([duplicate]))
    assert duplicate_plan.opportunities == []
    assert [%{reason: "Already in this collection"}] = duplicate_plan.skipped
    assert {:ok, %{imported: [], skipped: [_]}} = FundingImport.commit(duplicate_plan)
    assert {:ok, [saved]} = Funding.list(location)
    assert saved.name == "North Star Grant"

    assert {:ok, exported_json} = Funding.export_json(location)
    assert {:ok, [exported]} = Jason.decode(exported_json)
    refute Map.has_key?(exported, "amount")
    refute Map.has_key?(exported, "description")
    assert exported["highlighted"] == false
  end

  test "preview skips normalized duplicate rows in the file", %{location: location} do
    first = opportunity()
    second = opportunity(%{"name" => "north star grant", "funder" => " ARTS COUNCIL "})
    {:ok, plan} = FundingImport.preview(location, json([first, second]))
    assert length(plan.opportunities) == 1
    assert [%{name: "north star grant", reason: "Duplicate row in this file"}] = plan.skipped

    assert {:ok, %{imported: ["North Star Grant"], skipped: ["north star grant"]}} =
             FundingImport.commit(plan)
  end

  test "manual edits require the current token and preserve exact prior data", %{
    location: location
  } do
    {:ok, created} = Funding.save(location, opportunity())
    assert created.highlighted == false

    {:ok, changed} =
      Funding.save(
        location,
        Map.put(opportunity(), "highlighted", "true"),
        created.id,
        created.token
      )

    assert changed.highlighted

    assert {:error, _} =
             Funding.save(
               location,
               opportunity(%{"description" => "stale"}),
               created.id,
               created.token
             )

    revisions =
      Repo.all(from r in LocalRecord, where: r.scope == ^location.scope and r.kind == "revision")

    assert [%LocalRecord{data: old}] = revisions
    assert old["description"] == nil
    assert old["highlighted"] == false
  end

  test "a collection switch invalidates a reviewed import without partial writes", %{
    location: location
  } do
    {:ok, plan} = FundingImport.preview(location, json([opportunity()]))
    other = Path.join(Path.dirname(location.folder), "other-collection")
    File.mkdir_p!(other)
    assert {:ok, _} = Storage.set_folder(other)
    assert {:error, _} = FundingImport.commit(plan)
    assert {:ok, _} = Storage.set_folder(location.folder)
    assert {:ok, []} = Funding.list(location)
  end
end

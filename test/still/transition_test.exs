defmodule Still.TransitionTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Still.{Repo, Transition}
  alias Still.Writing.{Entry, RoomState, Version}

  setup context do
    tmp_dir =
      Path.join(System.tmp_dir!(), "still-transition-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    if context[:unboxed] do
      :ok
    else
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
      Repo.delete_all(RoomState)
      Repo.delete_all(Version)
      Repo.delete_all(Entry)
      %{tmp_dir: tmp_dir}
    end
  end

  test "the plan preserves imported rows and ambiguous provenance with all revisions" do
    imported =
      entry!(%{
        origin: "before",
        source_key: "lists:synthetic-source",
        source_group: "Notebook/1-title",
        notebook: "Notebook",
        source_order: 1,
        source: %{"artifacts" => [%{"path" => "synthetic.docx", "sha256" => "abc"}]},
        title: "Original title",
        body: "original imported words"
      })

    {:ok, _} = Still.Writing.save_entry(imported, "edited imported words")

    ambiguous =
      %Entry{}
      |> Ecto.Changeset.change(origin: "now", source_key: "", body: "keep me")
      |> Repo.insert!()

    candidate = entry!(%{body: "synthetic experimental writing"})

    Repo.insert!(%Version{
      entry_id: candidate.id,
      title: "Earlier",
      body: "earlier synthetic words"
    })

    plan = Transition.plan()

    assert plan.candidate_ids == [candidate.id]
    assert plan.protected_ids == Enum.sort([imported.id, ambiguous.id])
    assert plan.counts.candidate_versions == 1
    assert plan.counts.imported_or_provenance_entries == 2
    assert plan.blocked_references == []
  end

  test "apply requires the exact confirmation and the reviewed plan fingerprint" do
    candidate = entry!(%{body: "synthetic experimental writing"})
    plan = Transition.plan()

    assert {:error, :confirmation_required} =
             Transition.apply(expected_fingerprint: plan.fingerprint)

    assert {:error, :plan_fingerprint_required} =
             Transition.apply(confirmation: Transition.confirmation())

    assert Repo.get!(Entry, candidate.id).body == "synthetic experimental writing"
  end

  test "a plan is invalidated when provenance changes after review" do
    candidate = entry!(%{body: "synthetic experimental writing"})
    plan = Transition.plan()

    Repo.update!(Ecto.Changeset.change(candidate, source_key: "lists:became-provenance"))

    assert {:error, {:plan_changed, current}} =
             Transition.apply(
               confirmation: Transition.confirmation(),
               expected_fingerprint: plan.fingerprint
             )

    assert current.candidate_ids == []
    assert current.protected_ids == [candidate.id]
    assert Repo.get!(Entry, candidate.id).body == "synthetic experimental writing"
  end

  test "a failed backup prevents deletion", %{tmp_dir: tmp_dir} do
    candidate = entry!(%{body: "synthetic experimental writing"})
    plan = Transition.plan()
    backup_path = Path.join(tmp_dir, "not-a-directory")
    File.write!(backup_path, "synthetic file")

    assert {:error, {:backup_failed, _}} =
             Transition.apply(
               confirmation: Transition.confirmation(),
               expected_fingerprint: plan.fingerprint,
               backup_dir: backup_path
             )

    assert Repo.get!(Entry, candidate.id).body == "synthetic experimental writing"
  end

  @tag :unboxed
  test "successful apply deletes only candidates after a verified SQLite backup" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert_empty_test_database!()

      backup_dir =
        Path.join(
          System.tmp_dir!(),
          "still-transition-backup-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(backup_dir)

      imported = entry!(%{origin: "before", source_key: "lists:synthetic", body: "imported"})
      candidate = entry!(%{body: "synthetic experimental writing"})

      imported_version =
        Repo.insert!(%Version{
          entry_id: imported.id,
          title: "Before",
          body: "prior imported words"
        })

      candidate_version =
        Repo.insert!(%Version{
          entry_id: candidate.id,
          title: "Earlier",
          body: "prior experimental words"
        })

      room =
        Repo.insert!(%RoomState{
          id: 1,
          writing_id: candidate.id,
          draft_beside_id: candidate.id,
          recent: %{
            "draft_form" => "list",
            "recovery" => "keep this marker",
            "ids" => [candidate.id]
          },
          light: 38,
          letters: 50
        })

      imported_id = imported.id
      candidate_id = candidate.id
      imported_version_id = imported_version.id
      candidate_version_id = candidate_version.id
      room_id = room.id

      try do
        plan = Transition.plan()

        assert {:ok, result} =
                 Transition.apply(
                   confirmation: Transition.confirmation(),
                   expected_fingerprint: plan.fingerprint,
                   backup_dir: backup_dir
                 )

        assert result.deleted_entries == 1
        assert result.deleted_versions == 1
        assert File.regular?(result.backup)
        assert File.read!(result.backup) |> binary_part(0, 16) == "SQLite format 3\0"
        assert Repo.get(Entry, candidate_id) == nil
        assert Repo.get(Version, candidate_version_id) == nil
        assert Repo.get!(Entry, imported_id).body == "imported"
        assert Repo.get!(Version, imported_version_id).body == "prior imported words"
        state = Repo.get!(RoomState, room_id)
        assert state.writing_id == nil
        assert state.draft_beside_id == nil

        assert state.recent == %{
                 "draft_form" => "list",
                 "recovery" => "keep this marker",
                 "ids" => [candidate_id]
               }
      after
        Repo.delete_all(from v in Version, where: v.entry_id == ^imported_id)
        Repo.delete_all(from r in RoomState, where: r.id == ^room_id)
        Repo.delete_all(from e in Entry, where: e.id == ^imported_id)
        File.rm_rf!(backup_dir)
      end
    end)
  end

  test "a protected entry pointing at a candidate blocks apply without deleting either" do
    candidate = entry!(%{body: "synthetic experimental writing"})

    protected =
      entry!(%{
        origin: "before",
        source_key: "lists:synthetic",
        body: "imported",
        beside_id: candidate.id
      })

    plan = Transition.plan()

    assert [%{kind: :protected_entry_beside, entry_id: protected_id, target_id: target_id}] =
             plan.blocked_references

    assert protected_id == protected.id
    assert target_id == candidate.id

    assert {:error, {:referenced_candidates, _}} =
             Transition.apply(
               confirmation: Transition.confirmation(),
               expected_fingerprint: plan.fingerprint
             )

    assert Repo.get!(Entry, candidate.id)
    assert Repo.get!(Entry, protected.id).beside_id == candidate.id
  end

  @tag :unboxed
  test "a failed protected-corpus fingerprint rolls the transaction back" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert_empty_test_database!()

      backup_dir =
        Path.join(
          System.tmp_dir!(),
          "still-transition-rollback-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(backup_dir)

      protected = entry!(%{origin: "before", source_key: "lists:synthetic", body: "imported"})
      candidate = entry!(%{body: "synthetic experimental writing"})
      protected_id = protected.id
      candidate_id = candidate.id

      try do
        plan = Transition.plan()

        Repo.query!("""
        CREATE TEMP TRIGGER mutate_protected_before_candidate_delete
        BEFORE DELETE ON entries
        WHEN OLD.id = #{candidate_id}
        BEGIN
          UPDATE entries SET body = 'damaged' WHERE id = #{protected_id};
        END
        """)

        assert {:error, :protected_corpus_changed} =
                 Transition.apply(
                   confirmation: Transition.confirmation(),
                   expected_fingerprint: plan.fingerprint,
                   backup_dir: backup_dir
                 )

        assert Repo.get!(Entry, candidate_id).body == "synthetic experimental writing"
        assert Repo.get!(Entry, protected_id).body == "imported"
      after
        Repo.query!("DROP TRIGGER IF EXISTS mutate_protected_before_candidate_delete")
        fixture_ids = [protected_id, candidate_id]
        Repo.delete_all(from v in Version, where: v.entry_id in ^fixture_ids)
        Repo.delete_all(from e in Entry, where: e.id in ^fixture_ids)
        File.rm_rf!(backup_dir)
      end
    end)
  end

  defp assert_empty_test_database! do
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(Version, :count) == 0
    assert Repo.aggregate(RoomState, :count) == 0
  end

  defp entry!(attrs) do
    %Entry{}
    |> Entry.changeset(Map.put_new(attrs, :body, "synthetic words"))
    |> Repo.insert!()
  end
end

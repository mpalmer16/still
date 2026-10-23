defmodule Still.Transition do
  @moduledoc """
  A guarded, local preparation step for removing non-imported writing.

  `plan/0` is read-only. `apply/1` requires the exact confirmation phrase and the
  fingerprint from a reviewed plan. It makes and verifies a SQLite VACUUM INTO
  backup before opening the deletion transaction.
  """

  import Ecto.Query
  alias Still.{Preservation, Repo}
  alias Still.Writing.{Entry, RoomState, Version}

  @confirmation "DELETE NON-IMPORTED WRITING"

  def confirmation, do: @confirmation

  def plan do
    case Repo.transaction(fn -> build_plan(Repo) end) do
      {:ok, plan} -> plan
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_plan(repo) do
    entries = repo.all(from e in Entry, order_by: [asc: e.id])
    protected = Enum.reject(entries, &discard_candidate?/1)
    candidates = Enum.filter(entries, &discard_candidate?/1)
    candidate_ids = MapSet.new(candidates, & &1.id)
    versions = repo.all(from v in Version, order_by: [asc: v.id])
    room_states = repo.all(from r in RoomState, order_by: [asc: r.id])
    refs = blockers(protected, candidate_ids)

    %{
      status: :dry_run,
      counts: %{
        total_entries: length(entries),
        protected_entries: length(protected),
        imported_or_provenance_entries: Enum.count(protected, &imported_or_provenance?/1),
        ambiguous_provenance_entries:
          Enum.count(protected, &(&1.origin == "now" and imported_or_provenance?(&1))),
        other_protected_entries: Enum.count(protected, &(not imported_or_provenance?(&1))),
        versions: length(versions),
        candidate_entries: length(candidates),
        candidate_versions: Enum.count(versions, &MapSet.member?(candidate_ids, &1.entry_id)),
        blocked_references: length(refs),
        room_state_targets: length(room_state_references(room_states, candidate_ids))
      },
      protected_ids: Enum.map(protected, & &1.id),
      ambiguous_ids:
        protected
        |> Enum.filter(&(&1.origin == "now" and imported_or_provenance?(&1)))
        |> Enum.map(& &1.id),
      candidate_ids: Enum.map(candidates, & &1.id),
      blocked_references: refs,
      room_state_references: room_state_references(room_states, candidate_ids),
      fingerprint: database_fingerprint(repo)
    }
  end

  def apply(opts \\ []) do
    confirmation = Keyword.get(opts, :confirmation)
    expected_fingerprint = Keyword.get(opts, :expected_fingerprint)
    backup_dir = Keyword.get(opts, :backup_dir, backup_directory())

    cond do
      confirmation != @confirmation ->
        {:error, :confirmation_required}

      not is_binary(expected_fingerprint) or expected_fingerprint == "" ->
        {:error, :plan_fingerprint_required}

      true ->
        apply_reviewed(expected_fingerprint, backup_dir)
    end
  end

  defp apply_reviewed(expected_fingerprint, backup_dir) do
    initial = plan()

    cond do
      initial.fingerprint != expected_fingerprint ->
        {:error, {:plan_changed, initial}}

      initial.blocked_references != [] ->
        {:error, {:referenced_candidates, initial.blocked_references}}

      initial.candidate_ids == [] ->
        {:ok, %{deleted_entries: 0, deleted_versions: 0, backup: nil, plan: initial}}

      true ->
        with {:ok, backup_path} <- make_backup(backup_dir),
             :ok <- verify_backup(backup_path, expected_fingerprint) do
          delete_transaction(expected_fingerprint, initial, backup_path)
        end
    end
  end

  defp make_backup(dir) do
    try do
      {:ok, Preservation.backup!(dir)}
    rescue
      error -> {:error, {:backup_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:backup_failed, {kind, reason}}}
    end
  end

  defp verify_backup(path, expected_fingerprint) when is_binary(path) do
    if File.regular?(path) and database_fingerprint(path) == expected_fingerprint do
      :ok
    else
      {:error, :backup_does_not_match_plan}
    end
  rescue
    _ -> {:error, :backup_unverifiable}
  end

  defp verify_backup(_, _), do: {:error, :backup_unverifiable}

  defp delete_transaction(expected_fingerprint, initial, backup_path) do
    result =
      Repo.transaction(fn ->
        current = build_plan(Repo)

        if current.fingerprint != expected_fingerprint do
          Repo.rollback(:plan_changed)
        end

        if current.blocked_references != [] do
          Repo.rollback({:referenced_candidates, current.blocked_references})
        end

        candidate_ids = current.candidate_ids
        protected_ids = current.protected_ids
        before = protected_fingerprint(Repo, protected_ids)
        room_before = normalized_room_state_fingerprint(Repo, MapSet.new(candidate_ids))

        # The foreign keys are deliberately strict in this task: a protected
        # entry reference blocks deletion; room-state references are cleared by
        # the explicit targeted update below, while its recovery metadata stays.
        normalize_room_state_refs(Repo, MapSet.new(candidate_ids))

        {deleted_versions, _} =
          Repo.delete_all(from v in Version, where: v.entry_id in ^candidate_ids)

        {deleted_entries, _} = Repo.delete_all(from e in Entry, where: e.id in ^candidate_ids)

        unless protected_fingerprint(Repo, protected_ids) == before do
          Repo.rollback(:protected_corpus_changed)
        end

        unless normalized_room_state_fingerprint(Repo, MapSet.new(candidate_ids)) == room_before do
          Repo.rollback(:room_state_changed)
        end

        %{deleted_entries: deleted_entries, deleted_versions: deleted_versions}
      end)

    case result do
      {:ok, counts} -> {:ok, Map.merge(counts, %{backup: backup_path, plan: initial})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discard_candidate?(%Entry{} = entry) do
    entry.origin == "now" and not imported_or_provenance?(entry)
  end

  defp imported_or_provenance?(%Entry{} = entry) do
    entry.origin == "before" or not is_nil(entry.source_key) or not is_nil(entry.source_group) or
      not is_nil(entry.notebook) or not is_nil(entry.source_order) or nonempty_map?(entry.source)
  end

  defp nonempty_map?(value), do: is_map(value) and map_size(value) > 0

  defp blockers(protected, candidate_ids) do
    Enum.flat_map(protected, fn entry ->
      if MapSet.member?(candidate_ids, entry.beside_id) do
        [%{kind: :protected_entry_beside, entry_id: entry.id, target_id: entry.beside_id}]
      else
        []
      end
    end)
  end

  defp room_state_references(room_states, candidate_ids) do
    Enum.flat_map(room_states, fn state ->
      [:writing_id, :draft_beside_id]
      |> Enum.flat_map(fn field ->
        target = Map.fetch!(state, field)

        if MapSet.member?(candidate_ids, target) do
          [%{kind: :room_state, field: field, target_id: target}]
        else
          []
        end
      end)
    end)
  end

  defp normalize_room_state_refs(repo, candidate_ids) do
    Enum.each(repo.all(RoomState), fn state ->
      attrs = %{}

      attrs =
        if MapSet.member?(candidate_ids, state.writing_id),
          do: Map.put(attrs, :writing_id, nil),
          else: attrs

      attrs =
        if MapSet.member?(candidate_ids, state.draft_beside_id),
          do: Map.put(attrs, :draft_beside_id, nil),
          else: attrs

      if map_size(attrs) > 0, do: repo.update!(Ecto.Changeset.change(state, attrs))
    end)
  end

  defp normalized_room_state_fingerprint(repo, candidate_ids) do
    repo.all(from r in RoomState, order_by: [asc: r.id])
    |> Enum.map(fn row ->
      %{
        row
        | writing_id:
            if(MapSet.member?(candidate_ids, row.writing_id), do: nil, else: row.writing_id),
          draft_beside_id:
            if(MapSet.member?(candidate_ids, row.draft_beside_id),
              do: nil,
              else: row.draft_beside_id
            )
      }
    end)
    |> digest()
  end

  defp protected_fingerprint(repo, protected_ids) do
    entries = repo.all(from e in Entry, where: e.id in ^protected_ids, order_by: [asc: e.id])

    versions =
      repo.all(from v in Version, where: v.entry_id in ^protected_ids, order_by: [asc: v.id])

    digest({entries, versions})
  end

  defp database_fingerprint(repo) when is_atom(repo) do
    rows =
      Enum.map(["entries", "versions", "room_states"], fn table ->
        {table, repo.query!("SELECT * FROM #{table} ORDER BY id").rows}
      end)

    digest(rows)
  end

  defp database_fingerprint(path) when is_binary(path) do
    {:ok, db} = Exqlite.start_link(database: path, mode: :readonly, busy_timeout: 5_000)

    try do
      rows =
        Enum.map(["entries", "versions", "room_states"], fn table ->
          {table, Exqlite.query!(db, "SELECT * FROM #{table} ORDER BY id", []).rows}
        end)

      digest(rows)
    after
      GenServer.stop(db)
    end
  end

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp backup_directory do
    Repo.config()[:database]
    |> Path.dirname()
    |> Path.join("backups")
  end
end

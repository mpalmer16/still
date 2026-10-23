defmodule Mix.Tasks.Still.PrepareTransition do
  use Mix.Task

  @shortdoc "Review or apply a guarded non-imported writing transition"
  @confirmation "DELETE NON-IMPORTED WRITING"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args,
           strict: [apply: :string, plan_hash: :string, backup_dir: :string],
           aliases: [a: :apply, h: :plan_hash, b: :backup_dir]
         ) do
      {[], [], []} -> print_plan(Still.Transition.plan())
      {opts, [], []} -> apply_transition(opts)
      _ -> Mix.raise(usage())
    end
  end

  defp print_plan(plan) do
    Mix.shell().info("Dry run only; no writing was changed.")
    Mix.shell().info("Entries: #{plan.counts.total_entries}")

    Mix.shell().info(
      "Imported or provenance protected: #{plan.counts.imported_or_provenance_entries}"
    )

    Mix.shell().info("Other protected: #{plan.counts.other_protected_entries}")
    Mix.shell().info("Non-imported candidates: #{plan.counts.candidate_entries}")
    Mix.shell().info("Versions attached to candidates: #{plan.counts.candidate_versions}")
    Mix.shell().info("Blocked historical references: #{plan.counts.blocked_references}")
    Mix.shell().info("Room-state pointers to reset: #{plan.counts.room_state_targets}")
    Mix.shell().info("Candidate IDs: #{Enum.join(plan.candidate_ids, ", ")}")
    Mix.shell().info("Plan fingerprint: #{plan.fingerprint}")

    Mix.shell().info(
      "To apply, pass --apply '#{@confirmation}' and --plan-hash with this fingerprint."
    )
  end

  defp apply_transition(opts) do
    if opts[:apply] != @confirmation or is_nil(opts[:plan_hash]) do
      Mix.raise(usage())
    end

    apply_opts = [confirmation: opts[:apply], expected_fingerprint: opts[:plan_hash]]

    apply_opts =
      if opts[:backup_dir],
        do: Keyword.put(apply_opts, :backup_dir, opts[:backup_dir]),
        else: apply_opts

    case Still.Transition.apply(apply_opts) do
      {:ok, %{deleted_entries: entries, deleted_versions: versions, backup: backup}} ->
        Mix.shell().info("Removed #{entries} entries and #{versions} versions.")
        if backup, do: Mix.shell().info("Verified backup: #{backup}")

      {:error, {:plan_changed, plan}} ->
        Mix.shell().error("The collection changed after the dry run. Review a new plan.")
        print_plan(plan)
        Mix.raise("Transition cancelled.")

      {:error, {:referenced_candidates, refs}} ->
        Mix.raise("The plan contains historical references to candidates: #{inspect(refs)}")

      {:error, reason} ->
        Mix.raise("Transition cancelled: #{inspect(reason)}")
    end
  end

  defp usage do
    "Usage: mix still.prepare_transition [--apply '#{@confirmation}' --plan-hash FINGERPRINT [--backup-dir PATH]]"
  end
end

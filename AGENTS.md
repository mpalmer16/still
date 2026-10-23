# Still development conventions

- Keep Still a local, single-person writing place. Do not add accounts, cloud services, analytics, telemetry workers, feeds, scores, or organization the writer has to maintain.
- Put persistence, revision, recovery, search, and rediscovery rules in contexts. Keep LiveViews focused on interaction.
- Treat writing as important data: preserve earlier words, reject stale edits, and keep backups and exports verifiable.
- Use Phoenix LiveView and escaped HEEx for the interface. Keep browser JavaScript limited to editor recovery and keyboard behavior.
- Use `mix ecto.gen.migration` for schema changes. Run `mix assets.build` after asset edits and `mix precommit` before finishing.
- Test the behaviors that could lose writing or make it impossible to find. Verify Docker and the README against an empty and an established collection.
- Do not deploy, publish, add a Git remote, or expose the app beyond localhost.

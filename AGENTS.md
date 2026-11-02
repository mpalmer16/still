# Still development conventions

- Keep Still a local, single-person writing place. Do not add accounts, cloud services, analytics, telemetry workers, feeds, scores, or organization the writer has to maintain.
- Put persistence, revision, recovery, search, and rediscovery rules in contexts. Keep LiveViews focused on interaction.
- Treat writing as important data: preserve earlier words, reject stale edits, and keep backups and exports verifiable.
- Use Phoenix LiveView and escaped HEEx for the interface. Keep browser JavaScript limited to editor recovery and keyboard behavior.
- Use `mix ecto.gen.migration` for schema changes. Run `mix assets.build` after asset edits and `mix precommit` before finishing.
- Test the behaviors that could lose writing or make it impossible to find. Verify Docker and the README against an empty and an established collection.
- Do not deploy, publish, add a Git remote, or expose the app beyond localhost.

## Repository maintenance

- Keep tracked files limited to application source, build configuration, maintained tests, and current documentation. Keep personal writing, imported documents, databases, backups, credentials, logs, dependency caches, and app bundles out of Git and build contexts. Never force-add ignored collection data.
- Use synthetic writing and disposable folders for verification. Do not change the installed app or a personal collection as part of build checks. Native backend checks supplement manual window, keyboard, folder-picker, and recovery checks.
- Run the importer and browser helper checks when relevant: `python3 -m unittest discover -s scripts -p 'test_*.py'` and `node --test scripts/test_*.mjs`. Native build and lifecycle instructions live in `native/NOTES.md`.
- Keep Git identity repository-local. Use the configured personal account; do not change global identity, switch connected accounts, or alter archival repositories.
- If the user explicitly authorizes publication, first verify the configured fetch/push destination, personal authentication, repository ownership and privacy, and remote main history. Review the exact commits and tracked contents. Never force-push or publish additional branches or tags without authorization. After an approved push, verify local and remote commit IDs match.

# Still development conventions

## Development leadership

- Act as lead developer: own the design, architecture, integration, review, and final verification. Keep the writer's intended experience central when choosing implementation details.
- Use Luna subagents (`gpt-6-luna`) as needed for bounded implementation, investigation, test, or review tasks. Give each agent a clear scope, relevant context, file ownership when editing, and an expected result. Delegate independent work when useful; keep tightly coupled architectural decisions with the lead.
- Review agent findings and changes before integrating them. Avoid overlapping edits, unnecessary delegation for trivial tasks, and silent substitution of another subagent model if Luna is unavailable.

## Product and implementation

- Keep Still a local, single-person writing place. Do not add accounts, cloud services, analytics, telemetry workers, feeds, scores, or organization the writer has to maintain.
- Preserve the character and capabilities of echoes, Threads, notebook reading, search, and correspondence through storage changes. Retain meaningful regression tests; surface substantive design tradeoffs rather than quietly dropping behavior or preserving obsolete code through awkward new structures.
- Put persistence, revision, recovery, search, and rediscovery rules in contexts. Keep LiveViews focused on interaction.
- Treat writing as important data: preserve earlier words, reject stale edits, and keep backups and exports verifiable.
- Use Phoenix LiveView and escaped HEEx for the interface. Keep browser JavaScript limited to editor recovery, keyboard behavior, and explicit copy-to-clipboard actions.
- Use `mix ecto.gen.migration` for schema changes. Run `mix assets.build` after asset edits and `mix precommit` before finishing.
- Test the behaviors that could lose writing or make it impossible to find. Verify Docker and the README against an empty and an established collection.
- Do not deploy, publish, add a Git remote, or expose the app beyond localhost.

## Storage direction

These are requirements for the storage redesign, not a claim that the current application already implements them.

- Work with writer-selected local text files and folders. Drive, another sync service, and an ordinary local directory must work the same way. Do not require a provider-specific path, account, running sync client, or online service. If a location is unavailable, explain that and ask for a usable location; do not silently create a different collection.
- Accept ordinary text files without requiring a `.txt` extension, Still format marker, UUID wrapper folder, or metadata sidecar. Preserve authored line breaks, blank lines, indentation, and explicit-title meaning. Handle unsupported encodings or binary formats explicitly; do not silently convert or discard content.
- The writer supplies readable local text. Do not add `.gdoc` ingestion, Google Docs export, or Drive API workflows to Still. Any preparation of old source documents is upstream of the application's file access.
- The current words live in the ordinary files. A local SQLite database outside synchronized folders holds stable identities, relative file locations, notebook/List numbering and order, title metadata, earlier words, discovery indexes, Places and icons, and correspondence records including exact submitted words. Indexed text must follow the files rather than becoming a separate editable edition.
- Notebook and List numbering are the primary sequence when dates are unknown. Preserve original labels, gaps, suffixes, notebook series, and years. Never substitute import or modification timestamps for writing chronology. Notebooks can exist empty, have an explicitly chosen current notebook, and optionally describe the physical notebook and pen. Writing without a notebook association is valid.
- Moving or correcting a file should retain its identity and relationships when a match is reliable. Do not merge distinct Lists merely because their wording matches. Distinguish an unavailable folder from intentional deletion, and resolve ambiguous matches explicitly.
- Keep one latest verified database backup in the writer-selected location alongside the writing. Replace it safely without accumulating dated snapshots, per-piece revision folders, or exported metadata files. Earlier words and submission history belong in the database.
- Follow the agreed transition order: representative format pilot, storage implementation and feature verification, authorized reset, then full archive conversion/import. The writer accepts discarding old Still state; do not create extra transition backups or safekeeping collections. Original archive documents remain untouched until their agreed conversion and replacement.

## Repository maintenance

- Keep tracked files limited to application source, build configuration, maintained tests, and current documentation. Keep personal writing, imported documents, databases, backups, credentials, logs, dependency caches, and app bundles out of Git and build contexts. Never force-add ignored collection data.
- Use synthetic writing and disposable folders for verification. Do not change the installed app or a personal collection as part of build checks. Native backend checks supplement manual window, keyboard, folder-picker, and recovery checks.
- Remove disposable verification artifacts afterward. Do not leave progress reports, copied databases, rollback app bundles, or other just-in-case material in the repository.
- Run the importer and browser helper checks when relevant: `python3 -m unittest discover -s scripts -p 'test_*.py'` and `node --test scripts/test_*.mjs`. Native build and lifecycle instructions live in `native/NOTES.md`.
- Keep Git identity repository-local. Use the configured personal account; do not change global identity, switch connected accounts, or alter archival repositories.
- If the user explicitly authorizes publication, first verify the configured fetch/push destination, personal authentication, repository ownership and privacy, and remote main history. Review the exact commits and tracked contents. Never force-push or publish additional branches or tags without authorization. After an approved push, verify local and remote commit IDs match.

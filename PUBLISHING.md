# Personal repository maintenance

Still's source lives in the private personal repository `mpalmer16/still`.
The original local repository remains an archival reference; its history and
writing collection are not part of this repository. No collection is supplied.

## Identity and destination

The verified personal author is Michael Palmer, `mpalmer1661@gmail.com`.
Author settings are repository-local. Do not modify global identity or the
archival repository. Connected tools may be signed into a work account; do not
switch those accounts or use them as a substitute for the personal push identity.

The existing remote is:

```text
git@github-personal:mpalmer16/still.git
```

Do not add or replace remotes as part of routine maintenance. Publication requires
explicit user approval of the branch or commit. The checks below verify that
approval's destination; they do not themselves authorize a push.

## Review before publication

```sh
git status --short --branch
git log --format=fuller main..HEAD
git diff --stat main...HEAD
git diff main...HEAD
git ls-files
git remote -v
git config --local --get user.name
git config --local --get user.email
git config --local --get user.useConfigOnly
```

Expect the personal identity above and `useConfigOnly=true`. Inspect committed
files for writing, credentials, absolute home paths, databases, imported documents,
exports, backups, session keys, logs, dependency caches, and application bundles.
Publish committed source only. Never force-add ignored collection data.

Validate with synthetic fixtures and disposable collections:

```sh
mix precommit
mix assets.build
python3 -m unittest discover -s scripts -p 'test_*.py'
```

See `native/NOTES.md` for native builds and lifecycle checks. Verification bundles
must use a separate identity and disposable data; never replace the installed app.
Use Docker with disposable empty and established collections when runtime or
packaging configuration changes.

## Verify personal authentication and repository privacy

```sh
git remote get-url origin
git remote get-url --push origin
ssh -T git@github-personal
```

Both remote URLs must equal `git@github-personal:mpalmer16/still.git`. SSH must
report `Hi mpalmer16! You've successfully authenticated`; GitHub normally exits
with status 1 because it does not provide shell access.

Verify `mpalmer16/still` is **Private** and owned by the personal account in an
already authenticated personal GitHub browser session. If an existing personal
API connection is available, its repository metadata can verify owner `mpalmer16`,
owner type `User`, and `private: true` instead. A work-connected integration's 404
is not proof of privacy or absence. If personal authentication or privacy cannot
be verified, stop before pushing and report the blocker. Do not switch work-account
authentication or print tokens.

Read the current remote before merging approved changes:

```sh
git ls-remote origin refs/heads/main
```

Compare with the local `main` history. If the remote contains unfamiliar commits,
fetch and review them before proceeding; never overwrite them with a force push.

## Publish only the approved main

After review, merge the approved branch locally and repeat appropriate verification.
Confirm `main` has the reviewed source, the worktree is clean, and the destination
checks still pass. Then, only with publication approval:

```sh
git push origin main
git rev-parse main
git ls-remote origin refs/heads/main
```

The local and remote SHAs must match. Verify the repository remains private and
inspect its committed contents. Do not push maintenance branches, archived
branches, or tags unless separately requested. Do not force-push.

## Historical preparation and current boundaries

The initial source-only commit started a fresh personal history. It removed
private examples and machine paths, required an explicit importer source folder,
and refreshed the locked Bandit/Decimal security dependencies. Provenance keys
and source placement rules remain for compatibility; published fixtures are
synthetic. The old local repository retains the archival history.

The live SQLite database remains local and outside synchronized folders. The
storage-backup milestone adds consistent snapshots into an explicitly chosen
folder; it does not migrate writing or implement provider synchronization. See
`README.md` for settings, backups, and the future ordinary-file storage boundary.

Mac bundles target their build machine's architecture and OS. Local ad-hoc signing
is not notarized distribution. Backend smoke checks supplement physical window,
folder-picker, keyboard, close/cancel, and WebKit recovery verification.

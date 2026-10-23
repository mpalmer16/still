# Still

Still is a private, local place to write in the company of old writing. **Now**
is one blank page for a poem, list, fragment, or anything else. New writing is
kept as ordinary text files. The historical Lists remain in SQLite, with their
notebooks, provenance, earlier words, and paths through the room.

There are no accounts, cloud APIs, analytics, feeds, or hosted services. A folder
service may synchronize your files; Still works with the local folder itself.

## Write and return

Open Still into **Now**. Begin anywhere; a title is optional. Line breaks,
blank stanzas, tabs, indentation and trailing spaces are not interpreted or
reformatted. New input uses LF; an unchanged body or title-only edit retains
existing CRLF bytes. Editing text in a browser uses its LF newline convention.

**Save** or Cmd/Ctrl+S explicitly saves a file in the chosen collection. Typing
keeps a local recovery copy, but does not save the authoritative file. **Read**
or Cmd/Ctrl+Enter saves the latest words before opening their reading view.
**Saved writing**, beneath the editor, opens the pages you have kept. Open a
page to read it and choose **Change these words** to edit its words or title.
Earlier versions appear beneath the reading view. The wordmark opens a new
blank page; **Now** returns to the current piece.

A historical fragment can approach after a pause when your language shares
literal words with the past. Timing, peripheral placement and restrained
movement use the existing Still echo system. New files do not become part of
that historical corpus. Following an echo opens the List for reading; **Now**
returns to the same file or local draft, preserving words, caret, selection and
scroll in the same browser/profile where possible. A changed disk token makes
recovery explicit rather than silently treating a local copy as current.

**Light**, **Letters**, the room map, notebook order, **Find**, **Wander** and
**Back where I was** retain the historical reading experience. Find searches
the SQLite collection, including earlier words when requested. Saved new writing
is a separate shelf reached from Now or Find, with no writing categories. Native
**File → Open Writing…** (Cmd+O) opens that shelf; **File → New Writing** (Cmd+N)
opens a blank page. There is no separate Poetry or New List destination. Old
`/list` and `/poems` addresses remain compatibility aliases to the unified pages.

## Choose a collection folder

The active historical SQLite database stays in its existing writing folder.
Do not put the live database in a synchronized folder. Choose a separate local
root through **Storage & Backups**, reached from Find or the editor's **Save
location** details. In the Mac app, **File → Choose Backup Folder…** opens the
native picker. In a browser, enter an existing absolute path on the computer
running Still. This setting supplies both the database snapshot destination
and the directory for new writing files. It need not be a Google Drive folder.

Before setup, Now still accepts a **local draft**, clearly marked as not saved
as a file. Choose a folder, return to Now, and use **Refresh folder choice** in
Save location before saving a new draft. The displayed location changes only
when you explicitly adopt the choice. Saved editors opened against an earlier
root refuse writes after a switch; reopen the desired collection through Saved
writing. Missing folders produce guidance and never trigger a fallback save.
Changing or clearing the setting leaves existing files untouched.

The first file format keeps its original disk names for compatibility:

```text
chosen-root/
  poems/
    .still-poems.json
    <stable-uuid>/
      poem.txt
      metadata.json
      revisions/<timestamp>-<uuid>/
        poem.txt
        metadata.json
    .trash/<stable-uuid>/             # same complete directory after Delete
```

These names do not assign a type to the writing. No existing file needs to be
moved or migrated. Text is UTF-8 and independently readable; metadata holds an
optional title, stable identity, creation/modification dates and relative
filename. Renaming a title retains the UUID. An externally renamed single
`.txt` file is recognized; keep its UUID directory and metadata together.
Synchronize the complete tree, including marker, history and Trash.

Saves compare a token covering file names, directory structure and bytes,
including earlier revisions. Stale edits are rejected. A changed save first
freezes the prior words/title; hidden staging, flushed files, local atomic
renames and a verification journal protect interrupted two-file saves.
Ambiguous, incomplete, unknown-format or symlinked paths are left with an error.
An index is unnecessary to reconstruct the shelf.

The `.still-poems-lock` beside `poems/` coordinates local Still processes. A
crash may leave that lock. Close every Still process before manually removing
only the lock directory; preserve writing files and journals. External editors
and synchronization tools ignore Still's lock and can race the last token
check. Use one writing computer at a time, let synchronization settle, and
reopen externally edited files before continuing. Arbitrary outside edits have
no automatic revision capture. Unsupported directory flushing remains a
filesystem limitation. Still confirms local saving, not cloud upload.

## Delete and restore

Read saved writing and choose **Delete**, then confirm **Move to Trash**. The
complete file directory, title and all earlier words move together. Choose
**Saved writing → Trash → Restore** to return it. Historical SQLite Lists never
have this Delete control. In Trash, **Delete permanently…** opens a second
confirmation; **Delete permanently** removes that directory and its history.
A changed token refuses stale deletion. A partial filesystem failure is
reported explicitly, with instructions to refresh and inspect the folder.

Permanent deletion covers those saved files, not unsent words in another tab
or browser/profile, provider-side copies, or independent backups. Still does
not erase another editor's unconfirmed local recovery copy.

## Recovery and local settings

The current document cursor is machine-local JSON beside backup settings,
scoped to the active database and collection. It stores IDs, not words or
portable machine paths. Configuring a folder retains the active new draft;
explicitly starting another page changes Now without deleting the earlier
saved file. Damaged cursor state produces an error instead of silently
opening a different document.

Browser and Mac WebKit recovery stores are separate. Recovery survives
navigation/reopening in the same profile; do not clear site data while relying
on an unsent copy. A recovery offer never writes a file until Save. Distinct
pending copies survive delayed save replies. If recovery-key migration fails
after the first save, newer words remain reachable through a new blank page's
recovery offer. Browser storage failure is visible and in-page navigation is
blocked for unsecured changed words. Browser back/close/crash cannot guarantee
recovery when storage itself is unavailable. Native navigation, writing-folder
switch and close also refuse to abandon such words.

Machine-local settings default to `~/.config/still/`. Use
`STILL_LOCAL_STATE_DIRECTORY` to isolate a development session. These settings
and the current-page cursor do not belong in the synchronized collection or Git.
Existing experimental SQLite writing and browser drafts are not silently
deleted on launch. See the deliberate transition below.

## Database backups

Use **Back Up Now** in Storage & Backups or the native File menu. Still uses
SQLite `VACUUM INTO`, verifies integrity, flushes and publishes a uniquely
named snapshot before recording success. It never copies the live database.
The previous valid backup survives failure. There is no scheduler or retention
service. **Open Backup Folder** / **Show Backup Folder** reveals the chosen root
when a desktop opener is available; otherwise use the displayed host path.

Freshness compares logical database contents with the verified snapshot,
including entries, revisions and reading/room state, rather than timestamps.
New file writing is separate from this status and is not included in SQLite
backups or the SQLite JSON export. Preserve the complete `poems/` tree too.
Local recovery copies are not database backups. Cloud upload is not confirmed.

Mac close/quit offers **Back Up & Close**, **Close Without Backing Up**, or
**Cancel** when the database has changed. Failed backups keep the app open.
Without a destination, closing does not force setup. Browser operation retains
manual backup. Native writing-folder selection opens another SQLite collection;
it does not move data and waits for safe recovery before switching.

## Run from source or in a browser

Host development requires Elixir/Erlang and the existing dependencies:

```sh
mix setup
mix phx.server
```

Development uses `still_dev.db` unless explicitly overridden. To isolate every
part of a review session, choose disposable database, state and port settings:

```sh
STILL_DATABASE_PATH=/tmp/still-review/data/still.db \
  STILL_LOCAL_STATE_DIRECTORY=/tmp/still-review/state mix ecto.create
STILL_DATABASE_PATH=/tmp/still-review/data/still.db \
  STILL_LOCAL_STATE_DIRECTORY=/tmp/still-review/state mix ecto.migrate
STILL_DATABASE_PATH=/tmp/still-review/data/still.db \
  STILL_LOCAL_STATE_DIRECTORY=/tmp/still-review/state PORT=4001 mix phx.server
```

Use an existing disposable root in Storage & Backups before saving files.
The interface is served locally by Phoenix in both Mac and browser operation.
Do not expose it beyond localhost. Run one process at a time per collection.

Docker is optional:

```sh
docker compose up --build
```

Open `http://localhost:4000`; Docker binds to `127.0.0.1` only. Use
`STILL_PORT=4010` for another host port. Database data defaults to `./data` or
`STILL_DATA_DIRECTORY`; rebuilding does not remove it. Stop with
`docker compose down`. To mount the explicitly chosen file/backup root:

```sh
STILL_BACKUP_DIRECTORY="/path/to/existing/local-folder" \
  docker compose -f compose.yaml -f compose.backups.yaml up --build
```

Enter `/app/backup-destination` in Storage & Backups. The optional mount refuses
a missing host folder. Stop using the same two Compose files. Plain Compose
works normally without a file root. A headless container cannot open Finder.

## Native preview and packaging

`./native/build.sh` packages Phoenix, SQLite and the runtime into `dist/Still.app`.
Run `mix deps.get` before the first build; packaging also needs Xcode command-line
tools and Python 3. The resulting app needs no terminal, Docker or Homebrew at
runtime. It is locally signed for the build machine, not a universal notarized
installer. Building does not install or replace the existing application.

For review, use a separate bundle identity, executable, port, database and state.
The explicit runtime overrides are essential; build-time hints alone do not
isolate a fresh preview. See [native/NOTES.md](native/NOTES.md) for the complete
safe preview commands, lifecycle details and native checks. Do not point a
preview at real writing without separate approval.

## Historical preservation and deliberate transition

Imported records retain their exact text, notebook provenance/order,
relationships and earlier versions in SQLite. Historical reading, editing and
recovery remain available. Legacy non-imported SQLite pages remain readable
until an intentional cleanup; new Now never creates SQLite entries. Historical
edit conflicts can keep a separate copy as a new file in the selected root.

Review a clean-slate plan against an explicitly chosen database:

```sh
STILL_DATABASE_PATH="/path/to/disposable/still.db" mix still.prepare_transition
```

This is a dry run. It protects every `origin = before` record and any row with
import provenance, even ambiguous metadata. Only origin-now records with no
provenance are candidates. The report lists exact IDs, candidate versions,
blocked historical references and a fingerprint of one consistent snapshot.
Apply requires both `--apply 'DELETE NON-IMPORTED WRITING'` and
`--plan-hash FINGERPRINT` from the reviewed plan. It first makes and verifies a
consistent SQLite backup, rechecks that the plan is unchanged, then deletes
only candidates and their revisions in a transaction. Historical references
that would change block the operation. Protected rows and revisions are
fingerprinted before/after and any mismatch rolls back.

The tool never runs automatically. No real collection is approved for this
transition yet. Browser/WebKit recovery data is separate and remains untouched;
review obsolete experimental drafts deliberately after preserving needed
historical recovery copies. The new file editor does not load old SQLite Now
draft keys. Future historical imports remain a separate intentional workflow.

For an independent SQLite preservation copy or JSON export:

```sh
STILL_DATABASE_PATH="/path/to/collection/still.db" mix run -e 'IO.puts(Still.Preservation.backup!())'
STILL_DATABASE_PATH="/path/to/collection/still.db" mix run -e 'IO.puts(Still.Preservation.export!())'
```

These commands produce `backups/` and `exports/` beside that database and include
its historical revisions and provenance. They do not include new file writing.
Stop every process before restoring a snapshot; preserve the prior database and
its WAL/SHM files before replacing it. Never restore a live database.

## Verification

```sh
mix precommit
mix assets.build
node --test scripts/test_file_recovery.mjs
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 native/smoke.py --bundle "dist/Still Preview.app"
```

Tests use synthetic writing and disposable folders. Native smoke covers empty
and established databases, occupied ports, rapid reopening and backend owner
cleanup. Pure Swift lifecycle/location checks and actual UI checks are described
in the native notes. Source and data must remain separate; see
[PUBLISHING.md](PUBLISHING.md) for the reviewed publishing procedure.

### The writing page

Now offers a wider page with inner margins. Long lines wrap on screen; Save retains the
line breaks and indentation you actually entered. A title is always optional. Saved writing
without one is listed by its first nonblank line (up to 60 characters, including an ellipsis).
The label does not change the text or fill in an explicit title.

While you type in the body, the title and room controls fade. Move the pointer, press
Escape, or focus a control to bring them back. Escape moves to Save; Tab within the body
continues to indent. Warnings and recovery notices stay visible, and older Lists can still
appear beside the page. Reduced-motion preferences remove the fade animation.

# Using Still

[← Still](../README.md)

Still is a private, local place to write in the company of old writing. **Write**
is one blank page for a poem, list, fragment, or anything else. New writing is
kept as ordinary text files, with identities, indexes and earlier words in the
local SQLite database. Historical Lists retain their notebooks, provenance,
earlier words and paths through the room.

There are no accounts, cloud APIs, analytics, feeds, or hosted services. A folder
service may synchronize your files; Still works with the local folder itself.

The [ordinary-text storage model](storage-model.md) describes the current format. New writing uses ordinary text files in a selected local folder; its identities, indexes, revisions and correspondence remain in the local SQLite database. Archive preparation is separate from ordinary file access.

## Write and return

**Page width**, beside Letters, adjusts the writing surface independently of type
size. Still remembers the preferred width and limits it to leave room for echoes
on the current screen. **Reset** returns to the original width.

Enter carries the current line's tabs and spaces onto the next line. After two
consecutive indented lines, Enter returns to the left margin. **Shift+Enter**
continues the indent even then; Tab, Shift+Tab and Backspace remain available for
manual changes. Pasting existing writing does not apply these keyboard defaults.

For new writing, **Save to scratch** keeps the page in an unnumbered Scratch folder
without changing the current notebook or using its next List number. Open Scratch
from Notebooks or find its pages in Saved writing. Later edits use the usual Save.

In notebook contents, **Section details** lets you edit a section's displayed name.
Click a section heading to collapse or expand its Lists. In the current notebook,
older sections start closed; the section receiving new Lists starts open. Returning
to a particular List opens its section automatically.
**New Lists here** chooses that section and notebook for new writing. Numbers continue
across the whole notebook; changing the destination never moves an already saved page.
Section names are display labels; the ordinary folders keep their existing names.

Open Still into **Write**. Begin anywhere; a title is optional. Line breaks,
blank stanzas, tabs, indentation and trailing spaces are not interpreted or
reformatted. New input uses LF; an unchanged body or title-only edit retains
existing CRLF bytes. Editing text in a browser uses its LF newline convention.

**Save** or Cmd/Ctrl+S explicitly saves a file in the chosen collection. Typing
keeps a local recovery copy, but does not save the authoritative file. **Read**
or Cmd/Ctrl+Enter saves the latest words before opening their reading view.
**Saved writing**, beneath the editor, opens the pages you have kept. Open a
page to read it and choose **Change these words** to edit its words or title.
The overlapping-squares **Copy text** button copies the exact body and an
explicit title once, with a brief **Copied** response. Automatic first-line
labels are not prepended. In an editor, it uses the current words, including
changes that have not reached Save.
Earlier versions appear beneath the reading view. The wordmark opens a new
blank page; **Write** returns to the current piece.

While you type, the title and room controls fade. Move the pointer, press
Escape, or focus a control to bring them back. Escape moves focus to the page
controls; Tab within the body indents. Warnings and recovery notices stay
visible, and reduced-motion preferences remove the fade animation.

**New**, beside Save, opens a blank page after the current words are saved. If
there are unsaved changes, it keeps them in the editor and asks you to Save
first. It does not write an unconfigured draft.

A historical fragment can approach after a pause when your language shares
literal words with the past. Timing, peripheral placement and restrained
movement use the existing Still echo system. New files do not become part of
that historical corpus. Following an echo opens the List for reading; **Write**
returns to the same file or local draft, preserving words, caret, selection and
scroll in the same browser/profile where possible. A changed disk token makes
recovery explicit rather than silently treating a local copy as current.

Echoes now follow the passage around your caret after a short pause. Moving back
into an earlier stanza lets its language draw different company. A selected word
or phrase is a deliberate listening point; one uncommon selected word can admit a
faint echo, while ordinary isolated typing keeps the existing restraint. Blank
stanza gaps leave the field quiet. Listening never changes the words, caret, or
selection, and an imported saved edition excludes its own historical original.

Lean toward an echo with the pointer, or Tab to its link: a little of its original
surrounding language unfolds. The neighboring lines come from the same authored
stanza. Leaving folds them back; following the link still opens the source. Long
contexts keep the original glimpse. Nothing cycles or keeps moving while idle;
reduced-motion preferences remove the unfolding transition.

When wandering with a current List or reading a saved page, pause your pointer over
a passage, select its text, or Tab to it to draw related echoes. The echoes stay
available as you move the pointer to them. Choose **Whole page** to clear the
passage focus.

Notebook contents and Find results open a quiet reader under Find. **Previous**
and **Next** keep you in the notebook; **Contents** returns to the selected List
in its index. A Find match keeps its query, earlier-words choice and place in
the results, including results revealed with **Keep looking**.

Choose **Wander with this** to open that same piece with echoes and connections.
Wander keeps a **Back to reading** link to the place you left. **Continue reading**
in Find and in a notebook resumes that place. Each notebook remembers its own
place in the local database, independently of the writing open in Write.

**Light**, **Letters**, the room map, notebook order, **Find**, **Wander** and
**Back where I was** retain the historical reading experience. Find searches
the SQLite collection, including earlier words when requested. Saved new writing
is a separate shelf reached from Write or Find, with no writing categories. Native
**File → Open Writing…** (Cmd+O) opens that shelf; **File → New Writing** (Cmd+N)
opens a blank page. There is no separate Poetry or New List destination. Old
`/list` and `/poems` addresses remain compatibility aliases to the unified pages.

## Choose a writing folder

Choose an existing, readable and writable local folder. It may be an ordinary
folder or one synchronized by a service you use; Still accesses only the local
files and does not contact the service. The live SQLite database stays in its
machine-local location outside this folder. In the Mac app, use **File → Choose
Writing Folder…**. In a browser, enter the folder's absolute local path in
Storage & Backups. In the Mac app, its path controls are routed through the
recovery-aware File menu. If the chosen folder becomes unavailable, Still keeps
the selection visible and asks you to reconnect it or choose a usable folder. It
never silently opens or creates a different writing collection.

The current text of each saved piece is an ordinary file directly inside the
chosen folder. Existing filenames and extensions are accepted; Still does not
require a marker, UUID directory, or metadata sidecar. The file contains the
current words, with authored line breaks, blank lines and indentation kept.
An optional explicit title remains in the file. Stable file identity, title
role, relative path, notebook/List numbering and order, earlier words, search
index, Places and icons, and exact correspondence/submission records stay in the
local SQLite database. Indexed text follows the files rather than becoming an
editable copy. The database is not placed in a synchronized folder.

For example, a root can contain files like these:

```text
writing-folder/
  Morning walk.txt
  notebook 3a.md
  letter to myself
  still-backup.sqlite3
```

This is only an illustration; names and extensions are up to you. Saving a new
piece creates an ordinary text file. Unless you enter a filename, Still uses the
marked title line or the first nonblank line, with a number added if the name
is already used. Spaces and colons become underscores, including a final colon:
`this:is:the:title:` becomes `this_is_the_title_.txt`. Other unsafe filename
characters are replaced; the text stays exact.
Numbering belongs to the whole notebook; sections never restart it. A new List
gets the next number after the notebook's highest numbered List, across all its
sections. Existing gaps and suffixes are retained; `0042b`
is followed by `0043`. An empty notebook starts at `1`. The number prefixes the
filename, for example `0043_this_is_the_title_.txt`. **Save location & file name**
shows the notebook, section, next List number, and proposed file path. Leave the
path blank for that default, or enter a path in another notebook folder. Notebook
placement follows the file path. When adding a collection such as Poems, turn off **Number new Lists automatically**
in its notebook details. Existing filenames stay intact and future writing uses
the title alone; the collection is shown by filename within each section.
Writing without a notebook can also remain unnumbered. An empty opening falls back to Untitled.txt. To correct an existing name, read
the piece and open **Text file and title meaning → File name → Rename file**.
Renaming keeps the file in its current folder and retains its identity, List
number, and earlier words. Editing a title does not automatically rename an
existing file. Still uses hidden temporary files while
publishing a save, then removes them. Revisions and Trash state are in SQLite,
not in per-piece folders. A successful save keeps prior words in the database
before publishing newer file contents. If the file changed externally since it
was opened, Still refuses the stale save and leaves both versions available for
review. Unsupported encodings, binary files, unreadable paths, and symlinked
file paths produce an explicit problem; Still does not silently convert them.

Use one Still writer at a time for a given local database. Still locks file
writes beside its local database; synchronization tools and external editors do
not honor that lock and can race a save. Let synchronization settle and reopen
externally edited files before continuing. Still confirms local writes, not
provider upload. Sync the chosen writing folder for current text, and retain the
separate database backup for revisions and collection metadata.

## Delete and restore

Notebook title actions appear on hover or keyboard focus, with **Read**,
**Wander**, and **Delete** beside the title. On touchscreens these stay visible.
To remove a duplicate directly, open its notebook index and choose **Delete**
beside the List, then **Permanently delete**. This removes its text file and
earlier words from the local database. Exact submitted words in Correspondence
remain. The confirmation names the List being removed.

Read saved writing and choose **Delete**, then confirm **Move to Trash**. The
current text file is removed after its words and title have been retained in
SQLite. Choose **Saved writing → Trash → Restore** to return it. Historical SQLite Lists never
have this Delete control. In Trash, **Delete permanently…** opens a second
confirmation; **Delete permanently** removes that piece's SQLite history.
A changed token refuses stale deletion. A partial filesystem failure is
reported explicitly, with instructions to refresh and inspect the folder.

Permanent deletion removes the saved text file and its database history. It does not remove provider-side copies, independent backups, or unsent words in another tab or browser/profile. Still does
not erase another editor's unconfirmed local recovery copy.

## Recovery and local settings

The current document cursor is machine-local JSON beside backup settings,
scoped to the active database and collection. It stores IDs, not words or
portable machine paths. Configuring a folder retains the active new draft;
explicitly starting another page changes Write without deleting the earlier
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

The chosen writing folder holds one latest verified database backup named
`still-backup.sqlite3`. Use **Back Up Now** in Storage & Backups or the native
File menu. Still builds a consistent SQLite snapshot, checks its integrity and
collection identity, flushes it, then safely publishes it. A successful backup
replaces that one file. If the destination already contains an unrelated
SQLite database, an unrecognized file, or a symbolic link, Still preserves it
and reports the problem. A new computer or newly initialized database must
restore the matching collection backup before replacing an existing backup.
The Mac app checks after one minute and then every five minutes while open.
It refreshes the single verified backup when the database changes.

The backup contains the local database: stable file identities and indexed
current text, notebook/List metadata, earlier words, Places and icons, and
correspondence, including exact submitted manuscripts. It does not replace the
ordinary text files, which remain the current-text authority. Keep the writing
folder synchronized or copied as well. Browser and Mac
recovery copies remain in their respective local browser profiles and are not
part of the database backup. A local backup confirms file creation only; it
does not confirm synchronization upload.

Restore is explicit and requires Still to be closed. Run the restore task with
the verified backup, a new local database path, and the existing text folder:

```sh
mix still.restore /path/to/still-backup.sqlite3 /local/state/still.db /path/to/writing-folder
```

The task verifies the backup before creating the new database, refuses an
existing destination, reconnects the selected collection identity, and
reconciles the text files without changing their words. If the database holds
more than one writing-root identity, specify the one to reconnect with
`--collection UUID`. It never replaces the active database. Do not point Still
at an unavailable folder and accept a new empty collection as a substitute.

Mac close/quit protects unsaved words through local recovery. Backup reminders
on close are off by default, so closing does not take or request a backup.
**Back Up Now** remains available when you deliberately want one.

To restore the reminder later, enable **File → Remind Me to Back Up on Close**.
It then offers **Back Up & Close**, **Close Without Backing Up**, or **Cancel**
when database state has changed. Turning it off leaves backup verification and
saved words unchanged; it does not declare the database backed up.

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
`docker compose down`. To make an existing local writing-and-backup root available inside the container:

```sh
STILL_BACKUP_DIRECTORY="/path/to/existing/local-folder" \
  docker compose -f compose.yaml -f compose.backups.yaml up --build
```

Enter `/app/backup-destination` in Storage & Backups. The optional mount refuses
a missing host folder; ordinary text files and `still-backup.sqlite3` are stored
there, while the SQLite database stays in `/app/data`. Stop using the same two
Compose files. Plain Compose works normally without a writing root. A headless
container cannot open Finder.

## Native preview and packaging

`./native/build.sh` packages Phoenix, SQLite and the runtime into `dist/Still.app`.
Run `mix deps.get` before the first build; packaging also needs Xcode command-line
tools and Python 3. The resulting app needs no terminal, Docker or Homebrew at
runtime. It is locally signed for the build machine, not a universal notarized
installer. Building does not install or replace the existing application.

For review, use a separate bundle identity, executable, port, database and state.
The explicit runtime overrides are essential; build-time hints alone do not
isolate a fresh preview. See [native/NOTES.md](../native/NOTES.md) for the complete
safe preview commands, lifecycle details and native checks. Do not point a
preview at real writing without separate approval.

## Historical writing and the collection transition

Legacy SQLite notebooks remain readable during the transition. Ordinary-file
writing is indexed in SQLite for discovery, notebook reading, and earlier
words, but the index is never an independently editable edition. New writing
and transcriptions use the same ordinary-file editor.

Complete and verify the storage implementation before resetting the old Still
collection or installing the replacement application. Identify the exact
Still-owned database, collection folders, and obsolete backups before cleanup.
The agreed reset discards the old Still state without creating another
transition backup. Never include original archive documents in that cleanup.
Neither startup nor a build runs a reset.

Prepare and verify the full archive only after that reset. Preserve all text,
original notebook/List labels, numbering gaps, suffixes, and established title
meaning. Ordinary files need no numbered layout; an archive layout is an
explicit import convention, not a prerequisite for opening text. Cloud-native
document preparation stays upstream of Still. Choose the resulting existing
local folder when it is ready.

Notebooks are folders inside the selected writing root. **Add a notebook**
creates a folder, including an empty notebook. You can also create folders in
Finder. Choosing a current notebook is separate; new writing goes into its
folder. To change an existing piece’s notebook, move its file in Finder and
refresh Saved writing. Its history follows a reliably recognized move.

For ongoing care, use the one verified database backup and keep the current
text files as well. Restore with the command in **Database backups** above.
Do not copy a running SQLite database or replace one while Still is open.

## Verification

```sh
mix precommit
mix assets.build
node --test scripts/test_*.mjs
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 native/smoke.py --bundle "dist/Still Preview.app"
```

Tests use synthetic writing and disposable folders. Native smoke covers empty
and established databases, occupied ports, rapid reopening and backend owner
cleanup. Pure Swift lifecycle/location checks and actual UI checks are described
in the native notes. Source and data must remain separate; see
[AGENTS.md](../AGENTS.md#repository-maintenance) for repository maintenance and publication boundaries.

## Correspondence

Correspondence keeps file-backed writing, manually maintained journals, ordered
submission packets, and replies together in the selected collection. Sent manuscripts
keep immutable copies; nothing is submitted automatically. The historical Lists and
the Write writing experience keep their existing behavior. The editorial workspace
uses a wide editorial layout, with an explicitly chosen work on the desk,
shortlisted Places, side-by-side work history, a curated Places directory, and a
live ordered manuscript in packet preparation.
Graphite is the default dark color; Night blue, Forest, and Plum are available.
Still remembers the chosen dark color and the optional Light appearance across
visits to Correspondence. The writing room keeps its own light.

See [the Correspondence guide](correspondence.md) for the workflow, portable
record layout, recovery boundaries, and a disposable synthetic preview. The preview
runs separately from the installed application:

```sh
./scripts/preview_correspondence.sh
```

Places can be added from a reviewed JSON upload using **Correspondence → Places →
Import Places**. The page includes an example to share with a researcher; a portable
copy is in `docs/places-import-example.json`. Places can also be deactivated and
reactivated without losing submission history. Optional `keywords` (a comma-separated
string) find literal, case-insensitive word and phrase echoes in current saved titles
and text. Open a place for **Pieces to consider**, or a work for **Places to consider**;
each suggestion shows its shared words. These are reading prompts, not editorial-fit
judgments. From a place you can also keep any saved piece as a personal possibility,
and remove that connection later. Removing a connection leaves any keyword echo visible.
Historical Lists and earlier revisions are not searched by these suggestions.

Optional `reach` is `unknown` (the default), `approachable`, `stretch`, or `long_shot`.
Use `reach_note` for why it feels that way. Reach is your impression, separate from a
publication’s age, fees, or submission effort. All three fields can be imported and
edited later. Existing place files open without conversion, with no keywords or personal
connections and unknown reach; imports still skip existing names rather than updating them.
See [Correspondence](correspondence.md).

Places also accept an optional `description` (a short blurb) and `icon_url` (an
HTTP or HTTPS link to a PNG, JPEG, GIF, WebP, or ICO image). Opening the directory,
a place, or the home shortlist downloads missing icons automatically without
blocking the page. Still tries the supplied image first, then the website’s
`/favicon.ico`; unavailable images use the publication’s initial. Existing places
with websites get the same automatic fallback without reimporting. Change the
image link in **Edit place details** to replace it.

Successful images are saved locally and work offline. Failed attempts are retried
on a later visit after one day. Downloads are limited to 256 KiB each and public
web addresses; SVG and HTML are not displayed as icons. No writing, cookies, or
personal notes are sent. Imports only validate image links; they never require a
successful download. Database backups include saved images and correspondence records. Copy or sync
the ordinary text root separately to retain current writing.

## Threads — a word travels

**Threads**, in the main navigation, follows literal recurring words between historical
notebooks and saved file writing. Choose a word already found in the collection, or
open **A word of your own** and enter one. Matching is case-insensitive and uses whole
Unicode words: `river` does not silently become `rivers`. Current words are used;
Trash, unsaved drafts, and earlier versions stay outside this reading room.

Two passages appear beside one another, favoring a crossing between an older List
and a saved page, or between notebooks. **Whole pages** unfolds both complete texts;
**Passages** returns to their original matching stanzas. **Another crossing** changes
the pairing. Other matching passages continue beneath, and **Open this page** leads
to the normal reading view. **Let another word find me** follows another discovered
word. **Follow a word**, beneath a historical List or saved page, begins with words
from that particular piece.

This is a reading surface: it creates no categories, scores, saved arrangements, or
interpretations. Discovery and pairing do not write files or database records. Exact
source text and stanza whitespace remain intact. An original List and its explicitly
saved edition share a source identity, so they cannot create a false recurrence or
be paired as independent pages. If a chosen collection folder becomes unavailable,
Still explains the problem and leaves historical notebooks readable. Interrupted saves
are reported without replaying their journals or creating collection locks.

Saved file reading also offers one quiet historical companion when the existing
literal echo system finds a strong connection. Its own imported original is excluded;
weak connections leave the page quiet. Following the companion leaves the current
writing position intact.

### A separate, disposable preview

```sh
./scripts/preview_threads.sh
```

Open **http://localhost:4097/threads**. Docker binds only to localhost. This builds the
current checkout into `still-threads-preview:local`, starts one container, and prepares
invented notebooks and saved pages in one named volume. It mounts no host writing
folders and uses separate settings, database, collection, and browser origin. A small
banner identifies the preview. Subsequent starts keep your experiments in that volume.
Set `STILL_PREVIEW_PORT=4098` to use another port. Docker must already be running.

```sh
./scripts/preview_threads.sh stop     # keep the preview for later
./scripts/preview_threads.sh remove   # remove its container, data volume, and image
```

Removal deletes only this preview's disposable writing. It leaves the installed Still
app, your real collection, other containers, and the source checkout alone. There is no
extra worktree or installed application to clean up.

The same disposable preview includes **A page to listen beside**. Open it from Saved
writing, place the caret in the orchard stanza and then the harbor stanza, and pause
to let the company change. Hover or Tab to the echo to hear a little more of its
source. The historical **Orchard:Harbor:** List offers the same passage listening
while reading. Both examples are invented; existing preview pages stay intact.

## Read a notebook

Open **Notebooks**, choose a notebook, and open a piece. The index stays on the
left while the words appear in the middle. Choose another piece or use Previous
and Next to read in notebook order. On a narrow window, Notebook index switches
between the index and the page. Continue reading returns to the saved place.
Wander with this takes the current piece into Wander and keeps a way back.

Find opens a focused reader with a way back to the same search results. If the
writing folder cannot be read or another Still is updating it, Find explains the
problem and offers Try again; an unavailable collection is never an empty result.

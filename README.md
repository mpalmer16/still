# Still

Still is a private, local place to write. The room holds words being written now and Lists from before. It has no account, cloud service, analytics, or outside API. Your writing stays on your computer.

## Open the room

After building and installing the Mac application, open **Still** from the Dock or from **Applications**. You can also press Cmd+Space, type **Still**, and press Return. The optional installation destination below is `/Applications/Still.app`.

Still starts its own local backend and stops it when you quit. Docker and a terminal are unnecessary while using the app. Its first window opens generously; later launches remember your size and position. Double-click the native title bar to use your Mac's normal zoom/fill behavior, or choose **Window → Zoom**. Native fullscreen is Ctrl+Cmd+F.

To rebuild from source, quit Still, then run:

```sh
./native/build.sh
ditto dist/Still.app /Applications/Still.app
```

The build needs Elixir/Erlang, Xcode command-line tools, and Python 3. Run `mix deps.get` before the first build. The resulting bundle includes the runtime and targets the architecture and macOS version of the build machine. It is signed locally, rather than distributed as a universal or notarized installer. Still remembers its writing folder independently of the app bundle. File → Choose Writing Folder opens an existing collection or a new empty folder; File → Show Writing Folder reveals the current location. Existing words stay in their original folder when you switch. A folder switch waits for saving and refuses to leave unresolved recovery copies behind. See [native/NOTES.md](native/NOTES.md) for packaging and lifecycle details.

A separately identified preview build is optional; see the native notes. Open only one application process at a time against a collection, including Docker and host development. The source repository contains no writing collection. See [PUBLISHING.md](PUBLISHING.md) for the reviewed manual publishing procedure.

Still opens where you were writing. Start an empty page through the wordmark or Cmd+N in the native app and begin anywhere. **New List** opens the same writing surface with room for an optional title. Colons, bullets, commas, branches, and prose can share the page; there are no item fields to maintain. **Wander** begins somewhere among old and recent writing. Follow a quiet echo, stay near, or move farther away. Pieces that appeared together still know one another. **Find** searches titles and words when you remember something. Remembered words may appear anywhere in a piece, in any order; capitalization, accents, and separating punctuation do not need to match. A query made only of symbols still searches those symbols literally. Results show and highlight the matching passage; opening a result goes to those lines. Choose **Include earlier words** to search retained versions too. Historical results are labeled and open read-only, with a link back to the current words; reading them never restores them.

For a List's place in a notebook, choose **Browse notebooks** in Find, or choose a notebook name in the room's map. The index shows every List's current title in its preserved source order, with **Beginning** and **End** links. Editing a List does not move it to the top. Notebook 1's source sections keep their separate sequences. **Previous** and **Next** beneath a List follow the index from beginning to end, including the boundary between source sections. Editing does not change that sequence. **Back where I was** retraces the last 32 reading stops, including historical versions and their search, without changing Now. Open any title to read; the notebook's **index** link beneath the writing returns to that title in the index. Now continues to hold the writing you left.

To bring in a List from elsewhere, choose **New List** and paste the complete block into the writing. When an opening looks like a title, Still offers **Use first line as title** or **Leave it here** beneath the words. You can also adjust the title yourself or keep writing. Nothing is extracted automatically. Accepting the opening keeps the complete original paste in **Earlier words**, including text that had not yet reached autosave. The local export includes those earlier words.

**Light**, at the lower left, moves between smooth dark greys and blues. The background has no grain or texture. **Letters**, beside it, adjusts the writing from 17px to 33px, keeping the existing 21px default. Nearby text grows more gently. Controls and peripheral writing remain readable throughout Light and in fullscreen; keyboard focus is visible, reduced motion is respected, and the room map becomes a scrollable list in narrow windows. Both choices persist. The place name at the lower right reveals where the notebooks sit; choose a name to open its index. While writing, a fragment may approach after a pause when your words share enough literal language. A deliberate List item such as `water:` can create one faint pull; further words can strengthen or replace it. In a wide room, a second independent fragment can occupy the other darkness. Small windows place one fragment in the page after the words. Reading can also reveal a recent piece beside an older List, or an old echo beside recent writing. Following it opens a reading path and keeps the current Now in place. Fragments can always be ignored.

The Lists are editable: choose **Change these words**. Earlier words remain available, and an old List stays in its source place when edited today. **Write beside this** begins new writing with the old piece nearby. Source information and material that preceded a List remain under **Where these words were**.

Cmd/Ctrl+K opens Find; Cmd/Ctrl+Shift+L opens Light. Escape closes the room controls, or returns from reading to Now with the caret and scroll position where you left them. Inside the editor, Escape moves to the page controls so Tab can leave the writing. While reading, Option+Left stays near and Option+Right moves farther away. Option+Shift+Left/Right follows the notebook sequence, and Option+Up retraces the reading path. The **Save** button or Cmd/Ctrl+S saves immediately; autosave also runs as you write. **Saved writing** reopens new pages and imported Lists you have changed, with the most recently saved first. In the Mac app, **File → Open Writing** or Cmd+O opens that view, and **File → Save** or Cmd+S saves. **All writing** includes the whole collection. Cmd/Ctrl+Enter reads what you have written. Tab indents inside the editor; Shift+Tab removes an indent.

## In a browser

The Docker workflow remains available:

```sh
docker compose up --build
```

Open **http://localhost:4000**. Leave the terminal open, or add `-d` to run in the background. Stop with Ctrl+C or `docker compose down`. If port 4000 is occupied, use `STILL_PORT=4010 docker compose up --build` and open `http://localhost:4010`.

Docker publishes on `127.0.0.1` only. The native app uses a separate stable local origin at port 4040. Docker defaults to `./data`; a fresh native build defaults to Application Support unless it adopts an existing `./data/still.db` on its first launch. These locations need not be the same. If you choose a different native writing folder, point Docker at that same folder with `STILL_DATA_DIRECTORY="/absolute/path/to/writing" docker compose up --build`, or keep the collections separate. Keep these ports local.

## Where the writing lives

Writing lives in `still.db`, an SQLite database inside the chosen writing folder, alongside its local `.secret_key_base`. Manual preservation commands keep backups and exports in that folder; **Back Up Now** uses the separately configured destination described below. On the first launch of an updated build, Still adopts the existing `./data` collection when available and remembers it with a filesystem bookmark. Fresh builds without an existing collection start in `~/Library/Application Support/Still/Writing`. The File menu can choose another folder at any time after pending words are saved or recovered.

Moving Still.app does not move its writing or require a rebuild. Renaming a chosen writing folder keeps its remembered WebKit recovery identity. If the remembered folder or drive is unavailable, Still asks you to choose it rather than silently opening an empty collection. Choosing a different folder opens that folder's collection; it does not copy or move any words.

Docker uses `./data` beside this README by default, or the folder passed in `STILL_DATA_DIRECTORY`. Data and local keys remain ignored by Git. Rebuilding either application leaves writing intact. The preservation commands below use the repository collection as their example; substitute the folder shown by **File → Show Writing Folder** if yours is elsewhere.

Still saves after a short pause in typing. **Saving…** changes to **Saved on this Mac** after confirmation. Use **Save** for an immediate save and **Saved writing** to reopen your pages; imported Lists you have changed appear there too. Untouched imported Lists remain in **All writing** and their notebooks. The browser or native WebView also holds unsent text in local storage until the server confirms it saved. If a connection drops or a window closes mid-sentence, reopen the same page in the same application and use the recovery prompt. Native WebKit and your browser have separate recovery storage, even though saved writing is shared. Earlier versions can be restored from **Earlier words**. Do not clear site data while relying on an unsent copy.

## Bring Lists into Still

Choose the folder containing your source documents explicitly. Still never modifies it. A local extraction step reads Word, DOCX, and ODT structure into a manifest; importing that manifest creates editable Lists in Still. Clear alternate-format copies are combined within their source neighborhood. Individually titled pieces that appeared together remember that relationship.

On macOS, extraction needs Python 3 and the built-in Word converter. It uses no external service or additional Python packages:

```sh
python3 scripts/import_lists.py --source "/path/to/source-lists" --output data/lists.json
```

Import into the collection the native app and Docker open:

```sh
STILL_DATABASE_PATH="$PWD/data/still.db" mix ecto.migrate
STILL_DATABASE_PATH="$PWD/data/still.db" mix still.import data/lists.json
```

The importer skips source pieces that already live in Still. Running it again preserves your edits. The manifest and local extraction files are ignored by Git. The original files remain in the selected source folder.

## Storage and manual backups

Your active SQLite database stays in its existing writing folder. A synchronized
backup folder is a separate destination; choosing one does not move, migrate, or
make the database read-only. Do not put the live `still.db` in Google Drive or any
other synchronized folder.

In the Mac app, choose **File → Choose Backup Folder…** and select any existing
local folder. It can be a folder synchronized by Google Drive or another service;
Still does not connect to that service. Use **File → Back Up Now** to create a
verified snapshot and **File → Show Backup Folder** to reveal the destination.
**File → Storage & Backups…** shows the last successful backup and whether the
database has changed. **Clear Backup Folder** forgets the destination without
moving or deleting the database or any backup.

In a browser, open **Find → Storage & Backups** (or `/storage`). Enter an absolute
folder path on the computer running Still, choose **Use This Folder**, and use
**Back Up Now**. **Refresh Status** checks again after changes in another window.
**Open Backup Folder** opens the folder on that computer when a desktop opener is
available; on a headless server/container, use the displayed path to open its host
folder yourself. Browser close events do not trigger backups or reminders.

No folder is configured by default; normal writing still works. If a chosen folder
or drive becomes unavailable, Still retains that destination and reports the
problem. Reconnect the drive or explicitly choose another folder. It never
creates a replacement destination or falls back to another folder.

Backup settings and success records are machine-local JSON, separate from the
writing database and backup files. By default they live under `~/.config/still/`,
scoped to the active database path. `STILL_LOCAL_STATE_DIRECTORY` can choose another
local state directory. Keep that directory outside source control, synchronized
folders, and portable writing records. Docker uses `/app/data/local-state` in its
existing local data volume. Moving the active database to a different path starts
with separate backup settings; choose the destination again there.

For Docker, explicitly mount an existing host destination with the optional file:

```sh
STILL_BACKUP_DIRECTORY="/path/to/local-synchronized-folder" \
  docker compose -f compose.yaml -f compose.backups.yaml up --build
```

Then enter `/app/backup-destination` in Storage & Backups. The optional mount refuses
a missing host path rather than creating one. Stop it using the same two Compose
files. Plain `docker compose up --build` continues to work without a backup folder.

Each completed backup is a uniquely named folder containing `still.db`. Still uses
SQLite `VACUUM INTO`, verifies integrity, flushes the file, and publishes it from a
private staging folder before recording success. It keeps earlier completed
backups; there is no automatic retention, background backup service, or scheduler.
An interrupted `.partial` folder is not a completed backup. On failure, Still
reports the problem and retains previous completed backups. A finished snapshot
whose success record could not be saved is reported as an error, not a confirmed
current backup.

Freshness compares logical schema and table contents against the actual completed
snapshot, including entries, revisions, and reading/navigation state. It does not
use modification timestamps. A deleted or altered last backup makes the status
unverified. New reading activity or room settings can make the database changed,
even when the words are the same. A concurrent edit after a snapshot needs another
backup. Unsent recovery copies remain in their browser or WebKit profile; they
are included only after their writing is saved to the database.

On Mac window close or Quit, changes since the last verified backup trigger
**Back Up & Close**, **Close Without Backing Up**, or **Cancel**. Still waits for
the editor's save acknowledgment before checking. Back Up & Close requires an
available folder and successful verification; a failure or newer change keeps
the app open. Without a folder you can close without backing up, or cancel and
choose one. A manual backup in progress must finish before closing.

“Backup completed” confirms a local file only. Check your synchronization service
separately before relying on a cloud copy. Still cannot confirm cloud upload.
Use the completed snapshot's `still.db` with the restore procedure below, after
stopping every process using the collection.

### Poems as portable files

Open **Find → Poems**, or **File → Poems** in the Mac app. Choose **A blank page**
to transcribe or compose. The body starts empty; the title is optional. Save is
explicit: **Save poem** or Cmd/Ctrl+S writes the displayed file destination.
Open a poem to read it; **Edit poem or title** revises the words or renames its
optional title. Earlier words appear beneath the saved poem. Nothing interprets,
extracts, or reformats the poem into List items.

Poems use the same explicitly chosen folder as Storage & Backups, in a separate
`poems/` directory. In the Mac app use **File → Choose Backup Folder…**; in a
browser enter an existing local folder in **Storage & Backups**. This can be an
ordinary local folder before you configure any synchronization provider. Keep
the active SQLite database in its existing local folder. Choose the destination
before saving; the editor displays its collection path. If you choose a folder
from the native menu while a new draft is open, use **Refresh folder choice**
before Save. **Save location** reveals the complete text-file path. Changing or clearing
that setting changes the open poem collection without moving or deleting files.
A page opened against the previous destination refuses to save into a different
collection; return through Poems to open the newly selected destination.

Before a folder is chosen, the blank editor still works as a **local draft**.
Typing keeps recovery copies in the current browser or native WebKit profile;
these are clearly distinguished from a saved collection file. **A blank page**
also offers recovery of that browser/profile's previous new-poem draft. Choose a
folder, return to the blank page, bring back the recovery copy, and explicitly
save it. Existing poems offer local recovery when reopened for editing. If browser
capacity prevents moving a new draft's recovery key after its first successful
save, any newer unsaved words remain reachable through **A blank page**. A
recovery copy does not overwrite a file until you choose Save. Distinct pending
copies are retained when a save response arrives after further typing.

Browser and Mac profiles have separate recovery stores. Do not clear site data
while relying on one. If browser storage is unavailable, Still shows a warning;
keep the page open and save the poem or copy its words elsewhere. In-page
navigation is blocked for an unsecured changed draft; browser close/back/crash
behavior cannot guarantee recovery when browser storage itself is unavailable. The Mac app
refuses to close or switch its writing folder while a poem's only unsaved words
lack a safe recovery copy. A safely retained local draft can close without
forcing folder setup. Native reopening returns to its last poem editor. Browser
sessions can reopen `/poems/new` or the saved poem's edit address.

The portable collection format is:

```text
chosen-folder/
  poems/
    .still-poems.json                 # format marker
    <stable-uuid>/
      poem.txt                        # authoritative UTF-8 body
      metadata.json                   # id, optional title, creation/modification dates, filename
      revisions/
        <timestamp>-<revision-uuid>/
          poem.txt                    # earlier body, readable independently
          metadata.json               # earlier title and capture date
```

The title is separate from the body. Renaming a title retains the identifier and
text filename. You may rename a poem's single `.txt` file outside Still; keep its
UUID directory and metadata together, then reopen it. More than one text file,
missing metadata, unknown collection formats, or unsafe symlinks produce a
visible error and leave files in place. Synchronize the complete `poems/` tree,
including its marker, metadata and revisions. No database or cloud-specific
record is required to reconstruct the collection.

The context preserves text bytes, including tabs, blank stanzas and final
newlines. New browser input uses LF line endings; an unchanged body or title-only
edit preserves an existing body's CRLF bytes. Editing text in a browser follows
the browser's newline convention. It never trims whitespace or guesses a title.
Each changed Still save first captures the prior body and title in a readable
immutable revision. External edits made wholly outside Still have no automatic
revision capture; reopen them before further editing in Still.

Saves compare content and metadata tokens, not modification timestamps, and
reject a stale edit. Interrupted two-file saves retain a verification journal;
Still completes only recognized old/new file states. Ambiguous external changes
are left untouched with an error. Temporary files and revision staging are not
completed saves. Files are flushed and published with local atomic renames;
unsupported directory-flush operations remain a filesystem limitation.

An exclusive `.still-poems-lock` directory prevents independent local Still
processes from writing the collection at once. It is transient and is not a
synchronization engine. A process crash can leave the lock behind. Close **all**
Still processes using the destination before removing only that lock directory,
then reopen; keep any `.save-journal.json` and writing files for verified recovery.
Never remove a lock while another process is writing. Use one editing computer
at a time, let folder synchronization settle before switching, and avoid editing
outside Still during a Save. An external editor that ignores the lock can still
race the final filesystem rename. Still does not confirm cloud upload.

SQLite backups and JSON exports still contain only the existing database
writing. They do **not** contain poem files or browser recovery copies. Preserve
or synchronize the complete poem tree separately. The existing SQLite database
continues to hold historical Lists, all prior writing, provenance, revisions,
notebook relationships, and reading state. No entry is migrated or linked into
the poem collection. Future manuscript metadata, journals, submissions,
responses and frozen packets remain a later milestone; they are not implemented.

## Preserve and move your writing

From the repository, the host tools can create a consistent SQLite backup of the native collection:

```sh
MIX_ENV=dev STILL_DATABASE_PATH="$PWD/data/still.db" mix run -e 'IO.puts(Still.Preservation.backup!())'
```

For a portable JSON copy of every current page and its earlier versions:

```sh
MIX_ENV=dev STILL_DATABASE_PATH="$PWD/data/still.db" mix run -e 'IO.puts(Still.Preservation.export!())'
```

With Docker running, the equivalent commands are:

```sh
docker compose exec -T still /app/bin/still rpc 'Still.Preservation.backup!()'
```

```sh
docker compose exec -T still /app/bin/still rpc 'Still.Preservation.export!()'
```

These explicit preservation commands put backups under `./data/backups/` and JSON copies under `./data/exports/`. The Back Up Now interface instead uses your configured backup destination. Writing can continue while the copies are made. Copy a `.db` backup to another drive to protect against loss of this computer. The JSON includes List titles, source relationships, notebook context, and earlier words. Historical authored dates remain unknown; import time is recorded separately. JSON contains plain-text writing and is for reading or migration; use the SQLite backup to restore Still itself.

To restore a backup, quit Still.app. If using Docker, also run `docker compose down`. Then replace the database; the commands below preserve the previous one in case you change your mind:

```sh
mv data/still.db data/still-before-restore.db
mv data/still.db-wal data/still-before-restore.db-wal 2>/dev/null || true
mv data/still.db-shm data/still-before-restore.db-shm 2>/dev/null || true
cp data/backups/CHOSEN_BACKUP.db data/still.db
```

Replace `CHOSEN_BACKUP.db` with a filename from `data/backups/`, then reopen Still.app or run `docker compose up`. You can remove the `still-before-restore` files after checking the restored writing.

## Updating and removing

After source changes, quit Still and rebuild the installed app without touching data:

```sh
./native/build.sh
ditto dist/Still.app /Applications/Still.app
```

Quit Still.app before replacing its bundle. For Docker, use `docker compose up --build`.

To remove the installed app, quit Still and move `/Applications/Still.app` to the Trash. Its writing folder stays intact. To remove the development collection too, first copy any words or backups you want to retain and, if using Docker, run `docker compose down --rmi local`. Then delete this directory, including `data`. Deleting `data` removes the database and any backups or exports kept there; copy what you want to retain first.

## Development

Still uses Phoenix LiveView, Ecto, and SQLite. For a host development session:

```sh
mix setup
mix phx.server
```

Host development uses a separate `still_dev.db` by default. To open the imported collection on the host:

```sh
STILL_DATABASE_PATH="$PWD/data/still.db" mix phx.server
```

Use `PORT=4001` as well if Docker is running on 4000. Host development binds to localhost. Run `mix precommit` before committing changes. `mix assets.build` builds the small JavaScript bundle and stylesheet.

The local importer tests run with `python3 -m unittest discover -s scripts -p 'test_*.py'`. All collection fixtures are synthetic and run without private documents or an import manifest. After building the native app, `python3 native/smoke.py` exercises its backend with disposable empty and fabricated established collections; it never reads a personal database. Foundation-only writing-location checks are described in [native/NOTES.md](native/NOTES.md).

The app has no deletion action. Earlier words are retained when an existing page is changed in a new session. The local JSON export is intentionally a command instead of a browser download route.


The separate poem recovery helpers have dependency-free Node checks:

```sh
node --test scripts/test_poem_recovery.mjs
```

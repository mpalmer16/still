# A native body for Still

The shell registers app-scoped WebKit text-checker defaults before creating the
application: continuous spelling enabled, grammar and automatic correction off.
The names match [WebKit's Mac text checker](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/TextCheckerMac.mm).
Standard responder-chain Edit → Spelling actions and WebKit's context menu own
suggestions, temporary ignores and the system learned dictionary. HTML opts out
of spellcheck at the room boundary and opts in only for the writing textarea.
No custom dictionary, grammar service, automatic text rewriting or browser hook
is introduced. Learned words belong to macOS and may be shared with other apps.

The native writing context menu appends **Insert poem…** to WebKit's existing
items, preserving spelling suggestions and editing commands. The action opens
the shared LiveView picker at the editor's remembered caret. A document-start
script reports editor presence after document load and LiveView navigation;
the native menu action dispatches the same explicit editor event as the writing
Menu and Cmd/Ctrl+Shift+I. It adds no renderer or file-access path in the shell.

**Save as PDF** uses `WritingPDF.swift` to paginate a verified saved snapshot
with CoreText, preserving authored line breaks and using a serif font with inset
poem passages. The title is PDF metadata rather than an added heading. The native
bridge sends bytes back to the authenticated local backend with a signed export
request; the writing context rechecks the source and linked-source snapshot
before publishing. The renderer fetches the verified words directly from that
backend rather than taking rendered text from page scripts. Completion stays
associated with the initiating request even if the writer changes pages.
No editor capture, print panel, online service or external
PDF dependency is used. Export copies stay in a sibling `<collection> Exports`
folder and **Show export in Finder** only reveals files within that folder.

The renderer's Foundation/AppKit/PDFKit tests can run without a window:

```sh
swiftc -swift-version 5 -warnings-as-errors -parse-as-library native/WritingPDF.swift native/tests/WritingPDFTests.swift -o /tmp/still-pdf-tests
/tmp/still-pdf-tests
rm /tmp/still-pdf-tests
```

`native/build.sh` assembles `dist/Still.app`. An optional installed copy lives at `/Applications/Still.app` and can be opened from the Dock, Applications, or Spotlight. After rebuilding, quit Still and use `rsync -a --delete dist/Still.app/ /Applications/Still.app/` to update that copy, then run `codesign --verify --deep --strict /Applications/Still.app`. Synchronizing the complete bundle removes obsolete generated assets that an overlay copy would leave behind. Installation does not move the writing folder. The normal bundle retains `local.still.room`, port 4040, and its existing WebKit recovery storage.
The local build needs Elixir/Erlang, the Xcode command-line tools, and Python 3. Launching the built app needs none of those tools and does not use Docker.
`native/build.sh --shell-only` rebuilds just the native window around an already assembled backend during shell development. Use the full build to include Phoenix changes.

To package an unmerged experience alongside the existing app, run this from its
checkout. These options keep the original `dist/Still.app` intact and give the
preview its own app identity, window preferences, executable and local origin:

```sh
STILL_BUNDLE_PATH="$PWD/dist/Still Preview.app" \
STILL_BUNDLE_IDENTIFIER=local.still.preview \
STILL_BUNDLE_DISPLAY_NAME="Still Preview" \
STILL_BUNDLE_EXECUTABLE=StillPreview \
STILL_NATIVE_PORT=4044 \
./native/build.sh
open --env STILL_DATA_DIRECTORY="$PWD/tmp/preview-writing" \
  --env STILL_LOCAL_STATE_DIRECTORY="$PWD/tmp/preview-local-state" \
  --env STILL_NATIVE_PORT=4044 "$PWD/dist/Still Preview.app"
```

Use the explicit launch overrides for a preview; build-time values alone are not
runtime overrides when the disposable database does not exist yet. Launching a
preview without them can open the normal default writing folder.

This example uses a separate disposable collection. Do not point development or
verification builds at personal writing. For an intentional shared collection,
quit the other native app first; the collection lock permits one native owner.
Use SQLite's backup API when preparing an established disposable collection. Do
not copy a running database directly. Neither packaging nor headless backend
checks need to launch a window. Without these options, the normal build path,
identity, executable and port remain unchanged.

The bundle contains the existing Phoenix/LiveView release, ERTS, the SQLite NIF, and any Homebrew-linked runtime libraries. The bundle size depends on the build environment. The build targets the host architecture and OS; it is not a universal, notarized installer. It is signed locally with an ad-hoc signature.

New writing is stored as ordinary text files in a chosen local writing folder. File → Choose Writing Folder selects an existing readable/writable folder; it does not need a Still database or marker file. File → Show Writing Folder reveals the selected root. The live SQLite database stays in machine-local Application Support, outside the writing root. Switching roots waits for saving and refuses to leave local recovery copies unresolved; no database is copied, moved, or replaced by this action.

The writing root is stored in machine-local Still settings scoped to the local database path. Each selected root gets a separate persistent WebKit recovery profile. A missing root remains unavailable until reconnected or another usable location is explicitly chosen; Still does not silently switch to an empty folder. Fresh installs keep local data under `~/Library/Application Support/Still/Writing`. `STILL_DATA_DIRECTORY` is an explicit scratch override for the local database and backend files; launch with it to isolate a preview. Old remembered database-folder bookmarks do not redirect the live database. No writing is copied into the app bundle.

AppKit provides a normal Dock application, persistent window placement, native fullscreen, and standard editing menus. Cmd+N opens fresh writing, Cmd+O opens Saved writing, Cmd+S saves immediately, Cmd+K opens Find, and Ctrl+Cmd+F enters fullscreen. Save and Open Writing are also in the File menu. Typing keeps a local recovery copy; Save writes the ordinary text file. WKWebView shows the existing application without tabs or an address bar. On load, the window gives keyboard focus to the writer without moving an already focused selection. It accepts navigation only to its own local origin.

The native titlebar sits above the WebView. Its double-click follows the Mac's Desktop & Dock preference. The app's standard Zoom frame fills the usable display between the menu bar and Dock; AppKit owns the zoom and restore behavior. New windows begin at 90% of that space, capped at 1700×1040 points. The exact former 1120×820 default is enlarged once; a custom saved frame is preserved. Subsequent sizing and placement use the same native frame autosave. Window → Zoom is also available, and fullscreen remains separate.

Fullscreen entry and exit update `html[data-native-fullscreen]` for the room's layout without creating another writing mode. The signal is refreshed after every complete document load. WebKit swipe-history gestures, pinch magnification, and link previews are disabled so they do not compete with Still's movement and type-size control. The shell supplies no custom pointer image and changes no system accessibility preferences.

The shell starts its own bundled backend at `127.0.0.1:4040`. This stable origin keeps WebKit's local recovery storage available across launches. The native WebKit profile is separate from a browser profile; unsent browser copies therefore remain in that browser. `STILL_NATIVE_PORT` can override the port for scratch tests. An occupied port is rejected rather than treated as Still. The availability check uses the backend’s address-reuse behavior, so a recently closed connection cannot be mistaken for a listening application during immediate reopening.
Each chosen writing root has a distinct persistent WebKit profile, so one root cannot share draft recovery copies with another. Quit Still before switching launch environments. For example: `open --env STILL_DATA_DIRECTORY=/private/tmp/still-native-room --env STILL_NATIVE_PORT=4041 dist/Still.app`.

Native launches opt into `STILL_NATIVE=true`; Docker's existing runtime behavior is unchanged. Erlang distribution is disabled. The shell locks `data/native/backend.lock` to avoid two native owners, rotates a local startup log, and creates or reuses `data/.secret_key_base`. Quit and New/Open/Find dispatch the editor-recovery flush event before leaving. File → Save dispatches a save event through that same recovery hook without leaving the editor. Quitting gives the save pause time to finish, then stops only the backend the shell started. Write reopens through the shared machine-local Desk cursor; unsent words and editor position stay in the profile’s file recovery store. Legacy experimental SQLite drafts are not reopened automatically. A separate small guard also stops that BEAM if the window process crashes.

`python3 native/smoke.py` checks the packaged backend through the native controller using a disposable empty collection and an established collection populated with fabricated records, with Homebrew removed from PATH. Use `python3 native/smoke.py --bundle "dist/Still Preview.app"` to check the separate preview; the check reads its executable name from Info.plist. It also verifies immediate repeated launches after a server-closed connection, refusal of an occupied port, and that an abrupt parent exit closes the backend listener. It never reads a personal collection and does not open a window.

The Foundation-only location checks compile and run without opening a window:

```sh
swiftc -swift-version 5 -warnings-as-errors -parse-as-library native/WritingLocation.swift native/tests/WritingLocationTests.swift -o /tmp/still-location-tests
/tmp/still-location-tests
```

These check explicit overrides, legacy adoption, a renamed folder's bookmark, missing-folder refusal, and unchanged file contents. Actual native folder-picker, window, fullscreen, keyboard, and WebKit draft recovery should also be exercised in the app after a build. Backend smoke checks do not establish those visual and interaction behaviors.

Packaging follows [Elixir releases](https://hexdocs.pm/mix/Mix.Tasks.Release.html), which bundle the runtime for a matching target, and uses Apple's [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview) and [deferred application termination](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)) APIs.
Native zoom uses [the standard frame delegate](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowwillusestandardframe(_:defaultframe:)); titlebar double-click choices remain under [Desktop & Dock](https://support.apple.com/en-gb/guide/mac-help/mchlp1119/mac).

## Backup destination and closing

File → Choose Writing Folder… selects any existing local text-file root through
the native folder picker. The picker waits for the editor to save or recover
pending words. File → Clear Writing Folder forgets the root; File → Show Writing
Folder reveals it or explains why it is unavailable. Storage & Backups… shows
backup status in the native window. Root changes from that page are disabled so
all native changes pass through the recovery-aware menu. Settings are machine-
local, scoped to the active database path, and stored outside the writing root.

Back Up Now freezes the editor, dispatches the existing recovery/save flush, and
waits for acknowledgment. It requests a verified SQLite snapshot through a narrow
localhost control route authenticated with an ephemeral per-launch token. The
token is never stored in writing or exported records.

Window close and Cmd+Q still freeze and flush the editor, and refuse to leave
changed words without a safe recovery copy. Backup reminders on close are off
by default. Closing does not check backup freshness or take a backup in that
mode. **Back Up Now** remains available for an explicit manual backup.

The Mac app checks for a needed database backup one minute after opening and
every five minutes thereafter. It uses the same verified replacement as
**Back Up Now** and defers while a file save needs recovery. The last successful
backup appears in **Storage & Backups**.

**File → Remind Me to Back Up on Close** turns the reminder on or off. This is a
machine-local preference, separate from the writing folder and backup proof.
When enabled, changed/unverified database state offers **Back Up & Close**,
**Close Without Backing Up**, or **Cancel**. A backup choice needs a successful
verified snapshot and no newer database change. Turning the reminder off does
not mark anything as backed up, delete backups, or weaken editor recovery.
Manual backup and close operations do not overlap.

The policy helper has Foundation-only tests (use a disposable output path):

```sh
swiftc -swift-version 5 -warnings-as-errors native/BackupClose.swift native/tests/BackupCloseTests.swift -o /tmp/still-backup-close-tests
/tmp/still-backup-close-tests
```

These assertions cover clean/changed/unsettled state, all three choices, missing
folder, failed backup, and a concurrent change. They supplement headless backend
checks; physical AppKit dialogs and window cancellation should also be checked
with a separately identified disposable build.



## Writing

Write uses the shared Phoenix file editor for any new writing. File → Open Writing
opens `/writing`; New Writing opens `/?new=1`. There is no separate Poems menu.
The historical reading screens keep their SQLite behavior. Shared echo markup
and gravity context preserve historical company around Write and saved ordinary-
text pieces without changing the current file as the source of its words.

The native shell flushes local file recovery before navigation, backup readiness,
folder switching and close; it never saves a file draft without an explicit save.
`FileLeavePolicy` allows a saved, blank, or safely recovered editor to leave.
Changed words without verified recovery block leaving. The database close-time
reminder explains that current text files must sync separately while the database
backup retains their indexes, earlier words and collection records.
The shared Desk cursor resumes the current document through `/` on launch;
the shell no longer maintains separate new-List and poem editor URL cursors.

The selected local writing root contains ordinary text files and one latest
verified `still-backup.sqlite3` file. The live SQLite database remains in local
Application Support or the explicitly selected scratch database directory.
Database backups include notebook and List metadata, earlier words, Places,
icons, and correspondence; sync or copy the text root separately for current
words. Existing unrelated files at the backup name are preserved. Restoring is
an explicit operation into a new local database file, followed by reconnecting
the intended text root; it never replaces the active database.

With Still stopped, restore a verified backup and reconcile an existing writing
root with:

```sh
mix still.restore /path/to/still-backup.sqlite3 /local/state/still.db /path/to/writing-folder
```

Use `--collection UUID` if the database contains more than one root identity.
The task does not start the endpoint or change any text files. It refuses an
existing database destination and leaves the live database untouched.

Use only disposable data for checks. The README describes deliberate historical
cleanup, Trash, permanent deletion, profile-local recovery, and file-lock limits.
The clean-slate tool is never invoked by native startup. No installation or real
collection transition is part of development verification.

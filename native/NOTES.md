# A native body for Still

`native/build.sh` assembles `dist/Still.app`. An optional installed copy lives at `/Applications/Still.app` and can be opened from the Dock, Applications, or Spotlight. After rebuilding, quit Still and use `ditto dist/Still.app /Applications/Still.app` to update that copy. Installation does not move the writing folder. The normal bundle retains `local.still.room`, port 4040, and its existing WebKit recovery storage.
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
STILL_DATA_DIRECTORY="$PWD/tmp/preview-writing" \
./native/build.sh
```

This example uses a separate disposable collection. Do not point development or
verification builds at personal writing. For an intentional shared collection,
quit the other native app first; the collection lock permits one native owner.
Use SQLite's backup API when preparing an established disposable collection. Do not copy a running database
without its WAL; use SQLite's backup API. Neither packaging nor headless backend
checks need to launch a window. Without these options, the normal build path,
identity, executable and port remain unchanged.

The bundle contains the existing Phoenix/LiveView release, ERTS, the SQLite NIF, and any Homebrew-linked runtime libraries. The bundle size depends on the build environment. The build targets the host architecture and OS; it is not a universal, notarized installer. It is signed locally with an ad-hoc signature.

Writing stays in a remembered local folder. File → Choose Writing Folder selects the directory containing `still.db`, or explicitly opens an empty collection in another directory. File → Show Writing Folder reveals it. Switching waits for saving and refuses to leave local recovery copies unresolved; no database is copied, moved, or replaced by this action.

The chosen directory is stored as a filesystem bookmark in the app's preferences, separately from its bundle. Renaming it keeps the current WebKit profile UUID. Moving the app needs no rebuild. Missing or invalid bookmarks offer folder selection rather than silently falling back to an empty collection. A new build carries only a first-launch legacy hint when the build's data folder contains `still.db`; an existing remembered choice wins. Fresh installations otherwise use `~/Library/Application Support/Still/Writing`. `STILL_DATA_DIRECTORY` remains an explicit scratch override and does not replace the remembered choice. No writing is copied into the app bundle.

AppKit provides a normal Dock application, persistent window placement, native fullscreen, and standard editing menus. Cmd+N opens fresh writing, Cmd+O opens Saved writing, Cmd+S saves immediately, Cmd+K opens Find, and Ctrl+Cmd+F enters fullscreen. Save and Open Writing are also in the File menu; autosave remains active. WKWebView shows the existing application without tabs or an address bar. On load, the window gives keyboard focus to the writer without moving an already focused selection. It accepts navigation only to its own local origin.

The native titlebar sits above the WebView. Its double-click follows the Mac's Desktop & Dock preference. The app's standard Zoom frame fills the usable display between the menu bar and Dock; AppKit owns the zoom and restore behavior. New windows begin at 90% of that space, capped at 1700×1040 points. The exact former 1120×820 default is enlarged once; a custom saved frame is preserved. Subsequent sizing and placement use the same native frame autosave. Window → Zoom is also available, and fullscreen remains separate.

Fullscreen entry and exit update `html[data-native-fullscreen]` for the room's layout without creating another writing mode. The signal is refreshed after every complete document load. WebKit swipe-history gestures, pinch magnification, and link previews are disabled so they do not compete with Still's movement and type-size control. The shell supplies no custom pointer image and changes no system accessibility preferences.

The shell starts its own bundled backend at `127.0.0.1:4040`. This stable origin keeps WebKit's local recovery storage available across launches. The native WebKit profile is separate from a browser profile; unsent browser copies therefore remain in that browser. `STILL_NATIVE_PORT` can override the port for scratch tests. An occupied port is rejected rather than treated as Still. The availability check uses the backend’s address-reuse behavior, so a recently closed connection cannot be mistaken for a listening application during immediate reopening.
Each chosen collection has a distinct persistent WebKit profile, so a scratch collection cannot share draft recovery copies with the real collection. Quit Still before switching launch environments. For example: `open --env STILL_DATA_DIRECTORY=/private/tmp/still-native-room --env STILL_NATIVE_PORT=4041 dist/Still.app`.

Native launches opt into `STILL_NATIVE=true`; Docker's existing runtime behavior is unchanged. Erlang distribution is disabled. The shell locks `data/native/backend.lock` to avoid two native owners, rotates a local startup log, and creates or reuses `data/.secret_key_base`. Quit and New/Open/Find dispatch the editor-recovery flush event before leaving. File → Save dispatches a save event through that same recovery hook without leaving the editor. Quitting gives the save pause time to finish, then stops only the backend the shell started. If a new draft still lacks a server ID, a data-directory-specific local URL cursor reopens that fresh/beside writer next time; the writing itself stays in WebKit's recovery storage. A separate small guard also stops that BEAM if the window process crashes.

`python3 native/smoke.py` checks the packaged backend through the native controller using a disposable empty collection and an established collection populated with fabricated records, with Homebrew removed from PATH. Use `python3 native/smoke.py --bundle "dist/Still Preview.app"` to check the separate preview; the check reads its executable name from Info.plist. It also verifies immediate repeated launches after a server-closed connection, refusal of an occupied port, and that an abrupt parent exit closes the backend listener. It never reads a personal collection and does not open a window.

The Foundation-only location checks compile and run without opening a window:

```sh
swiftc -swift-version 5 -warnings-as-errors -parse-as-library native/WritingLocation.swift native/tests/WritingLocationTests.swift -o /tmp/still-location-tests
/tmp/still-location-tests
```

These check explicit overrides, legacy adoption, a renamed folder's bookmark, missing-folder refusal, and unchanged file contents. Actual native folder-picker, window, fullscreen, keyboard, and WebKit draft recovery should also be exercised in the app after a build. Backend smoke checks do not establish those visual and interaction behaviors.

Packaging follows [Elixir releases](https://hexdocs.pm/mix/Mix.Tasks.Release.html), which bundle the runtime for a matching target, and uses Apple's [WKWebView](https://developer.apple.com/documentation/webkit/wkwebview) and [deferred application termination](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)) APIs.
Native zoom uses [the standard frame delegate](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowwillusestandardframe(_:defaultframe:)); titlebar double-click choices remain under [Desktop & Dock](https://support.apple.com/en-gb/guide/mac-help/mchlp1119/mac).

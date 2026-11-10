# Ordinary text and notebook model

The ordinary-text storage model is implemented for new writing in the current
development checkout. Current words live in writer-selected local text files;
the machine-local SQLite database keeps stable identities, indexes, history,
notebook metadata, Places, icons and correspondence. This document records the
format rules, folder behavior and read-only pilot for prepared source files.

## Text and title meaning

The ordinary file contains **all current words**, including an explicit title.
Accept UTF-8 text with arbitrary filenames, with or without an extension. No
marker, sidecar, wrapper directory, or number is required. Preserve authored
line breaks, blank lines, indentation, trailing spaces, a final newline or its
absence, and a UTF-8 byte-order mark when present. Unsupported encodings and
binary documents require preparation outside Still; do not guess an encoding
or silently convert them. A `.gdoc` is a cloud document reference, not supplied
local text. There is no Google export or API workflow.

An ordinary file initially has **no explicit title line**. Saved writing uses its
existing filename as its display title (without the text extension, with underscores
shown as spaces and a separately recorded List number left in its own reference).
The filename label is searchable but never inserted into the poem. A page with no
usable filename, such as an unsaved draft, uses its first nonblank line as a temporary
label. Capitalization and separators in the body confer no title meaning.

The writer can explicitly mark a physical line as a title. The local database
records that role against the document identity and verified text. The selected
line remains in the file with its original whitespace and separator. The title
editor and body editor must partition and reassemble that same text without
duplicating the title or dropping any separators. Editing a title replaces only
the selected line. Removing its role leaves every word in the file.

For example, these bytes remain identical before and after marking line 2:

```text

  House sounds

	water: waiting:

```

Copy text returns the complete text once, whether the title is explicit or the
display label is automatic. It does not prepend the title line. The clipboard
receives text without the encoding byte-order mark. The existing editor's
separate title/body layout continues to copy an explicit title, a blank line,
and the body until that layout is replaced.

The database binds a title role to a physical line and the verified file
contents. An externally changed file requires review of that role; Still does
not guess that an identical phrase elsewhere has become its title. Saving
preserves earlier text in SQLite. A clearly established title in an original
archive document may be marked during its separately authorized conversion.
Ambiguous originals retain all text and no explicit title role.

## Linked poem passages

An optional own-line `[[poem: relative/path.txt | UUID]]` reference displays a
read-only passage from another ordinary file in the same selected root. The
identifier is authoritative when present; path-only references follow the path.
The source file remains the only editable copy of the included words. Moving
the whole collection retains relative paths and restored database identities;
without the database, path-only lookup is available for references without IDs,
and identified references require restoring/reconnecting their identities.
Still does not silently substitute a new file at an identified reference's old
path. Source refresh reads only linked files; missing/changed identities trigger
a reconciliation rather than guessing. No host text is rewritten by refresh.
Copy expands one level of available source words, while unavailable references
remain readable. Correspondence requires all linked sources and freezes expanded
submitted words and dependency tokens in its existing database records.

Markdown and PDF exports are separate snapshots under a sibling
`<collection name> Exports` folder, mirroring source directories and basenames.
They are outside the selected writing root, so they neither become notebooks
nor duplicate editable pieces. The source text keeps its references. Export
ownership and content hashes live in existing local database records; replacing
a generated copy requires its recorded bytes to remain unchanged. A PDF request
binds the saved source and linked-source snapshot and is checked again before
publication. Neither exported files nor their bytes replace earlier words or
submitted manuscripts in the database.

## Notebook and List metadata

Notebook and List numbering supplies sequence when writing dates are unknown.
Keep original labels, gaps, suffixes, series, and years. `0001`, `0003a`, and
`0003b` remain distinct labels in that order; there is no invented `0002`.
Two files with identical words remain distinct pieces. Import time, file
modification time, and title edits must never replace the writer's sequence.

Notebooks are ordinary folders with independent database records and can be empty. The current
notebook is an explicit choice: **Current Notebooks / 2026 / Notebook 1**.
Creating Notebook 2 neither renames Notebook 1 nor makes Notebook 2 current.
Optional descriptions of a physical notebook and pen remain lightweight.
Writing without a notebook is valid. A numbered archive layout is a useful
writer-selected convention, not a general file-access rule.

Adding a notebook creates its folder inside the selected writing root. Creating
a folder in Finder works too: folders containing writing and empty leaf folders
are discovered as notebooks. Grouping folders are retained. Subfolders inside
an already registered notebook are its sections. Explicit archive registration
can establish a physical notebook before its section folders are indexed.
Moving a file to another notebook folder changes its association on refresh;
reliable filesystem identity retains the piece's history and relationships.
New writing saved with a folder notebook selected goes into that folder.
Folder names and the storage provider are unrestricted.

## Persistence and feature integration

The selected local folder is the current-text authority regardless of its
storage provider. The local SQLite database lives outside that folder and
holds stable identities, relative locations, notebook/List metadata, title
roles, earlier words, search indexes, Places/icons, and correspondence. Indexed
text follows verified file contents. It is never a separately editable edition.

An unavailable root is an error, not an empty collection. Reconciliation must
separate missing files, intentional deletion, reliable moves, and ambiguous
matches. Equal words alone do not establish identity. Saving rejects stale
files and preserves the words being replaced. Interrupted saves need recovery
across the file/database boundary before they can be acknowledged as saved.

Write, Wander and notebook reading verify the selected folder once and share that verified
projection while choosing notebook neighbors, connections and echoes. This
operation-scoped snapshot ends with the navigation; it is not a timed cache.
The next navigation checks external edits and moves again. Saving always checks
the current file token independently, including during a reading snapshot.

Opening writing establishes a recovery-capable snapshot before reusing its file
projection. A read-only snapshot cannot stand in for pending-save recovery.

Correspondence reads revision counts in one grouped query, batches frozen
submission snapshots and cached place icons, and loads history and overlap from
the relevant correspondence records. It does not reopen every piece's earlier
versions to count them or rescan unrelated files for submission history. Cached
icons are reused without starting new download tasks on each tab visit. Frozen
submission bytes retain their digest, schema and lifecycle checks.

The existing behaviors map to that model as follows:

| Experience | Required source and behavior |
| --- | --- |
| Echoes | Verified current file text; preserve caret/selection sensitivity, exact source passages, restrained admission, and exclusion of the active work. Newly transcribed Lists can be candidates without being historical SQLite rows. |
| Threads | Verified passages and whole works from the same file identities; preserve stanza whitespace and Unicode word matching. A move cannot create another work or a false recurrence. |
| Notebook reading | Independent notebooks and preserved List sequence, including gaps and suffixes; no invented dates. |
| Reading place | Notebook and Find selections open a focused reader. SQLite remembers the last reader and each notebook's own place, including Find query, earlier-word version and result position. Wandering and the Now writing cursor cannot replace that place. |
| Search | Current file index plus database-held earlier words; refresh indexes after external changes, and expose unreadable/unavailable files. |
| Revisions | Earlier exact complete text and title roles in SQLite, including words replaced by Still and externally observed changes. |
| Correspondence | Places, icons, packets, replies, and exact submitted words in SQLite. Editing or moving a current file cannot rewrite a submitted manuscript. |
| Backup and restore | One latest verified SQLite backup beside the writing, safely replaced only when it belongs to the same collection; restore to a new local database file and explicitly reconnect the writing folder. No dated snapshot collection or per-piece revision folders. |

Archive preparation is separate from application file access. The upstream
`scripts/prepare_notebook_text.py` helper preflights local DOC, DOCX, ODT and
UTF-8 files before writing ordinary text. It preserves complete document text,
does not split or merge pieces, and blocks structures it cannot represent.
It reports ancillary ZIP/Finder files separately and leaves sources untouched.
Output collisions require an explicit choice; keeping source format in the
output names preserves both documents. No archive data belongs in the repository.

## Run the read-only pilot

From the source checkout after `mix deps.get`:

```sh
mix still.pilot --synthetic
mix still.pilot /absolute/path/to/prepared/local/text
```

The first command creates disposable synthetic files, checks exact title/editor
and copy behavior, reports supported and intentionally unsupported examples,
verifies that source bytes remain unchanged, and removes its files afterward.
It includes LF, CRLF, CR, mixed whitespace, a BOM, missing numbers, suffixes,
unassociated writing, an empty page, and an empty notebook folder.

The second command only reads the supplied folder recursively. It neither
starts the application nor opens its database. It reports every file and empty
folder, including unsupported input and symlinks. Unsupported files cause a
nonzero exit status so they cannot disappear silently. No personal writing is
included in the source repository or its test fixtures.

# Correspondence

Correspondence is a second room within Still for file-backed writing, destinations,
packet preparation, and the history of submissions. It does not send anything.
Historical Lists remain in SQLite and never become submission candidates.

## Everyday use

Open **Correspondence** from the main navigation. The room opens dark; its optional
light appearance stays within this room until you leave it and does not change Now. Choose the same collection folder in
**Storage & Backups** that holds your saved writing. Without an available folder,
Correspondence explains what is missing and stores no authoritative records elsewhere.

Pages begin with compact labels and actions rather than introductory banners.
**On the desk** keeps a work you explicitly choose in view. Use **Place on desk**
in **Works**, or the home page's saved-work chooser. Change it there or **Clear the desk**;
clearing removes only the placement, never the writing. The selection survives a restart
and follows the collection. A recent edit does not imply readiness for publication.

**Works** holds the pieces you mark for Correspondence. Open a saved piece in
Write or in its notebook and choose **Mark for Correspondence**. This adds the
piece to Works in its existing location. Pieces already in packets start
marked. You can remove the mark while keeping the packet history.

**Edit in Write** opens the same piece from Correspondence. After a submission,
the editor notes that the piece has been sent. Saving an edit creates a new
version, and the packet keeps the exact submitted words.

Works shows 40 pieces initially. **More works** reveals the next group and
search covers all marked pieces.
Opening a work places its current text beside earlier versions and correspondence,
including the exact versions sent. Use **Edit in Now** to compose or revise.
Correspondence does not have a second editor; global **Write** remains the way back.

Home shows up to three outstanding submissions, including unresolved pieces in a
partly accepted packet, and two recent replies. **All packets** leads to the complete
history. **Places to consider** shows up to three places you have shortlisted, your
notes and previous correspondence. Shortlist controls in Places and on home change
only that personal marker. Home shows recorded windows and policies only when you
have marked the source checked; this is your record, not live confirmation of availability.

**Places** keeps a compact shortlist above the complete directory. Open a place to
read its notes, requirements, and linked packets and pieces. **Edit place details**
opens the manual record; **Prepare a packet** starts with that saved destination selected.
The dark palette uses charcoal and grey with restrained blue highlights; **Light** changes this room
only, and the next visit starts dark again.

Packet preparation separates the saved-writing chooser, ordered manuscript, and
destination. The chooser can be searched and scrolled with the keyboard. Reordering
updates the on-screen manuscript; save before exporting or recording a submission.
Sent packets show their preserved texts by default, with optional folding for each piece.
On smaller windows the columns stack in reading order rather than compressing the text.

Keep a journal's website and actual submission address separately. Record current
guidelines, reading windows, fees, simultaneous-submission policy, and response
expectations yourself. An unknown field means unknown. Personal notes remain separate
from the information you have checked. Still does not fetch or invent journal policies.

Choose saved writing, arrange it in a packet, and select a destination. Review the
requirements and any other outstanding submissions. Save preparation notes and a
cover-letter draft. Manuscript downloads are available in DOCX and UTF-8 plain text.
They contain the ordered writing; the cover letter remains available separately in
the packet for copying and review. Check the destination's formatting requirements.

Submit yourself through the destination's website. Only then use **Mark sent** to
record the date and preserve the submitted text. Still cannot verify an external
submission. If a piece changed since packet preparation, review and save the packet
again before marking it sent. This deliberately refuses to substitute new words for
the version you reviewed.

Save journal and packet forms before leaving their page; unsaved preparation fields
are not part of Now's editor recovery.

A sent packet's manuscript is frozen. Reading it or downloading it later uses that
snapshot, even after the original is revised or moved to Trash. Record a reply in the
packet and select which pieces were accepted. Review other outstanding submissions
when work is accepted; Still never withdraws or contacts anyone automatically.
Prepare a new packet for a subsequent submission so the earlier history remains intact.

## Storage and recovery

Correspondence records live in the local SQLite database beside the selected writing folder. The folder itself contains the current ordinary text files and, after a backup, one latest verified `still-backup.sqlite3` copy. The database stores scoped place and packet records, desk placement, earlier record revisions, discovery details, icon bytes, and immutable submitted manuscripts. No Correspondence folders, JSON sidecars, icon files, or per-piece revision directories are created beside the writing.

Each selected folder has a stable collection identity in the local database. Still stores file locations relative to that folder and keeps the active words in those files. Opening or searching synchronizes readable UTF-8 files into SQLite indexes; the index is not a second editable copy. A file without an extension is valid. Binary or unsupported text is reported and left untouched. If the selected folder becomes unavailable, Still reports that instead of treating the writing as deleted or switching to another collection.

A packet records the selected piece identities and their current file tokens. **Mark sent** saves the exact full text of every piece into an immutable SQLite snapshot, including the explicit title line when one is part of the file. The snapshot also keeps title-role metadata and the destination name as it was when sent. Later edits, file moves, place renames, or Trash do not change that submitted version. Manuscript exports use this same full text and do not prepend a second title. DOCX and UTF-8 plain-text downloads contain the ordered writing; the cover letter remains separate.

Place details, shortlist choices, packet events, and desk placement are stored as scoped SQLite records. Stale form tokens prevent an older window from replacing a newer record. Each successful edit preserves the prior record revision in SQLite. A saved desk placement has the same stale-edit protection; clearing it removes only the placement, while its prior state remains in revision history.

Icons are optional. Still fetches only public HTTP(S) sources, checks redirects, and accepts bounded raster images. The image bytes, MIME type, source hash, and retry time are stored in SQLite. Changing the place's icon or website uses a different cache entry. A collection folder copy by itself does not carry this cache; a verified database backup does.

The exact submitted words and other correspondence history are included in the latest SQLite backup made with **Back Up Now**. The backup sits beside the writing and is safely replaced after verification; it is not a dated snapshot series. Current writing remains in the ordinary text files, so keep the selected folder available to Still and allow any folder synchronization service to finish. A successful local save does not prove that an external service has synchronized it.

When a save is interrupted, Still uses the pending record in SQLite to compare the file with the earlier and proposed words. A verified partial staging file can be cleaned up and the save completed. If the file contains a third version or an unfamiliar staging file is present, Still leaves that content and the pending record in place and reports the conflict. Reopen **Saved writing** to review the current file and proposed text, then choose which words to keep. Do not remove unfamiliar files in the writing folder while resolving a save.

Moving a file within the selected folder can retain its identity when the file match is reliable. If a copy-and-delete leaves more than one possible match, Still shows the ambiguity and lets you explicitly reconnect the existing writing or adopt a separate file. Equal text alone never merges two writings. Files in Trash retain their earlier words and relationships in SQLite; restoring to an occupied path is refused until you resolve that path yourself.

## Synthetic preview

From a development checkout with dependencies already set up:

```sh
./scripts/preview_correspondence.sh
```

This creates a new disposable synthetic database, settings directory, and collection
under the system temporary directory, then opens a localhost server at port 4096.
Visit `http://localhost:4096/correspondence`. Use `STILL_PREVIEW_PORT=4097` if needed.
Choose `STILL_PREVIEW_SCENARIO=empty`, `small` (the default), or `established`
to inspect an empty, five-piece, or twelve-piece synthetic collection. For example:

```sh
STILL_PREVIEW_PORT=4097 STILL_PREVIEW_SCENARIO=established ./scripts/preview_correspondence.sh
```

The script prints its exact temporary directory. It refuses to seed a pre-existing
collection and does not use the installed application's database or profile. Stop
with Control-C. Each launch creates a fresh preview; its printed directory contains the synthetic text files,
local database, and settings for inspection until you remove it. These examples are invented and
are not evidence of any real journal's policy or availability.

## Deliberate boundaries

There is no external directory, policy verification service, sending integration,
scheduler, hosted database, new writing classification, or cloud sync engine.
DOCX is a readable manuscript, not a claim to meet every journal's requirements.
Its layout is a readable manuscript rendering; the frozen UTF-8 text remains the
source of exact wording and line-ending fidelity. PDF can be produced by opening a DOCX and exporting
or printing it in a word processor; Still does not require a PDF conversion service.

## Importing and deactivating places

Next to **Add a place**, choose **Import Places**. Share the JSON example on that
page (or `docs/places-import-example.json`) with Cal. Upload one UTF-8 `.json`
array containing 1–200 places, at most 1 MB. Only `name` is required; all other
fields in the example are optional. Text must be strings; unknown details may be
omitted or empty. `shortlisted` is a boolean. `simultaneous_policy`, when supplied,
is `unknown`, `allowed`, or `not_allowed`. Web addresses must use HTTP or HTTPS.
Unknown fields are rejected so misspellings cannot silently discard information.

**Review places** validates the whole file without changing the collection.
**Import N places** then adds the previewed new names. Existing names, including
inactive places, and repeated names in the file are skipped (ignoring case and
outer whitespace). Import never edits an existing place or reactivates it. Imported
information starts unverified; check a publication's current source before submitting.
Nothing is fetched from the web and no submission is sent.

If saving fails partway through, Still reports the number actually added and the
failure. Completed additions remain intact; reviewing the file again skips those
names, making retries safe. The preview stays bound to the collection in which
it was reviewed: a missing or changed folder is an error, never a fallback.

Open a place and choose **Deactivate place** to remove it from the active directory,
home shortlist, and new packet choices. Its identity, notes, revisions, submitted
manuscripts, replies, and links remain intact. Find it under **Inactive places**
and choose **Reactivate place** to use it again. Preparing or sending a packet to
an inactive place requires reactivation; recording responses to existing submissions
continues normally. Editing details or importing the same name never implicitly
reactivates it. Old place records without the optional `inactive` flag remain active;
reading them causes no migration or rewrite.

## Bringing a historical List into saved writing

While reading the current words of a historical List (including one opened through
Find or Wander), choose **Add to saved writing**. Still saves its exact text in the
configured file collection and opens the usual Now editor. Change the optional
title there to the display title you want, then save. The historical List, its
notebook provenance, and SQLite revisions stay unchanged. This is an explicit
editable edition for your saved collection and packet preparation, not a migration.

The saved version has a stable ID derived from the importer's preserved source key.
Using the action again opens that same version, preserving subsequent title and
text edits rather than copying the historical words over them. The link survives
folder/title changes and a restored SQLite database. A saved version in Trash must
be restored instead of duplicated. Files created separately by hand are not matched
by their title or text; Still does not guess that two different pieces are the same.

The local database retains the historical title, notebook, source number when known,
and source key under `historical_source`; absolute import paths are excluded. The source
reference is also visible under **Text file** when reading saved writing. The current
words remain in the ordinary UTF-8 text file, and the provenance stays in SQLite as you
revise it. No two-way synchronization with the historical original is implied.

## Then & now

Open a work and choose **Then & now**, or use **Compare with current words** beside
one of its sent copies or earlier saves. The earlier manuscript and current saved
page appear together. **Look back to** moves between the exact versions sent to
places and the work’s earlier saved versions. Destination names and sent dates come
from the frozen packet, even if a place is renamed later.

**What changed** shades changed passages and identifies a changed title role. A title
selected from a line is metadata pointing into the complete text; it does not replace
or duplicate that line. **Just read** removes the shading so both complete pages can
be read quietly. Earlier saves and sent copies come from SQLite revision and snapshot
records. Line breaks, indentation, blank stanzas, tabs, and trailing spaces remain in
their own versions. Spacing-only and line-ending-only changes are identified explicitly.
Very long versions appear as complete pages without detailed passage markings.

The comparison does not merge, restore, save, export, or send a manuscript. Continue
editing through **Continue in Now**, or open the recorded correspondence from a sent
copy. A missing or unrelated version is reported instead of being substituted.
There are no new collection formats or migrations.

The separate Docker preview also includes **What the rain leaves**, an invented
work with two sent copies and two earlier saves. Run `./scripts/preview_threads.sh`
and open it from **Correspondence → Works → Then & now**. Existing preview pages
and desk choices are preserved. The same `remove` command removes the entire preview.

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
The home page brings an available manuscript beside active submissions and recent
replies. **Writing** is the searchable collection; opening a piece places its current
text beside its earlier versions and correspondence, including the exact versions sent.
Use **Return to Now to revise** for writing. Correspondence does not have a second editor.

**Places** keeps a compact shortlist above the complete directory. Open a place to
read its notes, requirements, and linked packets and pieces. **Edit place details**
opens the manual record; **Prepare a packet** starts with that saved destination selected.
The dark palette uses blue-grey paper and slate panels; **Light** changes this room
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

Records live beneath `correspondence/` in the selected collection, beside `poems/`.
The collection's machine-specific absolute path lives only in local Still settings.
Relationships use stable UUIDs, not writing folder labels or absolute paths.

The format marker is `.still-correspondence.json` (`still-correspondence-v1`). Journal
records live in `journals/<id>.json`; packet records in `packets/<id>.json`. Snapshot
records live in `snapshots/<snapshot-id>.json`; exact UTF-8 manuscript copies and a
manifest live in `snapshots/<snapshot-id>/<piece-id>.txt` and `snapshot.json`. Earlier
journal and packet JSON lives in `revisions/<record-id>/<content-hash>.json`. JSON is UTF-8 and
can be inspected with ordinary tools. Record tokens detect external edits, and sent
snapshots carry content hashes. Keep the whole directory together when copying it.

Still writes through temporary files, syncs them, and publishes completed records
atomically. Earlier JSON is retained before updates. A collection lock prevents two
Still instances from updating correspondence records together. External editors and
folder synchronization services do not honor Still's lock: avoid editing records in
another program while saving them in Still. A detected mismatch is an error, never
permission to overwrite. Reopen and reconcile outside changes first.

A missing, malformed, or partially synchronized record produces an explicit error.
Reconnect the selected folder or let synchronization finish, then reopen the room.
Still does not silently reconstruct missing established directories or replace a
broken record with an empty one. A lock left after a crash is not silently removed;
close every Still instance and preserve a copy of the collection before inspecting
and removing a stale `correspondence/.still-correspondence-lock` directory.

**Back Up Now snapshots SQLite only.** It does not back up writing files,
correspondence, or browser drafts. Preserve the entire collection folder separately,
including snapshots and earlier records. A successful local save does not prove that
Google Drive or any other external service has synchronized it.

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
with Control-C. Each launch creates a fresh preview; retain its printed directory if
you want to inspect the portable files afterward. These examples are invented and
are not evidence of any real journal's policy or availability.

## Deliberate boundaries

There is no external directory, policy verification service, sending integration,
scheduler, hosted database, new writing classification, or cloud sync engine.
DOCX is a readable manuscript, not a claim to meet every journal's requirements.
Its line breaks represent original line endings; the frozen UTF-8 text remains the
source of exact byte fidelity. PDF can be produced by opening a DOCX and exporting
or printing it in a word processor; Still does not require a PDF conversion service.

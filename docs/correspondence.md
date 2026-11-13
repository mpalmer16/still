# Correspondence

Correspondence is a second room within Still for file-backed writing, destinations,
packet preparation, and the history of submissions. It does not send anything.
Historical Lists remain in SQLite and never become submission candidates.

## Everyday use

Open **Correspondence** from Still's navigation. It has its own Home, Works,
Places, and Packets navigation, with **Back to Still** returning to writing. The
sun/moon menu holds the light appearance and remembered dark color choices:
Graphite, Night blue, Forest, or Plum. These affect Correspondence only.
Choose the collection folder in **Storage & Backups** that holds your saved writing.
Without an available folder, Correspondence explains what is missing and stores
no authoritative records elsewhere.

Home follows packets: continue preparations, see the submissions awaiting replies,
and revisit recent responses. Collection counts lead to the full directories.
It does not select a single work as the focus of the room.

**Works** holds the pieces you mark for Correspondence. Open a saved piece in
Write or in its notebook and choose **Mark for Correspondence**. This adds the
piece to Works in its existing location. Pieces already in packets start
marked. You can remove the mark while keeping the packet history.

**Edit in Write** opens the same piece from Correspondence. After a submission,
the editor notes that the piece has been sent. Saving an edit creates a new
version, and the packet keeps the exact submitted words.

**Works**, **Places**, and **Packets** use the same compact table layout, with
search beside a **Filters** menu. Each shows 40 rows per page, and searching or
filtering covers the entire list. Works can be filtered by notebook and packet
status, and sorted by notebook sequence, title, or packet activity. It shows
participation across packets, so a newer preparation or rejection cannot hide
an existing submission or acceptance. Open a work for its current text,
earlier versions, and exact sent copies.

Packets can be searched by title, destination, or their contents, filtered by
status and whether a destination is chosen, and sorted by activity, title,
destination, or sent date. Sent packet contents and destination names come from
the historical record. **Prepare a packet** can begin before any place is chosen.

**Places** is a single searchable table. Search names, keywords, descriptions, guidelines,
and your notes. Combine filters for active or inactive places, kept nearby, reach,
simultaneous-submission policy, and submission history. Click the Place, Reach,
Submission window, or History heading to sort; click again to reverse it. Windows
remain the text you recorded, without guessing whether a place is open. History uses
the date you marked a packet sent, with unknown dates kept last.

The table shows 40 places per page. Search and filters cover the full directory;
opening a place and returning to **All places** keeps your view. **Reset** clears
the search, filters, sorting, and page. Keep nearby is a personal marker in the same
table. **Places menu** holds Add a place and Import Places. Open a place to read its complete notes,
requirements, and linked packets and pieces. **Edit place details**
opens the manual record; **Prepare a packet** starts with that saved destination selected.
Packet preparation separates the saved-writing chooser, ordered manuscript, and
destination. The chooser can be searched and scrolled with the keyboard. Reordering
updates the on-screen manuscript; save before exporting or recording a submission.
Sent packets show their preserved texts by default, with optional folding for each piece.
On smaller windows the columns stack in reading order rather than compressing the text.

Keep a journal's website and actual submission address separately. Record current
guidelines, reading windows, fees, simultaneous-submission policy, and response
expectations yourself. An unknown field means unknown. Personal notes remain separate
from the information you have checked. Still does not fetch or invent journal policies.

Choose saved writing and arrange it in a packet. Save and revise the draft before
choosing a destination. **Edit** beneath a manuscript saves the packet arrangement
and opens the original file in the writing editor; **Save & return to packet**
brings you back. Review and save the packet again after changing a source. The
poems remain in their original notebooks; the packet holds ordered links to them.

Choose a destination when ready. Review the
requirements and any other outstanding submissions. Keep private submission notes and a
cover-letter draft. Use **Choose saved writing…** to attach a scratch page or any
other saved writing as the cover letter. It does not need a Correspondence mark
and is not added to the poems. The linked letter follows its source until sending;
changing it requires reviewing and saving the packet again. Alternatively, write
an inline letter draft in the packet. The copy button copies the linked or sent
letter for pasting into the submission form.

**Save as PDF** in the Mac app creates a clean manuscript with each
poem beginning on a new page, using the same verified text as the preview. PDFs are
saved under `<collection> Exports/Packets`, beside the writing folder and outside its
notebooks. Unrelated or externally changed exports are left untouched. Manuscript
downloads are also available in DOCX and UTF-8 plain text.
They contain the ordered writing; submission notes and the cover letter stay separately in
the packet for copying and review. Check the destination's formatting requirements.

Submit yourself through the destination's website. Only then use **Mark sent** to
record the date and preserve the submitted text. Still cannot verify an external
submission. If a piece changed since packet preparation, review and save the packet
again before marking it sent. This deliberately refuses to substitute new words for
the version you reviewed.

Save journal and packet forms before leaving their page; unsaved preparation fields
are not part of Now's editor recovery. Once the packet is saved, its larger
**Submission notes** area can be edited before and after sending. Use **Save notes**;
unsaved notes are held in this browser or Mac profile for explicit recovery when
you return. Saving notes does not change the packet manuscript or its reviewed
state. Stale saves are refused, and earlier saved notes remain in SQLite revisions.

A sent packet's manuscript is frozen. Reading it or downloading it later uses that
snapshot, even after the original is revised or moved to Trash. Record a reply in the
packet and select which pieces were accepted. Review other outstanding submissions
when work is accepted; Still never withdraws or contacts anyone automatically.
Use **Duplicate packet** to make a new preparation with the same ordered pieces,
cover-letter choice, and latest saved private notes. It starts without a destination
or send history. Choose another place and revise it freely; the original packet,
reply, and exact sent text remain intact. A duplicate uses current source writing,
so review it before sending again.

## Storage and recovery

Correspondence records live in the machine-local SQLite database outside the selected writing folder. The folder itself contains the current ordinary text files and, after a backup, one latest verified `still-backup.sqlite3` copy. The database stores scoped place and packet records, earlier record revisions, discovery details, icon bytes, and immutable submitted manuscripts. No Correspondence folders, JSON sidecars, icon files, or per-piece revision directories are created beside the writing.

Each selected folder has a stable collection identity in the local database. Still stores file locations relative to that folder and keeps the active words in those files. Opening or searching synchronizes readable UTF-8 files into SQLite indexes; the index is not a second editable copy. A file without an extension is valid. Binary or unsupported text is reported and left untouched. If the selected folder becomes unavailable, Still reports that instead of treating the writing as deleted or switching to another collection.

A packet records the selected piece identities and their current file tokens. **Mark sent** saves the exact full text of every piece into an immutable SQLite snapshot, including the explicit title line when one is part of the file. The snapshot also keeps title-role metadata and the destination name as it was when sent. Later edits, file moves, place renames, or Trash do not change that submitted version. Manuscript exports use this same full text and do not prepend a second title. PDF, DOCX and UTF-8 plain-text exports contain the ordered writing; the cover letter remains separate.

Place details, kept-nearby choices, and packet events are stored as scoped SQLite records. Stale form tokens prevent an older window from replacing a newer record. Each successful edit preserves the prior record revision in SQLite.

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
source of exact wording and line-ending fidelity. The Mac app creates packet PDFs
locally; Still does not require a PDF conversion service.

## Importing and deactivating places

In **Places menu**, choose **Import Places**. Share the JSON example on that
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
and new packet choices. Its identity, notes, revisions, submitted
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

Use the disposable Correspondence preview described above to check this workflow;
it leaves the installed app and personal collection untouched.

## Calendar event import

The Calendar can accept a local JSON event list. Use the field guide on its import page
and `docs/calendar-import.schema.json` (JSON Schema draft 2020-12). The file is an array of up to 200 events
and at most 1 MB. Each event requires `external_id`, `title`, and `date` in
YYYY-MM-DD form. Optional times use 24-hour HH:MM. An omitted time means the time
is unconfirmed; it does not claim the event is all day. Optional `end_date` is
inclusive and must be on or after `date`. Other optional fields are `timezone`
(a display label), `venue`, `address`, `url`, `notes`, `category`, and `status`.
Category is `reading`, `workshop`, `deadline`, or `other`; status is `scheduled`
or `cancelled`. Web links must use HTTP or HTTPS. Unknown fields and duplicate
external IDs in one file are errors.

An event may also include `recurrence`, or omit it or set it to `null` for a
one-time event. A recurrence object has `frequency` (`daily`, `weekly`, `monthly`,
or `yearly`), optional `interval`, optional inclusive `until` date, and optional
`excluded_dates` array. Monthly rules may include `weekday` and `week_of_month`
to describe a pattern such as the second Thursday or `-1` for the last occurrence
in a month. When a monthly pattern is supplied, the event's anchor date must
match it. The schema lists all accepted keys and value limits. The runtime also
checks relationships between fields, including that an end time has a start time
and that an event does not span more than 366 days.

**Review events** checks the complete file and shows the proposed new events,
changed events beside their previous values, and unchanged events that will be
skipped. Empty values in a proposed update are shown as **Not set**, including
when an optional field will be cleared. Reusing an `external_id` identifies the
same event for an update; it never creates a duplicate. Confirming the preview
commits all proposed additions and updates together. Event details are stored
locally. Still does not fetch the listed links, contact venues, or send event
information elsewhere.


Switch between **Calendar** and **List**. The month grid opens an agenda for a
selected date; **All upcoming dates** returns to the coming-up list. **Add event**
opens a local event form. **Edit** changes the saved event or recurring series.
The event directory shows one row per series, with its next visible occurrence,
and supports search, upcoming/all events, and 40-row pages. Recurring dates are
calculated for the selected month and the next twelve months; one-time future
events remain available in the list beyond that horizon.

Use **Hide event** for a one-time event, **Hide this date** for one occurrence,
or **Hide series** for all repeats. **Include hidden** exposes the matching restore
actions. These choices survive later curated imports. They never change the
source list or delete event history. Cancelled events have a separate visibility
filter. Repeats preserve their advertised local clock times; the time-zone field
is a display label, and Still does not convert times between zones. Monthly dates
that do not exist and non-leap-year February 29 repeats are skipped without drifting.

Correspondence uses the available window width with a small margin. Calendar weeks
run Sunday through Saturday. Its compact toolbar brings together the view switch,
month navigation, Today and search. **Calendar menu** contains Add event, Import
calendar events, visibility filters and the list's date-range choice. The month
and event list fill the available window height; the event list scrolls beneath
its separate heading.
Home shows the next four visible event dates, including recurring dates and
events already in progress, beside packet activity on wide screens. Hidden and
cancelled events stay out of this summary. Open an event title to see its date
in Calendar, or use the Calendar link for the complete view.

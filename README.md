![Still — a page, and some company](docs/images/still-room.svg)

Still is a private, local place to write in the company of old writing.
A poem, a list, a fragment. A title if you want one. Room to begin again.

[Writing & care](docs/guide.md) · [Correspondence](docs/correspondence.md) · [The Mac app](native/NOTES.md)

<br>

### Begin with Write

**Write** starts a new page after saved work. If you have unsaved words, it returns
to that unfinished page instead. As you write, the controls fall quiet. Your line breaks,
indentation, and spaces stay yours. Save keeps your words as ordinary text files,
with earlier versions to return to.

**Insert poem…** brings another saved poem into the page as a live, read-only
passage. Its original file keeps the words; the surrounding text file keeps a
readable reference. Copy includes the displayed poem.

Menu also lets you rename the current file and export its full words as Markdown
or PDF. Exported copies stay in a separate folder beside the writing collection.

Correspondence packets keep an ordered selection of saved poems. Assemble and revise
a packet before choosing its destination. Edit a piece and save back to its packet;
attach a saved scratch page as a linked cover letter without marking it for Correspondence.
The manuscript preview expands inserted poems. Save the reviewed packet before exporting
or marking it sent; changes to its source writing require another review. **Save as PDF**
in the Mac app creates a clean manuscript with each poem beginning on a new page, under
`<collection> Exports/Packets`. Plain text and DOCX downloads remain available. Cover
letters and private submission notes are excluded from manuscript exports. Marking a
packet sent preserves its exact words; later writing changes do not alter that copy.
Submission notes remain editable after sending, with stale-edit protection and earlier
saved words retained locally. Use **Save notes** to keep them; unsaved notes have a local
recovery copy in the same browser or Mac profile. **Keep nearby** is a personal marker
for publications you want to return to in Places. Home follows preparations,
outstanding submissions, and recent responses. Works, Places, and Packets share searchable,
filterable tables. Duplicate a packet for another destination while retaining the original send.

### Let the past come near

Echoes gather at the edges when your language meets words you have written before.
They listen near the caret, or beside a word you select. Lean toward one and a
little more of its original passage unfolds.

While wandering or reading a saved page, pause over a passage or select its text
to draw echoes from that passage.
Sometimes the page stays quiet.

### Read a notebook

**Notebooks** opens each notebook with its index beside the words. Move through
its pages in order, return to your reading place, or choose **Wander with this**.
**Find** opens the piece in its notebook and keeps the route back to your search results.
**Edit** keeps the notebook index beside the shared writing editor. **Save** keeps
you editing; **Save & return to notebook** (or Command/Control+Enter) returns to
that piece's notebook page, with echoes and your search context intact. New pages
still begin in Write.
New Lists take the next number in the selected notebook and include it in the
filename, counting across all its sections. Collections such as Poems can turn
off automatic numbering when they are added.

For a transcription whose place in the physical notebook is still unknown,
choose **New unplaced List** in that notebook, or **Save to Unplaced** in the
writing Menu. It stays in that notebook's collapsible **Unplaced** section as an
ordinary title-only text file, without consuming a number. This is separate from
Scratch, which holds writing outside the notebook sequence. Leave a piece
Unplaced for as long as you like.

In the saved piece's writing Menu, **Place in notebook…** previews a section and
an editable List number. Gaps, suffixes such as `55a`, and corrections are allowed.
Other pieces keep their numbers. If a number is already used, review the existing
pieces and explicitly allow it or choose another. An occupied filename is never
overwritten. Placement moves the same file and retains its identity, earlier
words, poem links, and correspondence records; you can also return it to Unplaced.
Hover over a notebook title, or focus it with the keyboard, for **Read**,
**Wander**, and **Delete**. **Delete** asks for confirmation before permanently
removing that List's local text file and saved earlier words. Submitted
correspondence retains its exact submitted text.

### Make room for what comes next

**Correspondence** holds the life around the work: places to consider, manuscripts
to arrange, submissions to remember, replies to keep. **Then & now** places an
earlier or submitted version beside today's words, so you can see what changed.
Places can suggest saved pieces through shared keywords, keep your own possible
connections, and record your sense of reach with a note. Each place can have a
short description and an automatically saved website icon or logo.

You decide when the work leaves the room. Still keeps the exact words you sent.

<br>

---

### Yours to keep

Still runs on your computer. No account, cloud API, or analytics.
Echoes follow shared words in your own writing. They offer company, without
inventing an interpretation.

Current new writing lives in ordinary text files. Stable identities, indexes,
revisions, notebook metadata, Places and correspondence live in the local
database alongside historical notebooks and Lists. Earlier words, recovery
copies, Trash and one verified database backup each have their place. The
[guide](docs/guide.md) explains how to care for both the text folder and database.

The [ordinary-text storage model](docs/storage-model.md) describes current new
writing: ordinary local text files, with history and collection records in the
machine-local database. Archive preparation remains separate from ordinary file access.

### Come in

On a Mac, build the app with Elixir/Erlang, Xcode command-line tools, and Python 3:

```sh
./native/build.sh
open dist/Still.app
```

The built app runs on its own. [Native notes](native/NOTES.md) cover installation
and the remembered writing folder.

For local development:

```sh
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000). For Docker, isolated previews,
storage, recovery, and checks, see [Using Still](docs/guide.md).

<br>

*For the words you are writing, and the ones that stayed.*

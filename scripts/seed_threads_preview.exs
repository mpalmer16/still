# Invented writing for the isolated Docker preview only. Never a host collection.
alias Still.{Desk, Poems, Repo, Storage, Writing}
alias Still.Writing.Entry

true = System.get_env("STILL_THREADS_PREVIEW") == "true"
true = Path.expand(Repo.config()[:database]) == "/app/data/still.db"
true = System.get_env("STILL_LOCAL_STATE_DIRECTORY") == "/app/data/local-state"
root = "/app/data/collection"
marker = "/app/data/.threads-preview-seeded"

if File.exists?(marker) do
  IO.puts("The separate preview is already prepared; your preview edits were kept.")
else
  # Refuse an established volume, even when someone has removed the seed marker.
  false = File.exists?(root)
  0 = Repo.aggregate(Entry, :count)
  false = File.exists?("/app/data/local-state")
  File.mkdir!(root)
  {:ok, _} = Storage.set_folder(root)
  location = Storage.collection_location()

  historical = [
    {"Early Notebooks / The small hours", "Window:Rain:",
     "The window learns the rain by heart.\nEach drop a small rehearsal\nfor the river.\n\nI leave the lamp on\nfor the room I have not entered.\n"},
    {"Early Notebooks / The small hours", "Orchard:Return:",
     "In the orchard, a ladder\nleans against the afternoon.\n\nWhat we meant by return:\nnot the same door,\nbut the same light beneath it.\n"},
    {"Early Notebooks / The small hours", "River:Letter:",
     "I fold the letter twice.\nThe river takes its time\nwith everything I cannot send.\n\nBeyond the bridge\na window holds the last of the light.\n"},
    {"Early Notebooks / The small hours", "Kitchen:Rain:",
     "The rain has brought us\nback into the kitchen.\n\nA cup with a blue rim.\nA lamp we never thought to mend.\n"},
    {"Notebooks / A borrowed room", "Light:Dust:",
     "The light moves slowly\nacross the table.\n\nEven the dust\nhas somewhere to be.\n"},
    {"Notebooks / A borrowed room", "Window:House:",
     "At the window of the empty house\na curtain continues\nto practice being wind.\n\nI am learning\nwhat a room remembers.\n"},
    {"Notebooks / A borrowed room", "Letter:Door:",
     "There is a letter\nunder the door.\n\nI know the handwriting\nbefore I know the words.\nOutside, the rain\nhas changed its mind.\n"},
    {"Notebooks / A borrowed room", "Hands:Water:",
     "Hands in the water.\nWater in the hands.\n\nThe river has no word\nfor keeping.\n"},
    {"Later Notebooks / Along the water", "Orchard:Hands:",
     "In the orchard\nmy father's hands\nare still full of weather.\n\nThe ladder waits\nwhere he left it.\n"},
    {"Later Notebooks / Along the water", "Bridge:Quiet:",
     "Under the bridge\nthe river keeps the sky\nin pieces.\n\nI carry one home\nin the quiet of my coat.\n"},
    {"Later Notebooks / Along the water", "Morning:Window:",
     "Morning comes to the window\nwithout an explanation.\n\nOn the table, yesterday's letter.\nIn the garden, the rain.\n"},
    {"Later Notebooks / Along the water", "Table:Room:",
     "A table, a lamp,\na room enough for listening.\n\nThe light has finished\nwhat the morning started.\n"}
  ]

  Enum.with_index(historical, 1)
  |> Enum.each(fn {{notebook, title, body}, index} ->
    Repo.insert!(Entry.changeset(%Entry{}, %{
      origin: "before", title: title, body: body, notebook: notebook,
      source_key: "threads-preview:#{index}", source_group: "threads-preview-page:#{index}",
      source_order: index * 100, source: %{"provenance" => "Invented preview writing"}
    }))
  end)

  saved = [
    {"What the window keeps",
     "The window is a way\nof being here\nand somewhere else.\n\nTonight the rain writes slowly.\nI let it finish.\n"},
    {"A ladder in August",
     "By August the ladder\nhad become part of the tree,\na second trunk leaning\ntoward the house.\n\nIn the orchard,\nno one calls this absence.\n"},
    {"The long way home",
     "The river keeps no copies.\nIt gives the bridge\nback to itself\neach morning.\n\nI take the long way home.\n"},
    {"Letter without an address",
     "Dear whoever is still there,\n\nI have kept the light\nabove the kitchen door.\n\nThe letter ends here.\nThe room does not.\n"},
    {"Small weather",
     "The rain keeps one light on\nin every window it passes.\n\n  I count them from the bus.\n"},
    {"A place for the quiet",
     "Set the lamp on the table.\nLeave the door a little open.\n\nThe quiet will find\nits own way in.\n"},
    {nil,
     "My hands remember the water\nlonger than the water remembers me.\n\nI put the cup away.\n"},
    {"The unfinished room",
     "The window learns the rain by heart.\n\nI thought the room was empty\nuntil the light moved.\n"}
  ]

  pieces = Enum.map(saved, fn {title, body} ->
    {:ok, piece} = Poems.save(location, Poems.new(location), %{title: title, body: body})
    piece
  end)

  # Keep a realistic earlier version on one sample page.
  first = hd(pieces)
  {:ok, first} = Poems.save(location, first, %{
    title: first.title, body: first.body <> "\nEven the dark has an outside.\n"
  })
  :ok = Desk.remember(location, %{id: first.id, saved: true, beside: nil})
  {:ok, _} = Writing.set_room_light(82)
  File.write!(marker, "Invented preview writing; safe to remove with preview_threads.sh remove.\n")
  IO.puts("Prepared a separate collection of invented notebooks and pages.")
end

# Add a new invented work for Then & now. Existing preview works and choices stay intact.
proof_marker = "/app/data/.proof-preview-seeded.json"

if File.exists?(proof_marker) do
  proof_demo = proof_marker |> File.read!() |> Jason.decode!()
  if !is_binary(proof_demo["piece_id"]), do: raise("The disposable preview setup was interrupted. Remove only this preview and start it again.")
  IO.puts("Then & now: /correspondence/writing/#{proof_demo["piece_id"]}?compare=latest")
else
  File.write!(proof_marker, "{\"preparing\":true}\n")
  location = Storage.collection_location()
  true = location.folder == root

  {:ok, first_place} = Still.Correspondence.save_journal(location, %{
    name: "North Window (preview)", website: "https://example.com",
    notes: "An invented destination for trying the manuscript comparison.",
    verified: false, shortlisted: true
  })
  {:ok, second_place} = Still.Correspondence.save_journal(location, %{
    name: "Field & Form (preview)", website: "https://example.com",
    notes: "Another invented destination. No policies or availability are implied.",
    verified: false, shortlisted: true
  })

  {:ok, first} = Poems.save(location, Poems.new(location), %{
    title: "A room for the rain",
    body: "The rain has stopped.\nI leave the window open\nfor whatever comes after.\n\n  On the table,\na letter without an address.\n"
  })
  {:ok, packet} = Still.Correspondence.save_packet(location, %{
    title: "A room for the rain / North Window", journal_id: first_place.id, piece_ids: [first.id],
    cover_letter: "Dear editors,\n\nPlease consider the enclosed poem. Thank you for reading.\n"
  })
  {:ok, packet} = Still.Correspondence.submit(location, packet.id, packet.token, "2026-09-12")
  {:ok, _} = Still.Correspondence.respond(location, packet.id, packet.token, "declined",
    "Thank you for letting us read this piece. (Invented preview reply.)", "2026-10-01")

  {:ok, middle} = Poems.save(location, first, %{
    title: "After the rain",
    body: "The rain has stopped.\nI leave the window open\nfor the shape of its leaving.\n\n  On the table,\na letter waiting for a name.\n"
  })
  {:ok, packet} = Still.Correspondence.save_packet(location, %{
    title: "After the rain / Field & Form", journal_id: second_place.id, piece_ids: [middle.id],
    cover_letter: "Dear editors,\n\nPlease consider the enclosed poem. Thank you for your time.\n"
  })
  {:ok, packet} = Still.Correspondence.submit(location, packet.id, packet.token, "2026-10-14")
  {:ok, packet} = Still.Correspondence.set_status(location, packet.id, packet.token, "awaiting")

  {:ok, current} = Poems.save(location, middle, %{
    title: "What the rain leaves",
    body: "The rain has stopped.\nI leave the window open\nfor the shape of its leaving.\n\n  On the table,\nan envelope holding\nthe quiet of the room.\n"
  })
  File.write!(proof_marker, Jason.encode!(%{piece_id: current.id, latest_packet_id: packet.id}) <> "\n")
  IO.puts("Created a separate invented work with two sent copies and two earlier saves.")
  IO.puts("Then & now: /correspondence/writing/#{current.id}?compare=latest")
end

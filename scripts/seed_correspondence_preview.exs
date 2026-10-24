# Disposable synthetic data only. Invoked by preview_correspondence.sh with explicit paths.
alias Still.{Correspondence, Poems, Repo, Storage}
root = System.fetch_env!("STILL_CORRESPONDENCE_PREVIEW_DIRECTORY") |> Path.expand()
true = String.starts_with?(Path.basename(root), "still-correspondence-")
true = Path.expand(Repo.config()[:database]) == Path.join(root, "still.db")
true = Path.expand(System.fetch_env!("STILL_LOCAL_STATE_DIRECTORY")) == Path.join(root, "state")
collection = Path.join(root, "collection")
false = File.exists?(collection)
File.mkdir!(collection)
{:ok, _} = Storage.set_folder(collection)
location = Storage.collection_location()

scenario = System.get_env("STILL_PREVIEW_SCENARIO", "small")
true = scenario in ["empty", "small", "established"]

if scenario != "empty" do
  pieces =
    [
      {"Small weather",
       "The rain keeps one light on\nin every window it passes.\n\n  I count them from the bus.\n"},
      {"Notes from the orchard",
       "By August the ladder\nhad become part of the tree,\na second trunk leaning\ntoward the house.\n"},
      {"The blue hour",
       "At six, the neighborhood\ngives back the day in small pieces:\n\na kettle, a gate, a lamp.\n"},
      {"Instructions for leaving",
       "Take only what the room\nhas already forgotten:\n\n  dust in the drawer,\n  a pale square on the wall.\n"},
      {nil, "A gate left open\nlets the afternoon through.\n"}
    ]
    |> Enum.map(fn {title, body} ->
      {:ok, piece} = Poems.save(location, Poems.new(location), %{title: title, body: body})
      piece
    end)

  journals =
    [
      {"Field & Form", "Attention to landscapes and ordinary moments.",
       "Check the current guidelines before submitting."},
      {"North Window Review", "An imagined destination for this preview.",
       "Not verified — confirm whether simultaneous submissions are permitted."},
      {"Orchard Quarterly", "A place to keep a few personal reading notes.",
       "No policy verified."}
    ]
    |> Enum.map(fn {name, notes, policy} ->
      {:ok, journal} =
        Correspondence.save_journal(location, %{
          name: name,
          website: "https://example.com",
          submission_url: "https://example.com/submissions",
          notes: notes,
          guidelines:
            "Synthetic preview record. Check a journal’s current requirements before preparing a real submission.",
          simultaneous_policy: policy,
          shortlisted: true,
          verified: false
        })

      journal
    end)

  packet = fn title, journal, works ->
    {:ok, packet} =
      Correspondence.save_packet(location, %{
        title: title,
        journal_id: journal.id,
        piece_ids: Enum.map(works, & &1.id),
        preparation_notes: "Review the destination’s current requirements before submitting.",
        cover_letter:
          "Dear editors,\n\nPlease consider the enclosed writing. Thank you for your time and attention.\n"
      })

    packet
  end

  [p1, p2, p3, p4, p5] = pieces
  [j1, j2, j3] = journals
  sent = packet.("Small weather / North Window", j2, [p1, p2])
  {:ok, sent} = Correspondence.submit(location, sent.id, sent.token, "2026-09-21")
  {:ok, _} = Correspondence.set_status(location, sent.id, sent.token, "awaiting")
  returned = packet.("Blue hour / Orchard", j3, [p3])
  {:ok, returned} = Correspondence.submit(location, returned.id, returned.token, "2026-08-08")

  {:ok, _} =
    Correspondence.respond(
      location,
      returned.id,
      returned.token,
      "declined",
      "Thank you for letting us read this work. We will pass on this occasion. (Synthetic reply.)",
      "2026-10-18"
    )

  _ = packet.("A gathering for Field & Form", j1, [p4, p5])
  accepted = packet.("Small weather / Field & Form", j1, [p1])
  {:ok, accepted} = Correspondence.submit(location, accepted.id, accepted.token, "2026-09-24")

  {:ok, _} =
    Correspondence.respond(
      location,
      accepted.id,
      accepted.token,
      "accepted",
      "Accepted for a future issue. Publication date is not yet known. (Synthetic reply.)",
      "2026-10-21",
      [p1.id]
    )

  {:ok, _} =
    Poems.save(location, p1, %{
      title: p1.title,
      body: p1.body <> "Even now, a small light stays.\n"
    })

  IO.puts(
    "Synthetic Correspondence preview created; submitted texts remain the earlier frozen versions."
  )

  if scenario == "established" do
    for n <- 1..7 do
      {:ok, piece} =
        Poems.save(location, Poems.new(location), %{
          title: "Study in blue #{n}",
          body:
            "On the table, a folded map.\nBeside it, the afternoon.\n\n  A synthetic manuscript, number #{n}.\n"
        })

      if rem(n, 2) == 0 do
        gathered = packet.("Blue studies #{n}", j3, [piece])
        {:ok, sent} = Correspondence.submit(location, gathered.id, gathered.token, "2026-10-01")
        {:ok, _} = Correspondence.set_status(location, sent.id, sent.token, "awaiting")
      end
    end

    {:ok, _} =
      Correspondence.save_journal(location, %{
        name: "Stone & Water (synthetic)",
        interests: "Poetry, brief prose, and the unexpected.",
        notes: "An imagined journal for testing a larger personal directory.",
        windows: "Unknown — check the source",
        shortlisted: false
      })
  end

  # This is an explicit choice in a disposable fixture, not automatic readiness.
  {:ok, _} = Correspondence.place_on_desk(location, p3.id, nil)
end

IO.puts("Editorial preview scenario: #{scenario}. All records are disposable synthetic examples.")

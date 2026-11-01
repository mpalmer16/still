defmodule Still.Correspondence do
  @moduledoc """
  Portable JSON persistence for Still correspondence. Data lives only in the configured
  collection folder. Sent manuscripts are separate immutable snapshots; historical SQLite
  Lists are never candidates or modified.
  """
  alias Still.{Poems, Storage}

  @root "correspondence"
  @marker ".still-correspondence.json"
  @format %{"format" => "still-correspondence-v1"}
  @desk_format "still-correspondence-desk"
  @desk_version 1
  @journal_fields ~w(name website submission_url interests guidelines windows fee simultaneous_policy response_expectation notes shortlisted verified inactive keywords reach reach_note possible_piece_ids icon_url description)
  @packet_fields ~w(title journal_id piece_ids preparation_notes cover_letter)
  @statuses ~w(preparing submitted awaiting declined accepted withdrawn)

  @doc "Searches titles and exact saved text without classifying or altering the writing."
  def search_pieces(pieces, query) do
    needle = String.downcase(query || "")

    Enum.filter(pieces, fn piece ->
      needle == "" or
        String.contains?(String.downcase(Poems.display_title(piece) <> " " <> piece.body), needle)
    end)
  end

  @doc "Literal keyword and phrase echoes in current saved writing; no editorial-fit ranking."
  def matching_keywords(journal, piece) do
    texts = Enum.map([Poems.display_title(piece), piece.body], &String.normalize(&1, :nfc))

    journal
    |> Map.get(:keywords)
    |> then(&(&1 || ""))
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&(String.normalize(&1, :nfc) |> String.downcase()))
    |> Enum.filter(fn keyword ->
      pattern =
        "(?<![\\p{L}\\p{M}\\p{N}_])" <>
          Regex.escape(String.normalize(keyword, :nfc)) <> "(?![\\p{L}\\p{M}\\p{N}_])"

      case Regex.compile(pattern, "iu") do
        {:ok, regex} -> Enum.any?(texts, &Regex.match?(regex, &1))
        {:error, _} -> false
      end
    end)
  end

  def pieces_to_consider(journal, pieces) do
    Enum.flat_map(pieces, fn piece ->
      keywords = matching_keywords(journal, piece)
      manual = piece.id in Map.get(journal, :possible_piece_ids, [])

      if manual || keywords != [],
        do: [%{piece: piece, keywords: keywords, manual: manual}],
        else: []
    end)
  end

  def places_to_consider(journals, piece) do
    journals
    |> Enum.filter(&active_journal?/1)
    |> Enum.flat_map(fn journal ->
      case pieces_to_consider(journal, [piece]) do
        [match] -> [Map.put(match, :journal, journal)]
        [] -> []
      end
    end)
  end

  def reach_label("approachable"), do: "Approachable"
  def reach_label("stretch"), do: "A stretch"
  def reach_label("long_shot"), do: "A long shot"
  def reach_label(_), do: "Unknown"

  @doc "Keeps or removes a personal possibility with stale-edit protection."
  def set_possible_piece(location, id, token, piece_id, keep) when is_boolean(keep) do
    with {:ok, journal} <- journal(location, id),
         :ok <- fresh(journal, token),
         {:ok, _} <- Poems.get(location, piece_id) do
      ids =
        if keep,
          do: Enum.uniq(journal.possible_piece_ids ++ [piece_id]),
          else: List.delete(journal.possible_piece_ids, piece_id)

      attrs = Map.take(journal, Enum.map(@journal_fields, &String.to_existing_atom/1))
      save_journal(location, Map.put(attrs, :possible_piece_ids, ids), id, token)
    end
  end

  def overview(location) do
    with {:ok, dirs} <- store(location),
         {:ok, journals} <- records(dirs.journals, :journal),
         {:ok, packets} <- records(dirs.packets, :packet),
         {:ok, pieces} <- Poems.list(location) do
      packets = Enum.map(packets, &attach_snapshot(&1, dirs))

      case Enum.find(packets, &match?({:error, _}, &1)) do
        nil ->
          {:ok,
           %{
             journals: Enum.sort_by(journals, &String.downcase(&1.name)),
             packets:
               Enum.map(packets, fn {:ok, p} -> p end) |> Enum.sort_by(& &1.updated_at, :desc),
             pieces: pieces
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def journal(location, id),
    do: with({:ok, d} <- store(location), do: read_record(d.journals, id, :journal))

  @doc "Reads places without loading manuscripts or submission snapshots."
  def journals(location),
    do: with({:ok, d} <- store(location), do: records(d.journals, :journal))

  @doc "Reads a bounded, optional icon cache without initializing or changing a collection."
  def read_icon_cache(location, journal) do
    with {:ok, dirs} <- store(location),
         dir = Path.join(Path.dirname(dirs.journals), "icons"),
         :ok <- safe_dir(dir),
         path = Path.join(dir, icon_cache_name(journal)),
         {:ok, %{type: :regular, size: size}} when size <= 360_000 <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, cache} when is_map(cache) <- Jason.decode(bytes) do
      {:ok, cache}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "Caches an icon only while its collection and source are still current."
  def write_icon_cache(location, journal, cache) do
    with {:ok, dirs} <- write_store(location) do
      base = Path.dirname(dirs.journals)

      :global.trans({{__MODULE__, base}, self()}, fn ->
        with_fs_lock(base, location.scope, fn ->
          with {:ok, current} <- read_record(dirs.journals, journal.id, :journal),
               true <- icon_cache_name(current) == icon_cache_name(journal),
               {:ok, dir} <- child(base, "icons"),
               path = Path.join(dir, icon_cache_name(journal)),
               :ok <- replaceable(path),
               :ok <- current_scope(base, location.scope) do
            atomic(path, Jason.encode!(cache) <> "\n")
          else
            _ -> {:error, :changed}
          end
        end)
      end)
    end
  end

  defp icon_cache_name(journal) do
    digest(journal.id <> Still.Correspondence.Icons.source_key(journal)) <> ".json"
  end

  @doc "Validates place details without writing to the collection."
  def validate_journal(attrs), do: normalize_journal(attrs)

  @doc "Deactivates or reactivates a place without changing its identity or submission history."
  def set_journal_active(location, id, token, active) when is_boolean(active) do
    with {:ok, journal} <- journal(location, id),
         :ok <- fresh(journal, token) do
      attrs = journal |> Map.take(Enum.map(@journal_fields, &String.to_existing_atom/1))
      save_journal(location, Map.put(attrs, :inactive, !active), id, token)
    end
  end

  def active_journal?(journal), do: !Map.get(journal, :inactive, false)

  def packet(location, id) do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d.packets, id, :packet),
         do: attach_snapshot(p, d)
  end

  @doc "Reads the optional manuscript pinned to this collection's Correspondence desk."
  def desk(location) do
    with {:ok, active} <- active_location(location),
         {:ok, dirs} <- read_store(active.folder),
         {:ok, current, _bytes} <- read_desk_file(desk_path(dirs)) do
      {:ok, current || empty_desk()}
    end
  end

  @doc "Pins a saved piece using the current Correspondence desk record token."
  def place_on_desk(location, piece_id, expected_token)
      when is_binary(piece_id) and (is_nil(expected_token) or is_binary(expected_token)) do
    if uuid_value?(piece_id) do
      case Poems.get(location, piece_id) do
        {:ok, _piece} -> write_desk(location, piece_id, expected_token)
        {:error, message} -> {:error, message}
      end
    else
      {:error, "The selected writing identifier is invalid."}
    end
  end

  def place_on_desk(_, _, _), do: {:error, "Reopen the Correspondence desk before changing it."}

  @doc "Clears the manuscript pin while retaining a versioned empty desk record."
  def clear_desk(location, expected_token)
      when is_nil(expected_token) or is_binary(expected_token),
      do: write_desk(location, nil, expected_token)

  def clear_desk(_, _), do: {:error, "Reopen the Correspondence desk before changing it."}

  def save_journal(location, attrs, id \\ nil, token \\ nil)

  def save_journal(location, attrs, id, token) when is_map(attrs) do
    with {:ok, vals} <- normalize_journal(attrs),
         {:ok, record_id} <- choose_id(id),
         {:ok, d} <- write_store(location),
         {:ok, old} <- existing(d.journals, id, token, :journal),
         :ok <- unique_name(d.journals, vals.name, record_id),
         vals <- preserve_optional_place_details(vals, attrs, old),
         now <- now(),
         rec <-
           Map.merge(vals, %{
             id: record_id,
             created_at: (old && old.created_at) || now,
             updated_at: now
           }),
         {:ok, saved} <- write_record(d.journals, rec, :journal, token),
         do: {:ok, saved}
  end

  def save_journal(_, _, _, _), do: invalid("journal")

  def save_packet(location, attrs, id \\ nil, token \\ nil)

  def save_packet(location, attrs, id, token) when is_map(attrs) do
    with {:ok, vals} <- normalize_packet(attrs),
         {:ok, record_id} <- choose_id(id),
         {:ok, d} <- store(location),
         {:ok, old} <- existing(d.packets, id, token, :packet),
         :ok <- editable(old),
         {:ok, j} <- read_record(d.journals, vals.journal_id, :journal),
         :ok <- active_destination(j),
         {:ok, pieces} <- current_pieces(location, vals.piece_ids),
         now <- now(),
         rec <-
           Map.merge(vals, %{
             id: record_id,
             created_at: (old && old.created_at) || now,
             updated_at: now,
             events: (old && old.events) || [],
             snapshot_ref: nil,
             snapshot_digest: nil,
             accepted_piece_ids: [],
             journal_name: j.name,
             piece_tokens: Map.new(pieces, &{&1.id, &1.token})
           }),
         {:ok, saved} <- write_record(d.packets, rec, :packet, token),
         do: {:ok, saved}
  end

  def save_packet(_, _, _, _), do: invalid("packet")

  def submit(location, id, token, date) do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d.packets, id, :packet),
         :ok <- fresh(p, token),
         :ok <- preparing(p),
         {:ok, pieces} <- current_pieces(location, p.piece_ids),
         :ok <- reviewed_tokens(p, pieces),
         {:ok, date} <- date(date),
         {:ok, j} <- read_record(d.journals, p.journal_id, :journal),
         :ok <- active_destination(j),
         sid <- Ecto.UUID.generate(),
         snap <- %{
           id: sid,
           packet_id: p.id,
           date: date,
           journal_id: p.journal_id,
           journal_name: j.name,
           packet_title: p.title,
           cover_letter: p.cover_letter,
           preparation_notes: p.preparation_notes,
           pieces:
             Enum.map(
               pieces,
               &%{
                 id: &1.id,
                 title: Poems.display_title(&1),
                 body: &1.body,
                 source_token: &1.token,
                 source_updated_at: &1.updated_at
               }
             )
         },
         {:ok, snapshot_digest} <- snapshot_write(d.snapshots, snap),
         event <- %{at: event_at(p), date: date, kind: "submitted", note: nil},
         next <-
           p
           |> Map.put(:status, "submitted")
           |> Map.put(:snapshot_ref, sid)
           |> Map.put(:snapshot_digest, snapshot_digest)
           |> Map.put(:journal_name, j.name)
           |> Map.update!(:events, &(&1 ++ [event]))
           |> Map.put(:updated_at, now()),
         {:ok, saved} <- write_record(d.packets, next, :packet, p.token),
         do: attach_snapshot(saved, d)
  end

  def respond(location, id, token, status, notes, date)
      when status in ["declined", "accepted", "withdrawn"] do
    respond(location, id, token, status, notes, date, nil)
  end

  def respond(_, _, _, _, _, _),
    do: {:error, "Choose declined, accepted, or withdrawn to record a response."}

  def respond(location, id, token, status, notes, date, accepted_ids)
      when status in ["declined", "accepted", "withdrawn"] do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d.packets, id, :packet),
         :ok <- fresh(p, token),
         :ok <- response_open(p),
         {:ok, date} <- date(date),
         {:ok, notes} <- text(notes, "Response notes", true),
         {:ok, accepted_now} <-
           accepted_ids(status, accepted_ids, p.piece_ids -- (p.accepted_piece_ids || [])),
         accepted <- Enum.uniq((p.accepted_piece_ids || []) ++ accepted_now),
         event <- %{
           at: event_at(p),
           date: date,
           kind: "response",
           status: status,
           note: notes,
           accepted_piece_ids: accepted
         },
         next <-
           p
           |> Map.put(:status, status)
           |> Map.put(:accepted_piece_ids, accepted)
           |> Map.update!(:events, &(&1 ++ [event]))
           |> Map.put(:updated_at, now()),
         {:ok, saved} <- write_record(d.packets, next, :packet, p.token),
         do: attach_snapshot(saved, d)
  end

  def respond(_, _, _, _, _, _, _), do: {:error, "Choose a valid response status."}

  def set_status(location, id, token, status)
      when status in ["submitted", "awaiting", "withdrawn"] do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d.packets, id, :packet),
         :ok <- fresh(p, token),
         :ok <- transition(p, status),
         date <- Date.to_iso8601(Date.utc_today()),
         event <- %{at: event_at(p), date: date, kind: "status", status: status, note: nil},
         next <-
           p
           |> Map.put(:status, status)
           |> Map.update!(:events, &(&1 ++ [event]))
           |> Map.put(:updated_at, now()),
         {:ok, saved} <- write_record(d.packets, next, :packet, p.token),
         do: attach_snapshot(saved, d)
  end

  def set_status(_, _, _, _), do: {:error, "That packet status cannot be set directly."}

  def history(location, piece_id) do
    with {:ok, v} <- overview(location) do
      rows =
        for(
          p <- v.packets,
          piece_id in p.piece_ids,
          do: %{
            packet: p,
            journal: Enum.find(v.journals, &(&1.id == p.journal_id)),
            snapshot: Enum.find((p[:snapshot] && p.snapshot.pieces) || [], &(&1.id == piece_id))
          }
        )

      {:ok, rows}
    end
  end

  def overlap(location, piece_ids, except_id \\ nil)

  def overlap(location, piece_ids, except_id) when is_list(piece_ids) do
    with {:ok, v} <- overview(location) do
      rows =
        for(
          p <- v.packets,
          p.id != except_id,
          p.status in ["submitted", "awaiting", "accepted"],
          id <- p.piece_ids -- (p.accepted_piece_ids || []),
          id in piece_ids,
          do: %{piece_id: id, packet: p, journal: Enum.find(v.journals, &(&1.id == p.journal_id))}
        )

      {:ok, rows}
    end
  end

  def overlap(_, _, _), do: {:error, "Choose one or more writing identifiers."}

  def export_packet(location, id) do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d.packets, id, :packet),
         {:ok, p} <- attach_snapshot(p, d),
         {:ok, j} <- journal_for_export(p, d),
         {:ok, pieces, frozen?} <- export_pieces(location, p, d) do
      {:ok, %{packet: p, journal: j, pieces: pieces, frozen?: frozen?}}
    end
  end

  defp export_pieces(_loc, %{snapshot: %{pieces: pieces}}, _d), do: {:ok, pieces, true}

  defp export_pieces(loc, p, _d) do
    with {:ok, pieces} <- current_pieces(loc, p.piece_ids),
         :ok <- reviewed_tokens(p, pieces),
         do:
           {:ok,
            Enum.map(
              pieces,
              &%{id: &1.id, title: Poems.display_title(&1), body: &1.body, token: &1.token}
            ), false}
  end

  defp journal_for_export(%{snapshot: s}, _d) when is_map(s),
    do: {:ok, %{id: s.journal_id, name: s.journal_name}}

  defp journal_for_export(p, d), do: read_record(d.journals, p.journal_id, :journal)

  defp normalize_journal(a) do
    with {:ok, v} <- fields(a, @journal_fields),
         {:ok, name} <- required(v["name"], "Journal name"),
         {:ok, website} <- web_url(v["website"], "Website"),
         {:ok, icon_url} <- web_url(v["icon_url"], "Icon URL"),
         {:ok, description} <- optional(v["description"], "Description"),
         {:ok, submission_url} <- web_url(v["submission_url"], "Submission URL"),
         {:ok, interests} <- optional(v["interests"], "Editorial interests"),
         {:ok, guidelines} <- optional(v["guidelines"], "Guidelines"),
         {:ok, windows} <- optional(v["windows"], "Reading windows"),
         {:ok, fee} <- optional(v["fee"], "Submission fee"),
         {:ok, simultaneous_policy} <-
           optional(v["simultaneous_policy"], "Simultaneous-submission policy"),
         {:ok, response_expectation} <-
           optional(v["response_expectation"], "Response expectations"),
         {:ok, notes} <- optional(v["notes"], "Personal notes"),
         {:ok, keywords} <- optional(v["keywords"], "Keywords"),
         {:ok, reach} <- reach(v["reach"]),
         {:ok, reach_note} <- optional(v["reach_note"], "Reach note"),
         {:ok, possible_piece_ids} <- possibility_ids(v["possible_piece_ids"]),
         {:ok, verified} <- bool(v["verified"]),
         {:ok, shortlisted} <- bool(v["shortlisted"]),
         {:ok, inactive} <- bool(v["inactive"]) do
      {:ok,
       %{
         name: name,
         website: website,
         icon_url: icon_url,
         description: description,
         submission_url: submission_url,
         interests: interests,
         guidelines: guidelines,
         windows: windows,
         fee: fee,
         simultaneous_policy: simultaneous_policy,
         response_expectation: response_expectation,
         notes: notes,
         keywords: keywords,
         reach: reach,
         reach_note: reach_note,
         possible_piece_ids: possible_piece_ids,
         verified: verified,
         shortlisted: shortlisted,
         inactive: inactive
       }}
    end
  end

  defp preserve_optional_place_details(vals, attrs, old) do
    Enum.reduce(
      [:inactive, :keywords, :reach, :reach_note, :possible_piece_ids, :icon_url, :description],
      vals,
      fn field, acc ->
        if old && !Map.has_key?(attrs, field) && !Map.has_key?(attrs, Atom.to_string(field)),
          do: Map.put(acc, field, Map.fetch!(old, field)),
          else: acc
      end
    )
  end

  defp possibility_ids(nil), do: {:ok, []}
  defp possibility_ids([]), do: {:ok, []}

  defp possibility_ids(ids) do
    case piece_ids(ids) do
      {:ok, ids} -> {:ok, ids}
      _ -> {:error, "Possibilities must contain distinct saved writing identifiers."}
    end
  end

  defp reach(value) when value in [nil, "", "unknown"], do: {:ok, "unknown"}
  defp reach(value) when value in ["approachable", "stretch", "long_shot"], do: {:ok, value}
  defp reach(_), do: {:error, "Reach must be unknown, approachable, stretch, or long_shot."}

  defp active_destination(journal) do
    if active_journal?(journal),
      do: :ok,
      else:
        {:error, "This place is inactive. Reactivate it before preparing or sending a packet."}
  end

  defp normalize_packet(a) do
    with {:ok, v} <- fields(a, @packet_fields),
         {:ok, title} <- optional(v["title"], "Packet title"),
         {:ok, journal_id} <- uuid(v["journal_id"], "Choose a journal."),
         {:ok, ids} <- piece_ids(v["piece_ids"]),
         {:ok, notes} <- optional(v["preparation_notes"], "Preparation notes"),
         {:ok, letter} <- optional(v["cover_letter"], "Cover letter") do
      {:ok,
       %{
         title: title,
         journal_id: journal_id,
         piece_ids: ids,
         preparation_notes: notes,
         cover_letter: letter,
         status: "preparing"
       }}
    end
  end

  defp fields(a, allowed) do
    if Enum.all?(Map.keys(a), &(to_string(&1) in allowed)),
      do: {:ok, Map.new(allowed, &{&1, Map.get(a, &1, Map.get(a, String.to_atom(&1)))})},
      else: {:error, "The record contains unsupported fields."}
  end

  defp required(v, label) do
    case text(v, label, false) do
      {:ok, value} ->
        if String.trim(value) == "",
          do: {:error, "#{label} is required."},
          else: {:ok, String.trim(value)}

      error ->
        error
    end
  end

  defp optional(nil, _), do: {:ok, nil}
  defp optional(v, label), do: text(v, label, true)

  defp web_url(nil, _label), do: {:ok, nil}
  defp web_url("", _label), do: {:ok, nil}

  defp web_url(value, label) when is_binary(value) do
    with {:ok, value} <- text(value, label, true),
         %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(value) do
      {:ok, value}
    else
      _ -> {:error, "#{label} must be an HTTP or HTTPS web address."}
    end
  end

  defp web_url(_, label), do: {:error, "#{label} must be an HTTP or HTTPS web address."}

  defp text(nil, _, true), do: {:ok, nil}

  defp text(v, label, allow_empty) when is_binary(v) do
    if String.valid?(v) and not String.contains?(v, <<0>>) and
         (allow_empty or String.trim(v) != ""),
       do: {:ok, v},
       else: {:error, "#{label} must be valid text."}
  end

  defp text(_, label, _), do: {:error, "#{label} must be text."}
  defp bool(nil), do: {:ok, false}
  defp bool(v) when is_boolean(v), do: {:ok, v}
  defp bool(_), do: {:error, "Journal flags must be true or false."}

  defp piece_ids(ids) when is_list(ids) do
    if ids != [] and Enum.all?(ids, &uuid_value?/1) and length(ids) == length(Enum.uniq(ids)),
      do: {:ok, ids},
      else: {:error, "Select distinct saved writings for the packet."}
  end

  defp piece_ids(_), do: {:error, "Add one or more saved writings to the packet."}

  defp uuid(v, _) when is_binary(v),
    do:
      if(uuid_value?(v),
        do: {:ok, v},
        else: {:error, "The selected journal identifier is invalid."}
      )

  defp uuid(_, msg), do: {:error, msg}
  defp uuid_value?(v), do: is_binary(v) and Ecto.UUID.cast(v) != :error

  defp current_pieces(loc, ids) do
    with {:ok, all} <- Poems.list(loc) do
      found = Map.new(all, &{&1.id, &1})

      if Enum.all?(ids, &Map.has_key?(found, &1)),
        do: {:ok, Enum.map(ids, &Map.fetch!(found, &1))},
        else:
          {:error,
           "One or more selected writings are missing from the active collection. Refresh before continuing."}
    end
  end

  defp reviewed_tokens(p, pieces) do
    if Enum.all?(pieces, &(Map.get(p.piece_tokens || %{}, &1.id) == &1.token)),
      do: :ok,
      else:
        {:error,
         "A selected writing changed after packet preparation. Reopen and review the packet before sending."}
  end

  defp valid_snapshot?(raw, packet) do
    pieces = raw["pieces"]

    is_binary(raw["id"]) and raw["id"] == packet.snapshot_ref and
      raw["packet_id"] == packet.id and raw["journal_id"] == packet.journal_id and
      is_binary(raw["date"]) and match?({:ok, _}, Date.from_iso8601(raw["date"])) and
      raw["journal_name"] == packet.journal_name and is_list(pieces) and
      Enum.map(pieces, & &1["id"]) == packet.piece_ids and
      Enum.all?(pieces, fn piece ->
        is_map(piece) and uuid_value?(piece["id"]) and is_binary(piece["title"]) and
          String.valid?(piece["title"]) and is_binary(piece["body_sha256"]) and
          byte_size(piece["body_sha256"]) == 64 and is_binary(piece["source_token"]) and
          valid_time?(piece["source_updated_at"])
      end)
  rescue
    _ -> false
  end

  defp snapshot_write(snapshots_dir, snapshot) do
    final_dir = Path.join(snapshots_dir, snapshot.id)
    stage_dir = Path.join(snapshots_dir, ".#{snapshot.id}.partial")
    pointer_path = Path.join(snapshots_dir, snapshot.id <> ".json")

    pieces =
      Enum.map(snapshot.pieces, fn piece ->
        Map.drop(piece, [:body]) |> Map.put(:body_sha256, digest(piece.body))
      end)

    manifest = %{snapshot | pieces: pieces}
    manifest_bytes = Jason.encode!(stringify(manifest), pretty: true) <> "\n"

    with :ok <- safe_dir(snapshots_dir),
         :ok <- absent(final_dir),
         :ok <- absent(pointer_path),
         :ok <- absent(stage_dir) do
      case File.mkdir(stage_dir) do
        :ok ->
          result =
            with :ok <- File.chmod(stage_dir, 0o700),
                 :ok <- write_piece_texts(stage_dir, snapshot.pieces),
                 :ok <- atomic(Path.join(stage_dir, "snapshot.json"), manifest_bytes),
                 :ok <- sync(stage_dir),
                 :ok <- File.rename(stage_dir, final_dir),
                 :ok <- sync(snapshots_dir),
                 :ok <- atomic(pointer_path, manifest_bytes) do
              {:ok, digest(manifest_bytes)}
            end

          case result do
            {:ok, _} = ok ->
              ok

            {:error, reason} ->
              File.rm_rf(stage_dir)
              {:error, explain(reason)}
          end

        {:error, reason} ->
          {:error, explain(reason)}
      end
    else
      {:error, reason} -> {:error, explain(reason)}
    end
  end

  defp write_piece_texts(stage_dir, pieces) do
    Enum.reduce_while(pieces, :ok, fn piece, :ok ->
      path = Path.join(stage_dir, piece.id <> ".txt")

      case atomic(path, piece.body) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp attach_snapshot(%{snapshot_ref: nil} = p, _d), do: {:ok, p}

  defp attach_snapshot(p, d) do
    path = Path.join(d.snapshots, p.snapshot_ref <> ".json")
    piece_dir = Path.join(d.snapshots, p.snapshot_ref)

    with true <- uuid_value?(p.snapshot_ref),
         :ok <- safe_file(path),
         :ok <- safe_dir(piece_dir),
         {:ok, bytes} <- File.read(path),
         true <- digest(bytes) == p.snapshot_digest,
         true <- internal_manifest_matches?(piece_dir, bytes),
         {:ok, raw} when is_map(raw) <- Jason.decode(bytes),
         true <- valid_snapshot?(raw, p),
         true <- valid_lifecycle_snapshot?(p, raw),
         {:ok, pieces} <- read_snapshot_pieces(raw["pieces"], piece_dir) do
      snap =
        atomize(raw, [
          :id,
          :packet_id,
          :date,
          :journal_id,
          :journal_name,
          :packet_title,
          :cover_letter,
          :preparation_notes
        ])

      {:ok, Map.put(p, :snapshot, Map.put(snap, :pieces, pieces))}
    else
      _ -> {:error, "The immutable sent-text snapshot is missing, invalid, or mismatched."}
    end
  end

  defp internal_manifest_matches?(piece_dir, pointer_bytes) do
    path = Path.join(piece_dir, "snapshot.json")
    with :ok <- safe_file(path), {:ok, bytes} <- File.read(path), do: bytes == pointer_bytes
  end

  defp read_snapshot_pieces(raw_pieces, piece_dir) do
    Enum.reduce_while(raw_pieces, {:ok, []}, fn raw, {:ok, acc} ->
      path = Path.join(piece_dir, raw["id"] <> ".txt")

      with :ok <- safe_file(path),
           {:ok, body} <- File.read(path),
           true <- String.valid?(body) and digest(body) == raw["body_sha256"] do
        piece =
          atomize(raw, [:id, :title, :source_token, :source_updated_at]) |> Map.put(:body, body)

        {:cont, {:ok, [piece | acc]}}
      else
        _ ->
          {:halt,
           {:error, "A frozen manuscript text file is missing or does not match its manifest."}}
      end
    end)
    |> case do
      {:ok, pieces} -> {:ok, Enum.reverse(pieces)}
      error -> error
    end
  rescue
    _ -> {:error, "A frozen manuscript text file is invalid."}
  end

  defp records(dir, kind) do
    with :ok <- safe_dir(dir), {:ok, names} <- File.ls(dir) do
      names
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn n, {:ok, acc} ->
        case read_record(dir, Path.rootname(n), kind) do
          {:ok, r} -> {:cont, {:ok, [r | acc]}}
          e -> {:halt, e}
        end
      end)
      |> case do
        {:ok, rs} -> {:ok, Enum.reverse(rs)}
        e -> e
      end
    else
      {:error, :enoent} -> {:ok, []}
      {:error, e} -> {:error, explain(e)}
    end
  end

  defp read_record(dir, id, kind) do
    if uuid_value?(id) do
      path = Path.join(dir, id <> ".json")

      with :ok <- safe_file(path),
           {:ok, bytes} <- File.read(path),
           {:ok, raw} when is_map(raw) <- Jason.decode(bytes),
           true <- raw["id"] == id,
           {:ok, rec} <- decode(raw, kind) do
        {:ok, Map.put(rec, :token, digest(bytes))}
      else
        {:error, :enoent} -> {:error, "No #{kind} with that identifier exists."}
        _ -> {:error, "A correspondence record is malformed or does not match its filename."}
      end
    else
      {:error, "The #{kind} identifier is invalid."}
    end
  end

  defp decode(r, :journal) do
    fields =
      ~w(name website submission_url interests guidelines windows fee simultaneous_policy response_expectation notes shortlisted verified created_at updated_at)

    text_fields =
      ~w(name website submission_url interests guidelines windows fee simultaneous_policy response_expectation notes)

    valid_texts = Enum.all?(text_fields, fn k -> nullable_text?(r[k]) end)
    valid_urls = valid_web_url?(r["website"]) and valid_web_url?(r["submission_url"])

    extensions_valid =
      valid_web_url?(r["icon_url"]) and
        match?({:ok, _}, optional(r["description"], "Description")) and
        match?({:ok, _}, optional(r["keywords"], "Keywords")) and
        match?({:ok, _}, optional(r["reach_note"], "Reach note")) and
        Map.get(r, "reach", "unknown") in ["unknown", "approachable", "stretch", "long_shot"] and
        is_list(Map.get(r, "possible_piece_ids", [])) and
        match?({:ok, _}, possibility_ids(Map.get(r, "possible_piece_ids", [])))

    r =
      r
      |> Map.put_new("icon_url", nil)
      |> Map.put_new("description", nil)
      |> Map.put_new("keywords", nil)
      |> Map.put_new("reach", "unknown")
      |> Map.put_new("reach_note", nil)
      |> Map.put_new("possible_piece_ids", [])

    if extensions_valid and Enum.all?(fields, &Map.has_key?(r, &1)) and valid_texts and valid_urls and
         is_binary(r["name"]) and
         String.trim(r["name"]) != "" and is_boolean(r["verified"]) and
         is_boolean(r["shortlisted"]) and is_boolean(Map.get(r, "inactive", false)) and
         valid_time?(r["created_at"]) and valid_time?(r["updated_at"]) do
      {:ok,
       atomize(Map.put_new(r, "inactive", false), [
         :id,
         :name,
         :website,
         :icon_url,
         :description,
         :submission_url,
         :interests,
         :guidelines,
         :windows,
         :fee,
         :simultaneous_policy,
         :response_expectation,
         :notes,
         :shortlisted,
         :verified,
         :inactive,
         :keywords,
         :reach,
         :reach_note,
         :possible_piece_ids,
         :created_at,
         :updated_at
       ])}
    else
      {:error, :invalid}
    end
  end

  defp decode(r, :packet) do
    fields =
      ~w(title journal_id piece_ids preparation_notes cover_letter status created_at updated_at events snapshot_ref snapshot_digest accepted_piece_ids journal_name piece_tokens)

    ids = r["piece_ids"]
    accepted = r["accepted_piece_ids"]
    tokens = r["piece_tokens"]

    basic =
      Enum.all?(fields, &Map.has_key?(r, &1)) and is_list(ids) and ids != [] and
        Enum.all?(ids, &uuid_value?/1) and length(ids) == length(Enum.uniq(ids)) and
        uuid_value?(r["journal_id"]) and r["status"] in @statuses and
        is_list(r["events"]) and Enum.all?(r["events"], &valid_event?(&1, ids)) and
        valid_event_times?(r["events"]) and
        valid_time?(r["created_at"]) and valid_time?(r["updated_at"]) and
        nullable_text?(r["title"]) and nullable_text?(r["preparation_notes"]) and
        nullable_text?(r["cover_letter"]) and is_list(accepted) and
        Enum.all?(accepted, &(&1 in ids)) and length(accepted) == length(Enum.uniq(accepted)) and
        (r["status"] != "accepted" or accepted != []) and is_map(tokens) and
        Map.keys(tokens) |> MapSet.new() == MapSet.new(ids) and
        Enum.all?(Map.values(tokens), &is_binary/1)

    preparing =
      r["status"] == "preparing" and is_nil(r["snapshot_ref"]) and
        is_nil(r["snapshot_digest"]) and accepted == []

    sent =
      r["status"] != "preparing" and uuid_value?(r["snapshot_ref"]) and
        is_binary(r["snapshot_digest"]) and is_binary(r["journal_name"]) and
        String.trim(r["journal_name"]) != ""

    if basic and (preparing or sent) and
         valid_lifecycle?(r["events"], r["status"], accepted, ids, preparing) do
      {:ok, atomize_packet(r)}
    else
      {:error, :invalid}
    end
  end

  # The event stream is the authority for a packet's lifecycle. A current status
  # that cannot be reached from the stream is corrupt, even if its fields look
  # individually well-formed.
  defp valid_lifecycle?([], "preparing", [], _ids, true), do: true

  defp valid_lifecycle?([%{"kind" => "submitted"} = first | rest], status, accepted, ids, false) do
    first["note"] == nil and is_nil(first["status"]) and is_nil(first["accepted_piece_ids"]) and
      lifecycle_tail(rest, "submitted", [], status, accepted, ids)
  end

  defp valid_lifecycle?(_, _, _, _, _), do: false

  defp lifecycle_tail([], state, accepted_now, final_status, final_accepted, _ids),
    do: state == final_status and accepted_now == final_accepted

  defp lifecycle_tail([event | rest], state, accepted_now, final_status, final_accepted, ids) do
    case {event["kind"], state, event["status"]} do
      {"status", "submitted", next} when next in ["awaiting", "withdrawn"] ->
        clean_status_event?(event) and
          lifecycle_tail(rest, next, accepted_now, final_status, final_accepted, ids)

      {"status", "awaiting", next} when next in ["submitted", "withdrawn"] ->
        clean_status_event?(event) and
          lifecycle_tail(rest, next, accepted_now, final_status, final_accepted, ids)

      {"response", current, next}
      when current in ["submitted", "awaiting", "accepted"] and
             next in ["accepted", "declined", "withdrawn"] ->
        response_accepted = event["accepted_piece_ids"]

        valid_response_event?(event) and is_list(response_accepted) and
          Enum.all?(response_accepted, &(&1 in ids)) and
          length(response_accepted) == length(Enum.uniq(response_accepted)) and
          Enum.all?(accepted_now, &(&1 in response_accepted)) and
          (next != "accepted" or response_accepted != []) and
          (current != "accepted" or length(accepted_now) < length(ids)) and
          (next != "accepted" or current != "accepted" or response_accepted != accepted_now) and
          lifecycle_tail(rest, next, response_accepted, final_status, final_accepted, ids)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp clean_status_event?(event),
    do: is_nil(event["note"]) and is_nil(event["accepted_piece_ids"])

  defp valid_response_event?(event),
    do: nullable_text?(event["note"])

  defp valid_lifecycle_snapshot?(packet, snapshot) do
    submitted = Enum.find(packet.events, &(&1.kind == "submitted"))

    is_map(submitted) and submitted.date == snapshot["date"] and
      packet.title == snapshot["packet_title"] and
      packet.cover_letter == snapshot["cover_letter"] and
      packet.preparation_notes == snapshot["preparation_notes"] and
      packet.journal_id == snapshot["journal_id"] and
      packet.journal_name == snapshot["journal_name"]
  rescue
    _ -> false
  end

  defp valid_event?(event, ids) when is_map(event) do
    event_accepts = event["accepted_piece_ids"]

    accepted_valid =
      is_nil(event_accepts) or
        (is_list(event_accepts) and length(event_accepts) == length(Enum.uniq(event_accepts)) and
           Enum.all?(event_accepts, &(&1 in ids)))

    accepted_valid and is_binary(event["at"]) and valid_time?(event["at"]) and
      is_binary(event["date"]) and
      match?({:ok, _}, Date.from_iso8601(event["date"])) and
      event["kind"] in ["submitted", "status", "response"] and
      nullable_text?(event["note"]) and
      (is_nil(event["status"]) or event["status"] in @statuses) and
      true
  end

  defp valid_event?(_, _), do: false

  defp valid_event_times?(events) do
    events
    |> Enum.map(&DateTime.from_iso8601(&1["at"]))
    |> Enum.reduce_while(nil, fn
      {:ok, current, _offset}, nil ->
        {:cont, current}

      {:ok, current, _offset}, previous ->
        if DateTime.compare(previous, current) in [:lt, :eq],
          do: {:cont, current},
          else: {:halt, false}

      _, _ ->
        {:halt, false}
    end)
    |> case do
      false -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  defp valid_web_url?(nil), do: true
  defp valid_web_url?(""), do: true

  defp valid_web_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp valid_web_url?(_), do: false

  defp nullable_text?(nil), do: true

  defp nullable_text?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  defp valid_time?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_time?(_), do: false

  defp atomize_packet(r) do
    base =
      atomize(r, [
        :id,
        :title,
        :journal_id,
        :piece_ids,
        :preparation_notes,
        :cover_letter,
        :status,
        :created_at,
        :updated_at,
        :snapshot_ref,
        :snapshot_digest,
        :accepted_piece_ids,
        :journal_name,
        :piece_tokens
      ])

    events =
      Enum.map(
        r["events"],
        &atomize(&1, [:at, :date, :kind, :status, :note, :accepted_piece_ids])
      )

    Map.put(base, :events, events)
  end

  defp atomize(m, keys),
    do:
      Enum.reduce(keys, %{}, fn k, a ->
        if Map.has_key?(m, Atom.to_string(k)), do: Map.put(a, k, m[Atom.to_string(k)]), else: a
      end)

  defp stringify(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(l) when is_list(l), do: Enum.map(l, &stringify/1)
  defp stringify(v), do: v

  defp write_record(dir, rec, kind, expected_token) do
    base = Path.dirname(dir)
    active = Storage.collection_location()

    if not active.available or Path.expand(active.folder) != Path.dirname(base) do
      {:error, "The active collection changed. Reopen Correspondence before continuing."}
    else
      expected_scope = active.scope

      :global.trans({{__MODULE__, base}, self()}, fn ->
        with_fs_lock(base, expected_scope, fn ->
          path = Path.join(dir, rec.id <> ".json")

          checked =
            case expected_token do
              nil ->
                with :ok <- absent(path), do: {:ok, nil}

              token ->
                with :ok <- safe_file(path),
                     {:ok, bytes} <- File.read(path),
                     {:ok, current} <- read_record(dir, rec.id, kind),
                     :ok <- fresh(current, token),
                     do: {:ok, bytes}
            end

          with :ok <- current_scope(base, expected_scope),
               {:ok, previous_bytes} <- checked,
               :ok <- if(kind == :journal, do: unique_name(dir, rec.name, rec.id), else: :ok),
               :ok <- writable_destination(base, rec, kind),
               :ok <- preserve_revision(base, rec.id, expected_token, previous_bytes),
               :ok <- safe_dir(dir),
               :ok <- current_scope(base, expected_scope),
               :ok <- replaceable(path),
               :ok <- atomic(path, Jason.encode!(stringify(rec), pretty: true) <> "\n"),
               {:ok, saved} <- read_record(dir, rec.id, kind) do
            {:ok, saved}
          else
            {:error, e} -> {:error, explain(e)}
          end
        end)
      end)
    end
  end

  defp writable_destination(base, %{status: status, journal_id: id}, :packet)
       when status in ["preparing", "submitted"] do
    with {:ok, journal} <- read_record(Path.join(base, "journals"), id, :journal),
         do: active_destination(journal)
  end

  defp writable_destination(_, _, _), do: :ok

  defp write_desk(location, piece_id, expected_token) do
    with {:ok, dirs} <- write_store(location) do
      base = Path.dirname(dirs.journals)
      active = Storage.collection_location()

      if not active.available or Path.expand(active.folder) != Path.dirname(base) do
        {:error, "The active collection changed. Reopen Correspondence before continuing."}
      else
        expected_scope = active.scope

        :global.trans({{__MODULE__, base}, self()}, fn ->
          with_fs_lock(base, expected_scope, fn ->
            path = desk_path(dirs)

            with :ok <- current_scope(base, expected_scope),
                 {:ok, _previous, previous_bytes} <- desk_revision(path, expected_token),
                 :ok <- validate_desk_piece(location, piece_id),
                 :ok <- preserve_revision(base, "desk", expected_token, previous_bytes),
                 :ok <- safe_dir(base),
                 :ok <- current_scope(base, expected_scope),
                 :ok <- replaceable(path),
                 record <- %{
                   "format" => @desk_format,
                   "version" => @desk_version,
                   "piece_id" => piece_id,
                   "updated_at" => now()
                 },
                 :ok <- atomic(path, Jason.encode!(record, pretty: true) <> "\n"),
                 {:ok, saved, _bytes} <- read_desk_file(path) do
              {:ok, saved}
            else
              {:error, reason} -> {:error, explain(reason)}
            end
          end)
        end)
      end
    end
  end

  defp validate_desk_piece(_location, nil), do: :ok

  defp validate_desk_piece(location, piece_id) do
    case Poems.get(location, piece_id) do
      {:ok, _piece} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp desk_revision(path, expected_token) do
    case read_desk_file(path) do
      {:ok, nil, nil} when is_nil(expected_token) ->
        {:ok, nil, nil}

      {:ok, nil, nil} ->
        {:error,
         "The Correspondence desk changed since it was opened. Reopen it before retrying."}

      {:ok, current, bytes} when current.token == expected_token ->
        {:ok, current, bytes}

      {:ok, _current, _bytes} ->
        {:error,
         "The Correspondence desk changed since it was opened. Reopen it before retrying."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp desk_path(dirs), do: Path.join(Path.dirname(dirs.journals), "desk.json")

  defp empty_desk, do: %{piece_id: nil, token: nil, updated_at: nil}

  defp read_desk_file(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, nil, nil}

      {:ok, %{type: :regular}} ->
        with {:ok, bytes} <- File.read(path),
             {:ok, raw} when is_map(raw) <- Jason.decode(bytes),
             true <- valid_desk_record?(raw) do
          state = %{
            piece_id: raw["piece_id"],
            token: digest(bytes),
            updated_at: raw["updated_at"]
          }

          {:ok, state, bytes}
        else
          _ ->
            {:error, "The Correspondence desk file is invalid; its contents were left untouched."}
        end

      {:ok, _} ->
        {:error, "The Correspondence desk path is unsafe; its contents were left untouched."}

      {:error, reason} ->
        {:error, explain(reason)}
    end
  end

  defp valid_desk_record?(raw) do
    Map.has_key?(raw, "piece_id") and raw["format"] == @desk_format and
      raw["version"] == @desk_version and
      (is_nil(raw["piece_id"]) or uuid_value?(raw["piece_id"])) and
      valid_time?(raw["updated_at"])
  end

  defp preserve_revision(_base, _id, nil, nil), do: :ok

  defp preserve_revision(base, id, token, bytes) when is_binary(token) and is_binary(bytes) do
    revisions = Path.join(base, "revisions")
    record_dir = Path.join(revisions, id)
    path = Path.join(record_dir, token <> ".json")

    with :ok <- ensure_safe_dir(revisions),
         :ok <- ensure_safe_dir(record_dir) do
      case File.lstat(path) do
        {:error, :enoent} ->
          atomic(path, bytes)

        {:ok, %{type: :regular}} ->
          with {:ok, existing} <- File.read(path), true <- existing == bytes do
            :ok
          else
            _ -> {:error, "A saved Correspondence revision conflicts with the current record."}
          end

        _ ->
          {:error, "A saved Correspondence revision path is unsafe."}
      end
    end
  end

  defp preserve_revision(_, _, _, _),
    do: {:error, "Could not preserve the previous Correspondence record."}

  defp ensure_safe_dir(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:error, :enoent} -> with :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700), do: :ok
      {:ok, _} -> {:error, "A Correspondence revision folder is unsafe."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_scope(base, expected_scope) do
    active = Storage.collection_location()

    if active.available and active.scope == expected_scope and
         Path.expand(active.folder) == Path.dirname(base),
       do: :ok,
       else: {:error, "The active collection changed. Reopen Correspondence before continuing."}
  end

  defp with_fs_lock(base, expected_scope, fun) do
    lock = Path.join(base, ".still-correspondence-lock")
    owner_path = Path.join(lock, "owner")
    owner_token = Ecto.UUID.generate()

    case File.mkdir(lock) do
      :ok ->
        result =
          try do
            with :ok <- File.chmod(lock, 0o700),
                 :ok <- write_lock_owner(owner_path, owner_token),
                 :ok <- current_scope(base, expected_scope) do
              fun.()
            end
          rescue
            error ->
              {:error, "Could not safely update Correspondence: #{Exception.message(error)}"}
          end

        case release_lock(lock, owner_path, owner_token) do
          :ok ->
            result

          {:error, reason} ->
            case result do
              {:ok, _} ->
                {:error,
                 "Correspondence was updated, but its lock could not be released: #{reason}"}

              {:error, message} ->
                {:error, "#{message} The update lock also needs attention: #{reason}"}

              _ ->
                {:error, "The Correspondence update lock needs attention: #{reason}"}
            end
        end

      {:error, :eexist} ->
        {:error, "Another Still instance is updating Correspondence. Retry after it finishes."}

      {:error, reason} ->
        {:error, explain(reason)}
    end
  end

  defp write_lock_owner(path, token) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- IO.binwrite(io, token <> "\n"), :ok <- :file.sync(io), do: :ok
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_lock(lock, owner_path, owner_token) do
    with :ok <- safe_dir(lock),
         :ok <- safe_file(owner_path),
         {:ok, bytes} <- File.read(owner_path),
         true <- bytes == owner_token <> "\n",
         :ok <- File.rm(owner_path),
         :ok <- File.rmdir(lock) do
      :ok
    else
      _ -> {:error, "The lock owner changed or the lock folder is not safe to remove."}
    end
  end

  defp existing(_dir, id, nil, _kind) when is_binary(id),
    do: {:error, "Reopen this record before saving your changes."}

  defp existing(_dir, nil, token, _kind) when not is_nil(token),
    do: {:error, "The new record revision is invalid."}

  defp existing(_dir, nil, nil, _kind), do: {:ok, nil}

  defp existing(dir, id, token, kind) when is_binary(id) and is_binary(token) do
    with {:ok, r} <- read_record(dir, id, kind), :ok <- fresh(r, token), do: {:ok, r}
  end

  defp existing(_, _, _, _), do: {:error, "Reopen this record before saving your changes."}
  defp editable(nil), do: :ok
  defp editable(%{status: "preparing", snapshot_ref: nil}), do: :ok
  defp editable(_), do: {:error, "A sent packet is an historical record and cannot be edited."}
  defp preparing(%{status: "preparing", snapshot_ref: nil}), do: :ok
  defp preparing(_), do: {:error, "Only a prepared packet can be marked sent."}

  defp response_open(%{status: s, snapshot_ref: ref})
       when s in ["submitted", "awaiting"] and is_binary(ref), do: :ok

  defp response_open(%{
         status: "accepted",
         snapshot_ref: ref,
         piece_ids: ids,
         accepted_piece_ids: accepted
       })
       when is_binary(ref) and length(accepted) < length(ids), do: :ok

  defp response_open(_),
    do: {:error, "Record a response only for sent work that is still awaiting a reply."}

  defp transition(%{status: s, snapshot_ref: ref}, n)
       when is_binary(ref) and
              ((s == "submitted" and n in ["awaiting", "withdrawn"]) or
                 (s == "awaiting" and n in ["submitted", "withdrawn"])),
       do: :ok

  defp transition(_, _), do: {:error, "That status change is not valid for this packet."}

  defp accepted_ids("accepted", nil, ids), do: {:ok, ids}

  defp accepted_ids("accepted", ids, all) when is_list(ids) do
    if ids != [] and length(ids) == length(Enum.uniq(ids)) and Enum.all?(ids, &(&1 in all)),
      do: {:ok, ids},
      else: {:error, "Choose one or more pieces from this packet as accepted."}
  end

  defp accepted_ids(status, _, _) when status in ["declined", "withdrawn"], do: {:ok, []}

  defp accepted_ids(_, _, _),
    do: {:error, "Accepted piece identifiers must belong to the packet."}

  defp unique_name(dir, name, id) do
    with {:ok, js} <- records(dir, :journal) do
      if Enum.any?(js, &(String.downcase(&1.name) == String.downcase(name) and &1.id != id)),
        do: {:error, "A journal with this name already exists."},
        else: :ok
    end
  end

  defp choose_id(nil), do: {:ok, Ecto.UUID.generate()}

  defp choose_id(id),
    do: if(uuid_value?(id), do: {:ok, id}, else: {:error, "The record identifier is invalid."})

  defp fresh(%{token: t}, t) when is_binary(t), do: :ok
  defp fresh(_, _), do: {:error, "This record changed on disk. Reopen it before continuing."}
  defp date(%Date{} = d), do: {:ok, Date.to_iso8601(d)}

  defp date(v) when is_binary(v),
    do:
      case(Date.from_iso8601(v),
        do: (
          {:ok, d} -> {:ok, Date.to_iso8601(d)}
          _ -> {:error, "Enter a valid calendar date."}
        )
      )

  defp date(_), do: {:error, "Enter a valid calendar date."}

  defp store(location) do
    with {:ok, active} <- active_location(location), do: read_store(active.folder)
  end

  defp write_store(location) do
    with {:ok, active} <- active_location(location) do
      base = Path.join(active.folder, @root)

      case File.lstat(base) do
        {:error, :enoent} ->
          with :ok <- create_store(active.folder), do: read_store(active.folder)

        {:ok, %{type: :directory}} ->
          read_store(active.folder)

        {:ok, _} ->
          {:error, "The Correspondence path is a symlink or not a directory."}

        {:error, reason} ->
          {:error, explain(reason)}
      end
    end
  end

  defp active_location(location) do
    active = Storage.collection_location()
    scope = if is_map(location), do: location[:scope] || location["scope"], else: nil

    cond do
      not active.configured ->
        {:error, "Choose a collection folder before using Correspondence."}

      not active.available ->
        {:error, active.error || "The selected collection folder is unavailable."}

      is_binary(scope) and scope != active.scope ->
        {:error, "The active collection changed. Reopen Correspondence before continuing."}

      not File.dir?(active.folder) ->
        {:error, "The selected collection folder became unavailable."}

      true ->
        {:ok, active}
    end
  end

  defp create_store(root) do
    base = Path.join(root, @root)

    case File.lstat(base) do
      {:ok, %{type: :directory}} ->
        marker = Path.join(base, @marker)

        with :ok <- safe_file(marker),
             {:ok, bytes} <- File.read(marker),
             {:ok, @format} <- Jason.decode(bytes) do
          :ok
        else
          _ ->
            {:error,
             "The Correspondence folder is unrecognized; its contents were left untouched."}
        end

      {:error, :enoent} ->
        initialize_store(root, base)

      {:ok, _} ->
        {:error, "The Correspondence path is a symlink or not a directory."}

      {:error, e} ->
        {:error, explain(e)}
    end
  end

  defp initialize_store(root, base) do
    stage = Path.join(root, ".correspondence-init-#{Ecto.UUID.generate()}.partial")

    with :ok <- safe_dir(root),
         :ok <- absent(stage),
         :ok <- File.mkdir(stage),
         :ok <- File.chmod(stage, 0o700),
         :ok <- atomic(Path.join(stage, @marker), Jason.encode!(@format) <> "\n"),
         {:ok, _} <- child(stage, "journals"),
         {:ok, _} <- child(stage, "packets"),
         {:ok, _} <- child(stage, "snapshots"),
         :ok <- sync(stage) do
      case File.rename(stage, base) do
        :ok ->
          case sync(root) do
            :ok ->
              :ok

            {:error, reason} ->
              {:error,
               "Correspondence initialization may have completed, but its folder could not be synced: #{explain(reason)}. Reopen the collection before retrying."}
          end

        {:error, reason} ->
          case File.lstat(base) do
            {:ok, %{type: :directory}} ->
              case read_store(root) do
                {:ok, _} ->
                  :ok

                {:error, _} ->
                  {:error,
                   "Another initialization may have published Correspondence, but the resulting folder needs repair. The staged copy was preserved."}
              end

            _ ->
              {:error,
               "Could not publish the staged Correspondence folder: #{explain(reason)}. The staged copy was preserved at #{stage}."}
          end
      end
    else
      {:error, reason} ->
        {:error,
         "Could not initialize Correspondence: #{explain(reason)}. Any staged files were preserved for inspection."}
    end
  end

  defp read_store(root) do
    base = Path.join(root, @root)

    case File.lstat(base) do
      {:error, :enoent} ->
        {:ok,
         %{
           journals: Path.join(base, "journals"),
           packets: Path.join(base, "packets"),
           snapshots: Path.join(base, "snapshots")
         }}

      {:ok, %{type: :directory}} ->
        marker = Path.join(base, @marker)

        with :ok <- safe_file(marker),
             {:ok, bytes} <- File.read(marker),
             {:ok, @format} <- Jason.decode(bytes),
             {:ok, journals} <- existing_child(base, "journals"),
             {:ok, packets} <- existing_child(base, "packets"),
             {:ok, snapshots} <- existing_child(base, "snapshots") do
          {:ok, %{journals: journals, packets: packets, snapshots: snapshots}}
        else
          {:error, :enoent} ->
            {:error,
             "Correspondence data is incomplete; reconnect or repair the collection folder."}

          _ ->
            {:error,
             "The Correspondence folder is unrecognized or unsafe; its contents were left untouched."}
        end

      {:ok, _} ->
        {:error, "The Correspondence path is a symlink or not a directory."}

      {:error, e} ->
        {:error, explain(e)}
    end
  end

  defp existing_child(base, name) do
    path = Path.join(base, name)
    with :ok <- safe_dir(path), do: {:ok, path}
  end

  defp child(base, name) do
    path = Path.join(base, name)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        {:ok, path}

      {:error, :enoent} ->
        with :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700), do: {:ok, path}

      {:ok, _} ->
        {:error, "A Correspondence subfolder is a symlink or not a directory."}

      {:error, e} ->
        {:error, explain(e)}
    end
  end

  defp safe_dir(p),
    do:
      case(File.lstat(p),
        do: (
          {:ok, %{type: :directory}} -> :ok
          {:ok, _} -> {:error, "A Correspondence path is unsafe."}
          e -> e
        )
      )

  defp safe_file(p),
    do:
      case(File.lstat(p),
        do: (
          {:ok, %{type: :regular}} -> :ok
          {:ok, _} -> {:error, "A Correspondence file is not a regular file."}
          e -> e
        )
      )

  defp replaceable(p),
    do:
      case(File.lstat(p),
        do: (
          {:error, :enoent} -> :ok
          {:ok, %{type: :regular}} -> :ok
          _ -> {:error, "A Correspondence record path is unsafe."}
        )
      )

  defp absent(p),
    do:
      case(File.lstat(p),
        do: (
          {:error, :enoent} -> :ok
          _ -> {:error, "A snapshot with this identifier already exists."}
        )
      )

  defp atomic(path, bytes) do
    tmp = path <> ".tmp-" <> Ecto.UUID.generate()

    result =
      case File.open(tmp, [:write, :binary, :exclusive]) do
        {:ok, io} ->
          try do
            with :ok <- IO.binwrite(io, bytes), :ok <- :file.sync(io), do: :ok
          after
            File.close(io)
          end

        e ->
          e
      end

    with :ok <- result,
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      case sync(Path.dirname(path)) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error,
           "The file may already be published at #{path}, but its folder sync failed (#{explain(reason)}). Reopen before retrying."}
      end
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp sync(p) do
    case :file.open(String.to_charlist(p), [:read, :raw]) do
      {:ok, io} ->
        r = :file.sync(io)
        :file.close(io)
        if r in [:ok, {:error, :eisdir}, {:error, :enotsup}, {:error, :einval}], do: :ok, else: r

      {:error, e} when e in [:eisdir, :enotsup, :einval] ->
        :ok

      {:error, e} ->
        {:error, e}
    end
  end

  defp digest(v), do: :crypto.hash(:sha256, v) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp event_at(%{events: events}) do
    current = DateTime.utc_now()

    case List.last(events || []) do
      %{at: previous} when is_binary(previous) ->
        case DateTime.from_iso8601(previous) do
          {:ok, previous, _offset} ->
            if DateTime.compare(previous, current) == :gt,
              do: DateTime.to_iso8601(previous),
              else: DateTime.to_iso8601(current)

          _ ->
            DateTime.to_iso8601(current)
        end

      _ ->
        DateTime.to_iso8601(current)
    end
  end

  defp invalid(s), do: {:error, "The #{s} data is invalid."}
  defp explain(e) when is_binary(e), do: e
  defp explain(e) when is_atom(e), do: :file.format_error(e) |> List.to_string()
  defp explain(e), do: inspect(e)
end

defmodule Still.Correspondence do
  @moduledoc """
  Scope-keyed local SQLite persistence for Still correspondence. Sent manuscripts are
  immutable database snapshots; historical SQLite Lists are never candidates or modified.
  """
  alias Still.{LocalRecord, Poems, Repo, Storage}
  alias Still.Writing.{Entry, PoemReferences, Version}
  import Ecto.Query

  @journal_fields ~w(name website submission_url interests guidelines windows fee simultaneous_policy response_expectation notes shortlisted verified inactive keywords reach reach_note possible_piece_ids icon_url description)
  @packet_fields ~w(title journal_id piece_ids preparation_notes cover_letter)
  @statuses ~w(preparing submitted awaiting declined accepted withdrawn)
  @desk_format "still-correspondence-desk"
  @desk_version 1

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

  def overview(location), do: load_overview(location, :all)

  def focused_overview(location, keep_ids \\ []), do: load_overview(location, keep_ids)

  defp load_overview(location, selection) do
    with {:ok, dirs} <- store(location),
         {:ok, journals} <- records(dirs, :journal),
         {:ok, packets} <- records(dirs, :packet),
         {:ok, packets} <- attach_snapshots(packets, dirs),
         {:ok, pieces} <- Poems.list(location) do
      packet_ids = MapSet.new(Enum.flat_map(packets, & &1.piece_ids))
      packet_pieces = Enum.filter(pieces, &MapSet.member?(packet_ids, &1.id))

      pieces =
        case selection do
          :all ->
            pieces

          keep_ids ->
            focus = focus_flags(dirs.scope)
            keep = MapSet.new(keep_ids)

            Enum.filter(pieces, fn piece ->
              Map.get(focus, piece.id, MapSet.member?(packet_ids, piece.id)) or
                MapSet.member?(keep, piece.id)
            end)
        end

      pieces = attach_revision_counts(dirs.scope, pieces)

      {:ok,
       %{
         journals: Enum.sort_by(journals, &String.downcase(&1.name)),
         packets: Enum.sort_by(packets, & &1.updated_at, :desc),
         pieces: pieces,
         packet_pieces: packet_pieces
       }}
    end
  end

  @doc "The correspondence status of pieces in the selected collection."
  def writing_status(%{available: true, scope: scope}) do
    packets =
      Repo.all(
        from r in LocalRecord,
          where: r.scope == ^scope and r.kind == "packet",
          select: r.data
      )

    focused =
      packets
      |> Enum.flat_map(&packet_piece_ids/1)
      |> Map.new(&{&1, true})
      |> Map.merge(focus_flags(scope))

    submitted =
      packets
      |> Enum.filter(&match?(%{"snapshot_ref" => ref} when is_binary(ref), &1))
      |> Enum.flat_map(&packet_piece_ids/1)
      |> MapSet.new()

    %{focused: focused, submitted: submitted}
  end

  def writing_status(_), do: %{focused: %{}, submitted: MapSet.new()}

  def set_focus(location, piece_id, marked?) when is_boolean(marked?) do
    with {:ok, %{scope: scope}} <- store(location),
         {:ok, _} <- Poems.get(location, piece_id) do
      case Repo.transaction(fn ->
             ensure_current_scope!(scope)

             %LocalRecord{}
             |> LocalRecord.changeset(%{
               scope: scope,
               kind: "submission_focus",
               record_key: piece_id,
               data: %{"marked" => marked?}
             })
             |> Repo.insert!(
               on_conflict: {:replace, [:data, :updated_at]},
               conflict_target: [:scope, :kind, :record_key]
             )
           end) do
        {:ok, _} -> :ok
        {:error, {:error, message}} -> {:error, message}
      end
    end
  end

  defp packet_piece_ids(%{"piece_ids" => ids}) when is_list(ids), do: ids
  defp packet_piece_ids(_), do: []

  defp focus_flags(scope) do
    Repo.all(
      from r in LocalRecord,
        where: r.scope == ^scope and r.kind == "submission_focus",
        select: {r.record_key, r.data}
    )
    |> Map.new(fn {id, data} -> {id, match?(%{"marked" => true}, data)} end)
  end

  def journal(location, id),
    do: with({:ok, d} <- store(location), do: read_record(d, id, :journal))

  @doc "Reads places without loading manuscripts or submission snapshots."
  def journals(location),
    do: with({:ok, d} <- store(location), do: records(d, :journal))

  @doc "Reads a bounded, optional icon cache without initializing or changing a collection."
  def read_icon_cache(location, journal) do
    with {:ok, active} <- active_location(location),
         %LocalRecord{data: data, bytes: bytes} <-
           Repo.get_by(LocalRecord,
             scope: active.scope,
             kind: "icon",
             record_key: journal.id <> ":" <> Still.Correspondence.Icons.source_key(journal)
           ),
         true <- is_map(data) do
      cond do
        is_binary(bytes) and byte_size(bytes) <= 262_144 ->
          {:ok, Map.put(data, "data", Base.encode64(bytes))}

        is_binary(bytes) ->
          {:ok, %{"invalid" => true}}

        true ->
          {:ok, data}
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "Reads a set of bounded icon caches with one scope validation and one database query."
  def read_icon_caches(location, journals) when is_list(journals) do
    keys =
      Map.new(journals, fn journal ->
        {journal.id <> ":" <> Still.Correspondence.Icons.source_key(journal), journal.id}
      end)

    if map_size(keys) == 0 do
      %{}
    else
      record_keys = Map.keys(keys)

      case active_location(location) do
        {:ok, active} ->
          rows =
            Repo.all(
              from(r in LocalRecord,
                where:
                  r.scope == ^active.scope and r.kind == "icon" and
                    r.record_key in ^record_keys
              )
            )
            |> Map.new(&{&1.record_key, &1})

          Map.new(keys, fn {key, id} ->
            result =
              case Map.get(rows, key) do
                %LocalRecord{data: data, bytes: bytes} when is_map(data) ->
                  cond do
                    is_binary(bytes) and byte_size(bytes) <= 262_144 ->
                      {:ok, Map.put(data, "data", Base.encode64(bytes))}

                    is_binary(bytes) ->
                      {:ok, %{"invalid" => true}}

                    true ->
                      {:ok, data}
                  end

                _ ->
                  :missing
              end

            {id, result}
          end)

        _ ->
          Map.new(journals, &{&1.id, :unavailable})
      end
    end
  end

  def read_icon_caches(_, _), do: %{}

  def write_icon_cache(location, journal, cache) do
    with {:ok, active} <- active_location(location),
         {:ok, current} <- read_record(%{scope: active.scope}, journal.id, :journal),
         true <- icon_cache_name(current) == icon_cache_name(journal) do
      key = journal.id <> ":" <> Still.Correspondence.Icons.source_key(journal)

      {:ok, bytes} =
        if is_binary(cache["data"]), do: Base.decode64(cache["data"]), else: {:ok, nil}

      attrs = %{
        scope: active.scope,
        kind: "icon",
        record_key: key,
        data: stringify(Map.delete(cache, "data")),
        bytes: bytes
      }

      case %LocalRecord{}
           |> LocalRecord.changeset(attrs)
           |> Repo.insert(
             on_conflict: {:replace, [:data, :bytes, :updated_at]},
             conflict_target: [:scope, :kind, :record_key]
           ) do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :changed}
      end
    else
      _ -> {:error, :changed}
    end
  end

  defp icon_cache_name(journal),
    do: digest(journal.id <> Still.Correspondence.Icons.source_key(journal))

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
         {:ok, p} <- read_record(d, id, :packet),
         do: attach_snapshot(p, d)
  end

  @doc "Reads the optional manuscript pinned to this collection's Correspondence desk."
  def desk(location) do
    with {:ok, active} <- active_location(location), do: desk_for_scope(%{scope: active.scope})
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
         {:ok, old} <- existing(d, id, token, :journal),
         :ok <- unique_name(d, vals.name, record_id),
         vals <- preserve_optional_place_details(vals, attrs, old),
         now <- now(),
         rec <-
           Map.merge(vals, %{
             id: record_id,
             created_at: (old && old.created_at) || now,
             updated_at: now
           }),
         {:ok, saved} <- write_record(d, rec, :journal, token),
         do: {:ok, saved}
  end

  def save_journal(_, _, _, _), do: invalid("journal")

  def save_packet(location, attrs, id \\ nil, token \\ nil)

  def save_packet(location, attrs, id, token) when is_map(attrs) do
    with {:ok, vals} <- normalize_packet(attrs),
         {:ok, record_id} <- choose_id(id),
         {:ok, d} <- store(location),
         {:ok, old} <- existing(d, id, token, :packet),
         :ok <- editable(old),
         {:ok, j} <- read_record(d, vals.journal_id, :journal),
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
         {:ok, saved} <- write_record(d, rec, :packet, token),
         do: {:ok, saved}
  end

  def save_packet(_, _, _, _), do: invalid("packet")

  def submit(location, id, token, date) do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d, id, :packet),
         :ok <- fresh(p, token),
         :ok <- preparing(p),
         {:ok, pieces} <- current_pieces(location, p.piece_ids),
         :ok <- reviewed_tokens(p, pieces),
         {:ok, date} <- date(date),
         {:ok, j} <- read_record(d, p.journal_id, :journal),
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
                 title_in_body: Map.get(&1, :title_in_body, true),
                 title_line: Map.get(&1, :title_line),
                 title_source: Map.get(&1, :title_source, "first_line"),
                 source_token: &1.token,
                 source_updated_at: &1.updated_at
               }
             )
         },
         {:ok, snapshot_digest} <- snapshot_write(d, snap),
         event <- %{at: event_at(p), date: date, kind: "submitted", note: nil},
         next <-
           p
           |> Map.put(:status, "submitted")
           |> Map.put(:snapshot_ref, sid)
           |> Map.put(:snapshot_digest, snapshot_digest)
           |> Map.put(:journal_name, j.name)
           |> Map.update!(:events, &(&1 ++ [event]))
           |> Map.put(:updated_at, now()),
         {:ok, saved} <- write_record(d, next, :packet, p.token),
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
         {:ok, p} <- read_record(d, id, :packet),
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
         {:ok, saved} <- write_record(d, next, :packet, p.token),
         do: attach_snapshot(saved, d)
  end

  def respond(_, _, _, _, _, _, _), do: {:error, "Choose a valid response status."}

  def set_status(location, id, token, status)
      when status in ["submitted", "awaiting", "withdrawn"] do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d, id, :packet),
         :ok <- fresh(p, token),
         :ok <- transition(p, status),
         date <- Date.to_iso8601(Date.utc_today()),
         event <- %{at: event_at(p), date: date, kind: "status", status: status, note: nil},
         next <-
           p
           |> Map.put(:status, status)
           |> Map.update!(:events, &(&1 ++ [event]))
           |> Map.put(:updated_at, now()),
         {:ok, saved} <- write_record(d, next, :packet, p.token),
         do: attach_snapshot(saved, d)
  end

  def set_status(_, _, _, _), do: {:error, "That packet status cannot be set directly."}

  def history(location, piece_id) do
    with {:ok, d} <- store(location),
         {:ok, packets} <- records(d, :packet) do
      packets =
        packets
        |> Enum.filter(&(piece_id in &1.piece_ids))
        |> Enum.sort_by(& &1.updated_at, :desc)

      with {:ok, packets} <- attach_snapshots(packets, d),
           {:ok, journals} <- journals_for_packets(packets, d) do
        rows =
          for p <- packets do
            %{
              packet: p,
              journal: Enum.find(journals, &(&1.id == p.journal_id)),
              snapshot: Enum.find((p[:snapshot] && p.snapshot.pieces) || [], &(&1.id == piece_id))
            }
          end

        {:ok, rows}
      end
    end
  end

  def overlap(location, piece_ids, except_id \\ nil)

  def overlap(location, piece_ids, except_id) when is_list(piece_ids) do
    with {:ok, d} <- store(location),
         {:ok, packets} <- records(d, :packet) do
      packets =
        Enum.filter(packets, fn p ->
          p.id != except_id and p.status in ["submitted", "awaiting", "accepted"] and
            Enum.any?(p.piece_ids -- (p.accepted_piece_ids || []), &(&1 in piece_ids))
        end)
        |> Enum.sort_by(& &1.updated_at, :desc)

      with {:ok, packets} <- attach_snapshots(packets, d) do
        rows =
          for p <- packets,
              id <- p.piece_ids -- (p.accepted_piece_ids || []),
              id in piece_ids,
              do: %{piece_id: id, packet: p, journal_id: p.journal_id}

        with {:ok, journals} <- journals_for_packets(Enum.map(rows, & &1.packet), d) do
          {:ok,
           Enum.map(rows, fn row ->
             Map.put(row, :journal, Enum.find(journals, &(&1.id == row.journal_id)))
             |> Map.delete(:journal_id)
           end)}
        end
      end
    end
  end

  def overlap(_, _, _), do: {:error, "Choose one or more writing identifiers."}

  def export_packet(location, id) do
    with {:ok, d} <- store(location),
         {:ok, p} <- read_record(d, id, :packet),
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
              &%{
                id: &1.id,
                title: Poems.display_title(&1),
                body: &1.body,
                title_in_body: Map.get(&1, :title_in_body, true),
                title_line: Map.get(&1, :title_line),
                title_source: Map.get(&1, :title_source, "first_line"),
                token: &1.token
              }
            ), false}
  end

  defp journal_for_export(%{snapshot: s}, _d) when is_map(s),
    do: {:ok, %{id: s.journal_id, name: s.journal_name}}

  defp journal_for_export(p, d), do: read_record(d, p.journal_id, :journal)

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
        do:
          ids
          |> Enum.map(&Map.fetch!(found, &1))
          |> expand_linked_pieces(loc),
        else:
          {:error,
           "One or more selected writings are missing from the active collection. Refresh before continuing."}
    end
  end

  defp expand_linked_pieces(pieces, location) do
    Enum.reduce_while(pieces, {:ok, []}, fn piece, {:ok, acc} ->
      references = Enum.filter(PoemReferences.parse(piece.body), &(&1.kind == :reference))

      if references == [] do
        {:cont, {:ok, acc ++ [piece]}}
      else
        resolved =
          PoemReferences.resolve(location, piece.body,
            current_id: piece.id,
            reconcile: true
          )

        case expand_segments(resolved) do
          {:ok, expanded_body, dependencies} ->
            body_digest = :crypto.hash(:sha256, expanded_body)

            token =
              :crypto.hash(
                :sha256,
                :erlang.term_to_binary({piece.token, body_digest, dependencies})
              )
              |> Base.encode16(case: :lower)

            expanded = %{piece | body: expanded_body, token: token}
            {:cont, {:ok, acc ++ [expanded]}}

          {:error, message} ->
            {:halt, {:error, message}}
        end
      end
    end)
  end

  defp expand_segments(segments) do
    Enum.reduce_while(segments, {:ok, [], []}, fn
      %{kind: :text, raw: raw}, {:ok, body, dependencies} ->
        {:cont, {:ok, [body, raw], dependencies}}

      %{kind: :reference, status: :available, source: source}, {:ok, body, dependencies} ->
        dependency = {source.id, source.token}
        {:cont, {:ok, [body, source.body], dependencies ++ [dependency]}}

      %{kind: :reference, message: message}, _acc ->
        {:halt,
         {:error,
          "A linked poem is unavailable. #{message || "Reopen Saved writing to reconnect it."}"}}
    end)
    |> case do
      {:ok, body_parts, dependencies} ->
        {:ok, IO.iodata_to_binary(body_parts), dependencies}

      error ->
        error
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
          String.valid?(piece["title"]) and is_boolean(piece["title_in_body"]) and
          (is_nil(piece["title_line"]) or
             (is_integer(piece["title_line"]) and piece["title_line"] > 0)) and
          piece["title_source"] in ["first_line", "explicit"] and
          (piece["title_source"] != "explicit" or is_integer(piece["title_line"])) and
          is_binary(piece["body_sha256"]) and
          byte_size(piece["body_sha256"]) == 64 and is_binary(piece["source_token"]) and
          valid_time?(piece["source_updated_at"])
      end)
  rescue
    _ -> false
  end

  defp snapshot_write(%{scope: scope}, snapshot) do
    stored =
      Map.update!(snapshot, :pieces, fn pieces ->
        Enum.map(pieces, fn piece -> Map.put(piece, :body_sha256, digest(piece.body)) end)
      end)

    bytes = Jason.encode!(stringify(stored))

    attrs = %{
      scope: scope,
      kind: "snapshot",
      record_key: snapshot.id,
      data: %{"packet_id" => snapshot.packet_id},
      bytes: bytes
    }

    case %LocalRecord{} |> LocalRecord.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> {:ok, digest(bytes)}
      {:error, _} -> {:error, "Could not preserve the exact submitted manuscript words."}
    end
  end

  defp attach_snapshot(%{snapshot_ref: nil} = p, _d), do: {:ok, p}

  defp attach_snapshot(p, %{scope: scope}) do
    row =
      if uuid_value?(p.snapshot_ref),
        do:
          Repo.get_by(LocalRecord,
            scope: scope,
            kind: "snapshot",
            record_key: p.snapshot_ref
          )

    attach_snapshot_row(p, %{scope: scope}, row)
  end

  defp attach_snapshot_row(%{snapshot_ref: nil} = p, _d, _row), do: {:ok, p}

  defp attach_snapshot_row(p, _d, %LocalRecord{bytes: bytes}) when is_binary(bytes) do
    with true <- uuid_value?(p.snapshot_ref),
         true <- digest(bytes) == p.snapshot_digest,
         {:ok, raw} when is_map(raw) <- Jason.decode(bytes),
         true <- valid_snapshot?(raw, p),
         true <- valid_lifecycle_snapshot?(p, raw) do
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

      pieces =
        Enum.map(raw["pieces"], fn piece ->
          body = piece["body"]

          if is_binary(body) and digest(body) == piece["body_sha256"],
            do:
              atomize(piece, [
                :id,
                :title,
                :body,
                :title_in_body,
                :title_line,
                :title_source,
                :source_token,
                :source_updated_at
              ]),
            else: raise("snapshot body digest mismatch")
        end)

      {:ok, Map.put(p, :snapshot, Map.put(snap, :pieces, pieces))}
    else
      _ -> {:error, "The immutable sent-text snapshot is missing, invalid, or mismatched."}
    end
  rescue
    _ -> {:error, "The immutable sent-text snapshot is missing, invalid, or mismatched."}
  end

  defp attach_snapshot_row(_, _, _),
    do: {:error, "The immutable sent-text snapshot is missing, invalid, or mismatched."}

  defp attach_snapshots(packets, %{scope: scope} = d) do
    refs = packets |> Enum.map(& &1.snapshot_ref) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    rows =
      if refs == [],
        do: [],
        else:
          Repo.all(
            from(r in LocalRecord,
              where: r.scope == ^scope and r.kind == "snapshot" and r.record_key in ^refs
            )
          )

    by_ref = Map.new(rows, &{&1.record_key, &1})

    Enum.reduce_while(packets, {:ok, []}, fn p, {:ok, acc} ->
      case attach_snapshot_row(p, d, Map.get(by_ref, p.snapshot_ref)) do
        {:ok, attached} -> {:cont, {:ok, [attached | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attached} -> {:ok, Enum.reverse(attached)}
      error -> error
    end
  end

  defp attach_revision_counts(scope, pieces) do
    ids = Enum.map(pieces, & &1.id)

    counts =
      if ids == [] do
        %{}
      else
        Repo.all(
          from(e in Entry,
            left_join: v in Version,
            on: v.entry_id == e.id,
            where: e.collection_scope == ^scope and e.file_id in ^ids,
            group_by: e.file_id,
            select: {e.file_id, count(v.id)}
          )
        )
        |> Map.new()
      end

    Enum.map(pieces, &Map.put(&1, :revision_count, Map.get(counts, &1.id, 0)))
  end

  defp journals_for_packets(packets, d) do
    ids = packets |> Enum.map(& &1.journal_id) |> Enum.uniq()

    with {:ok, journals} <- records(d, :journal),
         do: {:ok, Enum.filter(journals, &(&1.id in ids))}
  end

  defp records(%{scope: scope}, kind) do
    rows =
      Repo.all(
        from(r in LocalRecord,
          where: r.scope == ^scope and r.kind == ^Atom.to_string(kind),
          order_by: r.record_key
        )
      )

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case decode_record(row, kind) do
        {:ok, rec} ->
          {:cont, {:ok, [rec | acc]}}

        _ ->
          {:halt,
           {:error, "A correspondence record is malformed or does not match its database key."}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp read_record(%{scope: scope}, id, kind) do
    if uuid_value?(id) do
      case Repo.get_by(LocalRecord, scope: scope, kind: Atom.to_string(kind), record_key: id) do
        nil -> {:error, "No #{kind} with that identifier exists."}
        row -> decode_record(row, kind)
      end
    else
      {:error, "The #{kind} identifier is invalid."}
    end
  end

  defp decode_record(row, kind) do
    raw = if is_map(row.data), do: stringify(row.data), else: %{}

    if is_map(row.data) and raw["id"] == row.record_key do
      with {:ok, rec} <- decode(raw, kind),
           do: {:ok, Map.put(rec, :token, digest(Jason.encode!(raw)))}
    else
      {:error, :invalid}
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

  defp write_record(%{scope: scope}, rec, kind, expected_token) do
    key = Atom.to_string(kind)

    result =
      try do
        Repo.transaction(fn ->
          ensure_current_scope!(scope)

          current =
            Repo.one(
              from(r in LocalRecord,
                where: r.scope == ^scope and r.kind == ^key and r.record_key == ^rec.id
              )
            )

          cond do
            is_nil(current) and not is_nil(expected_token) ->
              Repo.rollback({:error, "Reopen this record before saving your changes."})

            not is_nil(current) and
                (is_nil(expected_token) or
                   decode_record(current, kind) |> token_matches?(expected_token) == false) ->
              Repo.rollback({:error, "This record changed on disk. Reopen it before continuing."})

            true ->
              :ok
          end

          case unique_name(%{scope: scope}, Map.get(rec, :name), rec.id) do
            :ok -> :ok
            {:error, message} -> Repo.rollback({:error, message})
          end

          case writable_destination(%{scope: scope}, rec, kind) do
            :ok -> :ok
            {:error, message} -> Repo.rollback({:error, message})
          end

          if current do
            rev_attrs = %{
              scope: scope,
              kind: "revision",
              record_key: "#{key}:#{rec.id}:#{current.lock_version}",
              data: stringify(current.data),
              bytes: current.bytes
            }

            Repo.insert!(LocalRecord.changeset(%LocalRecord{}, rev_attrs))
          end

          attrs = %{
            scope: scope,
            kind: key,
            record_key: rec.id,
            data: stringify(rec),
            lock_version: (current && current.lock_version + 1) || 1
          }

          saved =
            if current,
              do: current |> LocalRecord.changeset(attrs) |> Repo.update!(),
              else: %LocalRecord{} |> LocalRecord.changeset(attrs) |> Repo.insert!()

          case decode_record(saved, kind) do
            {:ok, result} -> result
            _ -> Repo.rollback({:error, "Could not verify the saved Correspondence record."})
          end
        end)
      rescue
        _ -> {:error, :concurrent_write}
      end

    case result do
      {:ok, saved} ->
        {:ok, saved}

      {:error, {:error, message}} ->
        {:error, message}

      {:error, :concurrent_write} ->
        {:error, "This record changed on disk. Reopen it before continuing."}

      {:error, reason} ->
        {:error, explain(reason)}
    end
  end

  defp token_matches?({:ok, %{token: token}}, expected), do: token == expected
  defp token_matches?(_, _), do: false

  defp writable_destination(%{scope: scope}, %{status: status, journal_id: id}, :packet)
       when status in ["preparing", "submitted"] do
    with {:ok, journal} <- read_record(%{scope: scope}, id, :journal),
         do: active_destination(journal)
  end

  defp writable_destination(_, _, _), do: :ok

  defp write_desk(location, piece_id, expected_token) do
    with {:ok, d} <- write_store(location),
         {:ok, current} <- desk_for_scope(d),
         :ok <- desk_fresh(current, expected_token),
         :ok <- validate_desk_piece(location, piece_id) do
      record = %{
        "format" => @desk_format,
        "version" => @desk_version,
        "piece_id" => piece_id,
        "updated_at" => now()
      }

      result =
        try do
          Repo.transaction(fn ->
            ensure_current_scope!(d.scope)
            existing = Repo.get_by(LocalRecord, scope: d.scope, kind: "desk", record_key: "desk")

            actual_token =
              if existing, do: digest(Jason.encode!(stringify(existing.data || %{}))), else: nil

            if actual_token != expected_token,
              do:
                Repo.rollback(
                  {:error,
                   "The Correspondence desk changed since it was opened. Reopen it before retrying."}
                )

            if existing do
              Repo.insert!(
                LocalRecord.changeset(%LocalRecord{}, %{
                  scope: d.scope,
                  kind: "revision",
                  record_key: "desk:desk:#{existing.lock_version}",
                  data: stringify(existing.data || %{}),
                  bytes: existing.bytes
                })
              )
            end

            attrs = %{
              scope: d.scope,
              kind: "desk",
              record_key: "desk",
              data: record,
              lock_version: (existing && existing.lock_version + 1) || 1
            }

            if existing,
              do: existing |> LocalRecord.changeset(attrs) |> Repo.update!(),
              else: %LocalRecord{} |> LocalRecord.changeset(attrs) |> Repo.insert!()

            {:ok, value} = desk_for_scope(%{scope: d.scope})
            value
          end)
        rescue
          _ -> {:error, :concurrent_write}
        end

      case result do
        {:ok, saved} ->
          {:ok, saved}

        {:error, {:error, message}} ->
          {:error, message}

        {:error, :concurrent_write} ->
          {:error,
           "The Correspondence desk changed since it was opened. Reopen it before retrying."}

        {:error, reason} ->
          {:error, explain(reason)}
      end
    end
  end

  defp desk_for_scope(%{scope: scope}) do
    case Repo.get_by(LocalRecord, scope: scope, kind: "desk", record_key: "desk") do
      nil ->
        {:ok, empty_desk()}

      row ->
        data = row.data || %{}

        if is_map(data) and data["format"] == @desk_format and data["version"] == @desk_version and
             (is_nil(data["piece_id"]) or uuid_value?(data["piece_id"])) and
             valid_time?(data["updated_at"]) do
          {:ok,
           %{
             piece_id: data["piece_id"],
             token: digest(Jason.encode!(data)),
             updated_at: data["updated_at"]
           }}
        else
          {:error, "The Correspondence desk record is malformed."}
        end
    end
  end

  defp desk_fresh(%{token: token}, token) when is_binary(token), do: :ok
  defp desk_fresh(%{token: nil}, nil), do: :ok

  defp desk_fresh(_, _),
    do:
      {:error, "The Correspondence desk changed since it was opened. Reopen it before retrying."}

  defp validate_desk_piece(_location, nil), do: :ok

  defp validate_desk_piece(location, piece_id) do
    case Poems.get(location, piece_id) do
      {:ok, _piece} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp empty_desk, do: %{piece_id: nil, token: nil, updated_at: nil}

  defp ensure_current_scope!(scope) do
    active = Storage.collection_location()

    if active.available and active.scope == scope,
      do: :ok,
      else:
        Repo.rollback(
          {:error, "The active collection changed. Reopen Correspondence before continuing."}
        )
  end

  defp existing(_db, id, nil, _kind) when is_binary(id),
    do: {:error, "Reopen this record before saving your changes."}

  defp existing(_db, nil, token, _kind) when not is_nil(token),
    do: {:error, "The new record revision is invalid."}

  defp existing(_db, nil, nil, _kind), do: {:ok, nil}

  defp existing(db, id, token, kind) when is_binary(id) and is_binary(token) do
    with {:ok, r} <- read_record(db, id, kind), :ok <- fresh(r, token), do: {:ok, r}
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

  defp unique_name(%{scope: scope}, name, id) when is_binary(name) do
    case records(%{scope: scope}, :journal) do
      {:ok, js} ->
        if Enum.any?(js, &(String.downcase(&1.name) == String.downcase(name) and &1.id != id)),
          do: {:error, "A journal with this name already exists."},
          else: :ok

      error ->
        error
    end
  end

  defp unique_name(_, _, _), do: :ok

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
    with {:ok, active} <- active_location(location), do: {:ok, %{scope: active.scope}}
  end

  defp write_store(location), do: store(location)

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

      true ->
        {:ok, active}
    end
  end

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

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp invalid(s), do: {:error, "The #{s} data is invalid."}
  defp explain(e) when is_binary(e), do: e
  defp explain(e) when is_atom(e), do: :file.format_error(e) |> List.to_string()
  defp explain(e), do: inspect(e)
end

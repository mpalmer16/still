defmodule Still.Writing do
  @moduledoc "The small, durable boundary around a person's writing."

  import Ecto.Query
  alias Ecto.Changeset
  alias Still.Repo

  alias Still.Writing.{
    Connections,
    Entry,
    Geography,
    Gravity,
    ListInterpretation,
    Notebooks,
    RoomState,
    Search,
    ReadingPath,
    Version
  }

  @snapshot_interval 15 * 60

  def new_entry, do: %Entry{}
  def change_entry(entry, attrs \\ %{}), do: Entry.changeset(entry, attrs)
  def get_entry(id), do: Repo.get(Entry, id)
  def get_entry!(id), do: Repo.get!(Entry, id)

  @doc "Adds an explicit editable saved version; never updates the historical database entry."
  def add_to_saved_writing(location, id) do
    case get_entry(id) do
      nil -> {:error, "This historical List is no longer available."}
      entry -> Still.Poems.from_historical(location, entry)
    end
  end

  def list_entry?(%Entry{origin: "before"}), do: true
  def list_entry?(%Entry{source: %{"writing_form" => "list"}}), do: true
  def list_entry?(_entry), do: false

  def list_interpretation(body), do: ListInterpretation.propose(body)

  @doc "Accept an opening as a title, keeping the complete text as earlier words atomically."
  def accept_list_title(entry, body, opts \\ []) when is_binary(body) do
    cond do
      present_title?(Keyword.get(opts, :title)) or present_title?(entry && entry.title) ->
        {:error, :title_already_set}

      interpretation = list_interpretation(body) ->
        Repo.transaction(fn ->
          # The textarea may contain words which have not reached autosave yet.
          # Save those exact words before checkpointing the interpretation, also
          # when this is the first save of a new page.
          raw =
            entry
            |> save_entry(body, Keyword.merge(opts, writing_form: "list", checkpoint: true))
            |> interpretation_save!()

          raw
          |> save_entry(interpretation.body,
            title: interpretation.title,
            writing_form: "list",
            checkpoint: true
          )
          |> interpretation_save!()
        end)

      true ->
        {:error, :no_title_suggestion}
    end
  end

  defp interpretation_save!({:ok, entry}), do: entry
  defp interpretation_save!({:error, reason}), do: Repo.rollback(reason)
  defp present_title?(title), do: is_binary(title) and String.trim(title) != ""

  def save_entry(entry, body, opts \\ [])

  def save_entry(nil, body, opts) when is_binary(body) do
    with {:ok, attrs} <- writing_attrs(nil, body, opts) do
      %Entry{}
      |> Entry.changeset(Map.put(attrs, :beside_id, Keyword.get(opts, :beside_id)))
      |> Repo.insert()
    end
  end

  def save_entry(%Entry{} = seen, body, opts) when is_binary(body) do
    with {:ok, attrs} <- writing_attrs(seen, body, opts) do
      changeset = Entry.changeset(seen, attrs)

      if changeset.valid? and map_size(changeset.changes) == 0 do
        case Repo.get(Entry, seen.id) do
          nil ->
            {:error, :missing}

          %{lock_version: version} = current when version != seen.lock_version ->
            {:error, {:stale, current}}

          current ->
            {:ok, current}
        end
      else
        if changeset.valid? do
          Repo.transaction(fn ->
            case Repo.get(Entry, seen.id) do
              nil ->
                Repo.rollback(:missing)

              %{lock_version: version} = current when version != seen.lock_version ->
                Repo.rollback({:stale, current})

              current ->
                if snapshot_due?(current, opts) do
                  Repo.insert!(%Version{
                    entry_id: current.id,
                    title: current.title,
                    body: current.body
                  })
                end

                current
                |> Entry.changeset(attrs)
                |> mark_returned(current)
                |> Changeset.optimistic_lock(:lock_version)
                |> Repo.update!()
            end
          end)
        else
          {:error, changeset}
        end
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, {:stale, get_entry(seen.id)}}
  end

  defp writing_attrs(entry, body, opts) do
    attrs = %{body: body, title: Keyword.get(opts, :title, entry && entry.title)}

    case Keyword.fetch(opts, :writing_form) do
      :error ->
        {:ok, attrs}

      {:ok, "list"} ->
        source = if entry, do: entry.source || %{}, else: %{}
        {:ok, Map.put(attrs, :source, Map.put(source, "writing_form", "list"))}

      _ ->
        {:error, :invalid_writing_form}
    end
  end

  defp mark_returned(changeset, %Entry{origin: "before", returned_at: nil}) do
    Changeset.put_change(changeset, :returned_at, DateTime.utc_now())
  end

  defp mark_returned(changeset, _entry), do: changeset

  @doc "Bring a local Lists manifest into Still once, leaving living edits alone on repeats."
  def import_lists(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"format" => "still-lists-1", "entries" => entries}} when is_list(entries) <-
           Jason.decode(bytes) do
      Repo.transaction(fn ->
        entries
        |> Enum.with_index(1)
        |> Enum.reduce(%{inserted: 0, skipped: 0}, fn {source, position}, counts ->
          import_entry(source, position, counts)
        end)
      end)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_manifest}
    end
  end

  defp import_entry(%{"source_key" => key} = source, position, counts)
       when is_binary(key) and byte_size(key) > 0 do
    if Repo.get_by(Entry, source_key: key) do
      %{counts | skipped: counts.skipped + 1}
    else
      attrs =
        source
        |> Map.take(~w(title body source_key source_group notebook source_order source))
        |> Map.put("origin", "before")

      case %Entry{} |> Entry.changeset(attrs) |> Repo.insert() do
        {:ok, _entry} -> %{counts | inserted: counts.inserted + 1}
        {:error, changeset} -> Repo.rollback({:invalid_entry, position, changeset})
      end
    end
  end

  defp import_entry(_source, position, _counts),
    do: Repo.rollback({:invalid_entry, position, :missing_source_key})

  defp snapshot_due?(entry, opts) do
    if Keyword.get(opts, :checkpoint, false) do
      true
    else
      latest =
        Repo.one(
          from v in Version,
            where: v.entry_id == ^entry.id,
            order_by: [desc: v.inserted_at, desc: v.id],
            limit: 1
        )

      is_nil(latest) or
        DateTime.diff(DateTime.utc_now(), latest.inserted_at) >= @snapshot_interval
    end
  end

  def list_entries(opts \\ []), do: Search.entries(opts)
  def find_entries(opts \\ []), do: Search.find(opts)
  def search_passage(body, query), do: Search.passage(body, query)
  def search_query(value), do: Search.query(value)
  def notebook_neighbors(entry), do: Notebooks.neighbors(entry)
  def remember_reading(entry, opts \\ []), do: ReadingPath.visit(entry, opts)
  def previous_reading(entry, version \\ nil), do: ReadingPath.previous(entry, version)
  def back_reading(entry, version \\ nil), do: ReadingPath.back(entry, version)

  def get_version(entry, id) when is_binary(id) do
    with {number, ""} <- Integer.parse(id),
         true <- number > 0 && number <= 9_223_372_036_854_775_807 do
      Repo.get_by(Version, id: number, entry_id: entry.id)
    else
      _ -> nil
    end
  end

  def get_version(_, _), do: nil

  def list_versions(%Entry{id: id}) do
    Repo.all(from v in Version, where: v.entry_id == ^id, order_by: [desc: v.inserted_at])
  end

  def export_entries do
    Repo.all(from e in Entry, order_by: [asc: e.inserted_at, asc: e.id], preload: :versions)
  end

  def restore_version(%Entry{} = entry, version_id) do
    case Repo.get_by(Version, id: version_id, entry_id: entry.id) do
      nil -> {:error, :missing}
      version -> save_entry(entry, version.body, title: version.title, checkpoint: true)
    end
  end

  def before_entry(opts \\ []) do
    excluded = Keyword.get(opts, :exclude_ids, [])

    query = from e in Entry, where: e.origin == "before" and e.id not in ^excluded

    query =
      case Keyword.get(opts, :exclude_notebook) do
        nil -> query
        notebook -> where(query, [e], is_nil(e.notebook) or e.notebook != ^notebook)
      end

    Repo.one(from e in query, order_by: fragment("RANDOM()"), limit: 1)
  end

  def source_siblings(entry), do: Connections.source_siblings(entry)
  def wander_entry(opts \\ []), do: Connections.wander_entry(opts)
  def nearby(entry), do: Connections.nearby(entry)
  def echo(entry), do: Connections.echo(entry)
  def saved_echo(piece), do: Gravity.saved_echo(piece)
  def historical_source_ids(piece), do: Gravity.historical_source_ids(piece)

  def saved_field(piece, passage \\ nil, opts \\ []),
    do: Gravity.saved_field(piece, passage, opts)

  def connections(entry), do: Connections.for_entry(entry)
  def gravity(body, opts \\ []), do: Gravity.draw(body, opts)
  def gravity_field(body, opts \\ []), do: Gravity.field(body, opts)

  @doc "Original source-file number, only when preserved artifact filenames agree. Never an inferred date or position."
  def source_number(%{origin: "before", source: source}) when is_map(source) do
    artifacts = source["artifacts"]

    numbers =
      if(is_list(artifacts), do: artifacts, else: [])
      |> Enum.flat_map(fn
        %{"path" => path} when is_binary(path) ->
          case Regex.run(~r/^(\d+)/, Path.basename(path)) do
            [_, number] -> [number]
            _ -> []
          end

        _ ->
          []
      end)
      |> Enum.uniq()

    case numbers do
      [number] -> number
      _ -> nil
    end
  end

  def source_number(_), do: nil

  def geography(entry), do: Geography.for_entry(entry)
  def places, do: Geography.places()
  def notebooks, do: Notebooks.all()
  def notebook(key), do: Notebooks.get(key)
  def place_distance(left, right), do: Geography.distance(left, right)

  def room_light do
    case Repo.get(RoomState, 1) do
      nil -> 38
      state -> state.light
    end
  end

  def set_room_light(light) when is_integer(light) do
    light = light |> max(0) |> min(360)

    case Repo.insert(%RoomState{id: 1, light: light},
           on_conflict: [set: [light: light]],
           conflict_target: :id
         ) do
      {:ok, _state} -> {:ok, light}
      error -> error
    end
  end

  def set_room_light(_light), do: {:error, :invalid_light}

  def room_letters do
    case Repo.get(RoomState, 1) do
      nil -> 50
      state -> state.letters
    end
  end

  def set_room_letters(letters) when is_integer(letters) do
    letters = letters |> max(0) |> min(100)

    case Repo.insert(%RoomState{id: 1, letters: letters},
           on_conflict: [set: [letters: letters]],
           conflict_target: :id
         ) do
      {:ok, _state} -> {:ok, letters}
      error -> error
    end
  end

  def set_room_letters(_letters), do: {:error, :invalid_letters}

  def current_writing do
    with %RoomState{writing_id: id} when is_integer(id) <- Repo.get(RoomState, 1),
         %Entry{origin: "now"} = entry <- Repo.get(Entry, id) do
      entry
    else
      _ -> nil
    end
  end

  def remember_writing(%Entry{origin: "now", id: id}) when is_integer(id) do
    recent = room_recent() |> Map.delete("draft_form")

    Repo.insert(%RoomState{id: 1, writing_id: id, recent: recent},
      on_conflict: [set: [writing_id: id, draft_beside_id: nil, recent: recent]],
      conflict_target: :id
    )
  end

  def remember_writing(_entry), do: {:error, :not_now}

  def current_beside do
    with %RoomState{writing_id: nil, draft_beside_id: id} when is_integer(id) <-
           Repo.get(RoomState, 1) do
      Repo.get(Entry, id)
    else
      _ -> nil
    end
  end

  def current_list_draft? do
    match?(%RoomState{writing_id: nil, recent: %{"draft_form" => "list"}}, Repo.get(RoomState, 1))
  end

  @doc "Return to a fresh local draft without creating an empty writing or a visit log."
  def begin_writing(beside \\ nil, opts \\ [])
  def begin_writing(nil, opts), do: remember_draft_space(nil, opts)

  def begin_writing(%Entry{id: id}, opts) when is_integer(id) do
    if Repo.exists?(from e in Entry, where: e.id == ^id),
      do: remember_draft_space(id, opts),
      else: {:error, :missing_beside}
  end

  def begin_writing(_beside, _opts), do: {:error, :invalid_beside}

  defp remember_draft_space(beside_id, opts) do
    with {:ok, recent} <- draft_recent(opts) do
      Repo.insert(%RoomState{id: 1, draft_beside_id: beside_id, recent: recent},
        on_conflict: [set: [writing_id: nil, draft_beside_id: beside_id, recent: recent]],
        conflict_target: :id
      )
    end
  rescue
    # SQLite reports foreign keys without a constraint name. This insert's only
    # populated relationship is the requested source, which may disappear after
    # the context checked that it exists.
    error in Ecto.ConstraintError ->
      if error.type == :foreign_key,
        do: {:error, :missing_beside},
        else: reraise(error, __STACKTRACE__)
  end

  defp draft_recent(opts) do
    recent = room_recent()

    case Keyword.fetch(opts, :writing_form) do
      :error -> {:ok, Map.delete(recent, "draft_form")}
      {:ok, "list"} -> {:ok, Map.put(recent, "draft_form", "list")}
      _ -> {:error, :invalid_writing_form}
    end
  end

  defp room_recent do
    case Repo.get(RoomState, 1) do
      nil -> %{}
      state -> state.recent || %{}
    end
  end

  def companions(%Entry{id: id, beside_id: parent_id}) do
    parent_ids = List.wrap(parent_id)

    Repo.all(
      from e in Entry,
        where: e.beside_id == ^id or e.id in ^parent_ids,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  @doc "Remember a small recent path through the room, without recording a visit log."
  def remember_visit(%Entry{id: id}) when is_integer(id) do
    recent = room_recent()
    ids = [id | Enum.reject(Map.get(recent, "ids", []), &(&1 == id))] |> Enum.take(16)
    recent = Map.put(recent, "ids", ids)

    Repo.insert(%RoomState{id: 1, recent: recent},
      on_conflict: [set: [recent: recent]],
      conflict_target: :id
    )
  end

  def last_visited, do: recent_entries(limit: 1) |> List.first()

  def recent_entries(opts \\ []) do
    case Repo.get(RoomState, 1) do
      nil ->
        []

      state ->
        ids = Map.get(state.recent, "ids", []) |> Enum.take(Keyword.get(opts, :limit, 8))
        entries = Repo.all(from e in Entry, where: e.id in ^ids) |> Map.new(&{&1.id, &1})
        Enum.flat_map(ids, fn id -> if entry = entries[id], do: [entry], else: [] end)
    end
  end

  def remember_one(today \\ Date.utc_today()) do
    before = from e in Entry, where: e.origin == "before"

    case Repo.aggregate(before, :count) do
      0 ->
        remember_older_now(today)

      count ->
        index = rem(:erlang.phash2(Date.to_iso8601(today)), count)

        Repo.one(
          from e in before,
            order_by: [asc: e.notebook, asc: e.source_order, asc: e.id],
            offset: ^index,
            limit: 1
        )
    end
  end

  defp remember_older_now(today) do
    cutoff = DateTime.utc_now() |> DateTime.add(-28, :day)

    older = from e in Entry, where: e.origin == "now" and e.inserted_at < ^cutoff

    case Repo.aggregate(older, :count) do
      0 ->
        nil

      count ->
        index = rem(:erlang.phash2(Date.to_iso8601(today)), count)

        Repo.one(
          from e in older, order_by: [asc: e.inserted_at, asc: e.id], offset: ^index, limit: 1
        )
    end
  end

  def opening(%Entry{title: title}) when is_binary(title) and title != "", do: title

  def opening(%Entry{body: body}) do
    line =
      body
      |> String.split("\n")
      |> Enum.find("Untitled", &(String.trim(&1) != ""))
      |> String.trim()

    if String.length(line) > 120, do: String.slice(line, 0, 119) <> "…", else: line
  end

  def continuation(%Entry{body: body}) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.drop(1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> String.slice(text, 0, 220)
    end
  end

  def excerpt(%Entry{body: body}) do
    body |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 240)
  end
end

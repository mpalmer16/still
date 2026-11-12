defmodule Still.Correspondence.Calendar do
  @moduledoc "Collection-scoped local calendar events for Correspondence."
  alias Still.{LocalRecord, Repo, Storage}
  alias Still.Writing.CollectionLock
  import Ecto.Query

  @kind "calendar_event"
  @fields ~w(external_id title date start_time end_time end_date timezone venue address url notes category status recurrence hidden hidden_dates)

  def list(location) do
    with {:ok, scope} <- active_scope(location) do
      rows = Repo.all(from r in LocalRecord, where: r.scope == ^scope and r.kind == @kind)
      events = Enum.map(rows, &decode/1)

      if Enum.any?(events, &match?({:error, _}, &1)),
        do: {:error, "A saved calendar event is malformed."},
        else:
          {:ok,
           events
           |> Enum.map(fn {:ok, e} -> e end)
           |> Enum.sort_by(&{&1.date, Map.get(&1, :start_time) || "", &1.title})}
    end
  end

  @doc "Returns the earliest visible calendar occurrences, including events already in progress."
  def upcoming(location, today, limit \\ 4)

  def upcoming(location, %Date{} = today, limit)
      when is_integer(limit) and limit in 1..10 do
    with {:ok, events} <- list(location) do
      last = Date.add(today, 366)

      in_window = Still.Correspondence.Recurrence.occurrences(events, today, last)

      beyond_window =
        events
        |> Enum.filter(fn event ->
          is_nil(event.recurrence) and Date.compare(Date.from_iso8601!(event.date), last) == :gt
        end)
        |> Enum.flat_map(fn event ->
          date = Date.from_iso8601!(event.date)
          Still.Correspondence.Recurrence.occurrences([event], date, date)
        end)

      visible =
        (in_window ++ beyond_window)
        |> Enum.reject(&(&1.hidden or &1.status == "cancelled"))
        |> Enum.sort_by(&{&1.date, &1.start_time || "", &1.title, &1.id})
        |> Enum.take(limit)

      {:ok, visible}
    end
  end

  def upcoming(_location, _today, _limit),
    do: {:error, "Choose a date and a limit between 1 and 10."}

  def get(location, id) when is_binary(id) do
    with {:ok, scope} <- active_scope(location),
         %LocalRecord{} = row <-
           Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id),
         {:ok, event} <- decode(row) do
      {:ok, event}
    else
      nil -> {:error, "This calendar event is no longer available."}
      error -> error
    end
  end

  def get(_, _), do: {:error, "Reopen this calendar event before continuing."}

  def set_hidden(location, id, expected_token, hidden, date \\ nil)

  def set_hidden(location, id, expected_token, hidden, date)
      when is_binary(id) and is_binary(expected_token) and is_boolean(hidden) do
    with {:ok, scope} <- active_scope(location),
         true <- is_nil(date) or valid_date(date) do
      CollectionLock.with_lock(Repo.config()[:database], fn ->
        result =
          Repo.transaction(fn ->
            ensure_scope!(scope, location)
            row = Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id)

            if is_nil(row) or token(row) != expected_token,
              do:
                Repo.rollback(
                  {:error, "This calendar event changed. Reopen it before continuing."}
                )

            {:ok, event} = decode(row)

            data =
              if date do
                dates = event.hidden_dates
                dates = if hidden, do: Enum.uniq([date | dates]), else: List.delete(dates, date)
                Map.put(row.data, "hidden_dates", Enum.sort(dates))
              else
                Map.put(row.data, "hidden", hidden)
              end

            unchanged? =
              if date,
                do: data["hidden_dates"] == event.hidden_dates,
                else: event.hidden == hidden

            if unchanged? do
              event
            else
              preserve_revision!(row)

              saved =
                row
                |> LocalRecord.changeset(%{data: data, lock_version: row.lock_version + 1})
                |> Repo.update!()

              {:ok, value} = decode(saved)
              value
            end
          end)

        transaction_result(result)
      end)
    else
      {:error, message} -> {:error, message}
      false -> {:error, "Choose a valid event date."}
    end
  end

  def set_hidden(_, _, _, _, _), do: {:error, "Reopen this calendar event before continuing."}

  def save(location, attrs, id \\ nil, token \\ nil) do
    with {:ok, attrs} <- validate(attrs),
         {:ok, scope} <- active_scope(location) do
      CollectionLock.with_lock(Repo.config()[:database], fn ->
        Repo.transaction(fn ->
          ensure_scope!(scope, location)

          current =
            if is_binary(id),
              do: Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id)

          expected = if current, do: token(current), else: nil

          if expected != token,
            do: Repo.rollback({:error, "This calendar event changed. Reopen it before saving."})

          if is_nil(current) and id,
            do: Repo.rollback({:error, "This calendar event is no longer available."})

          existing = Repo.all(from r in LocalRecord, where: r.scope == ^scope and r.kind == @kind)
          decoded = Enum.map(existing, &decode/1)

          if Enum.any?(decoded, &match?({:error, _}, &1)),
            do:
              Repo.rollback(
                {:error, "A saved calendar event is malformed. Resolve it before saving."}
              )

          duplicate_external_id? =
            Enum.zip(existing, decoded)
            |> Enum.any?(fn {row, decoded_event} ->
              row.record_key != (current && current.record_key) and
                case decoded_event do
                  {:ok, event} -> event.external_id == attrs["external_id"]
                  _ -> false
                end
            end)

          if duplicate_external_id?,
            do: Repo.rollback({:error, "An event with this external_id already exists."})

          rid = (current && current.record_key) || Ecto.UUID.generate()

          local_state =
            if current, do: Map.take(current.data, ["hidden", "hidden_dates"]), else: %{}

          data = attrs |> Map.merge(local_state) |> Map.put("id", rid)

          if current && current.data == data do
            {:ok, event} = decode(current)
            Repo.rollback({:ok, event})
          end

          if current, do: preserve_revision!(current)

          row_attrs = %{
            scope: scope,
            kind: @kind,
            record_key: rid,
            data: data,
            lock_version: (current && current.lock_version + 1) || 1
          }

          saved =
            if current,
              do: current |> LocalRecord.changeset(row_attrs) |> Repo.update!(),
              else: %LocalRecord{} |> LocalRecord.changeset(row_attrs) |> Repo.insert!()

          {:ok, event} = decode(saved)
          event
        end)
      end)
      |> transaction_result()
    end
  end

  def validate(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    attrs =
      Enum.reduce(
        ~w(start_time end_time end_date timezone venue address url notes),
        attrs,
        fn key, acc -> if Map.get(acc, key) in ["", nil], do: Map.delete(acc, key), else: acc end
      )

    unknown = Map.keys(attrs) -- @fields

    cond do
      unknown != [] ->
        {:error, "Unsupported calendar fields: #{Enum.join(unknown, ", ")}."}

      Enum.any?(attrs, fn {key, v} ->
        key not in ["recurrence", "hidden", "hidden_dates"] and
            (not is_binary(v) or not String.valid?(v) or :binary.match(v, <<0>>) != :nomatch)
      end) ->
        {:error, "Calendar fields must be valid text strings."}

      Enum.any?(attrs, fn {key, v} ->
        key == "recurrence" and not (is_nil(v) or is_map(v))
      end) ->
        {:error, "recurrence must be an object or null."}

      Enum.any?(attrs, fn {key, v} ->
        key == "hidden" and not is_boolean(v)
      end) ->
        {:error, "hidden must be true or false."}

      Enum.any?(attrs, fn {key, v} ->
        key == "hidden_dates" and
            not (is_list(v) and Enum.all?(v, &valid_date/1))
      end) ->
        {:error, "hidden_dates must contain valid dates."}

      Enum.any?(attrs, fn {key, value} ->
        over_limit?(key, value)
      end) ->
        {:error, "Calendar text exceeds the allowed field length."}

      not nonempty(attrs["external_id"]) ->
        {:error, "external_id is required."}

      not nonempty(attrs["title"]) ->
        {:error, "title is required."}

      not valid_date(attrs["date"]) ->
        {:error, "date must use YYYY-MM-DD."}

      present(attrs, "start_time") and not valid_time(attrs["start_time"]) ->
        {:error, "start_time must use HH:MM."}

      present(attrs, "end_time") and
          (not present(attrs, "start_time") or not valid_time(attrs["end_time"])) ->
        {:error, "end_time requires start_time and must use HH:MM."}

      present(attrs, "end_date") and
          (not valid_date(attrs["end_date"]) or attrs["end_date"] < attrs["date"]) ->
        {:error, "end_date must be a valid date on or after date."}

      present(attrs, "end_date") and
          Date.diff(Date.from_iso8601!(attrs["end_date"]), Date.from_iso8601!(attrs["date"])) >
            366 ->
        {:error, "Calendar events may not span more than 366 days."}

      present(attrs, "end_time") and (attrs["end_date"] || attrs["date"]) == attrs["date"] and
          attrs["end_time"] < attrs["start_time"] ->
        {:error, "The event end must not be before its start."}

      Map.has_key?(attrs, "category") and
          attrs["category"] not in ~w(reading workshop deadline other) ->
        {:error, "category must be reading, workshop, deadline, or other."}

      Map.has_key?(attrs, "status") and attrs["status"] not in ~w(scheduled cancelled) ->
        {:error, "status must be scheduled or cancelled."}

      present(attrs, "url") and not valid_url?(attrs["url"]) ->
        {:error, "url must be a complete http:// or https:// address."}

      true ->
        with {:ok, recurrence} <- validate_recurrence(attrs["recurrence"], attrs["date"]) do
          {:ok,
           Map.merge(
             %{
               "status" => "scheduled",
               "category" => "other",
               "recurrence" => recurrence,
               "hidden" => false,
               "hidden_dates" => []
             },
             attrs
           )
           |> Map.put("recurrence", recurrence)}
        end
    end
  end

  def validate(_), do: {:error, "Each calendar event must be an object."}

  defp over_limit?(key, value) when is_binary(value) do
    limit =
      cond do
        key == "notes" -> 10_000
        key == "title" -> 300
        key == "external_id" -> 200
        key in ["recurrence", "hidden", "hidden_dates"] -> 100_000
        true -> 500
      end

    String.length(value) > limit
  end

  defp over_limit?(_, _), do: false

  defp validate_recurrence(value, date), do: Still.Correspondence.Recurrence.validate(value, date)

  def decode(%LocalRecord{data: data, lock_version: ver, record_key: record_key})
      when is_map(data) do
    id = data["id"]
    attrs = Map.take(data, @fields)

    with true <- is_binary(id),
         {:ok, _uuid} <- Ecto.UUID.cast(id),
         true <- id == record_key,
         true <- valid_date(data["date"]),
         {:ok, attrs} <- validate(attrs) do
      atom_attrs = Map.new(attrs, fn {key, value} -> {String.to_atom(key), value} end)

      {:ok,
       Map.merge(atom_attrs, %{
         id: id,
         token: token(%LocalRecord{data: data, lock_version: ver})
       })}
    else
      _ -> {:error, "A saved calendar event is malformed."}
    end
  end

  def decode(_), do: {:error, "A saved calendar event is malformed."}

  def token(%LocalRecord{data: data, lock_version: ver}),
    do:
      :crypto.hash(:sha256, Jason.encode!(%{"data" => data, "lock_version" => ver}))
      |> Base.encode16(case: :lower)

  def active_scope(location) do
    active = Storage.collection_location()
    scope = if is_map(location), do: location[:scope] || location["scope"], else: nil

    cond do
      not active.configured ->
        {:error, "Choose a collection folder before using Correspondence."}

      not active.available ->
        {:error, active.error || "The selected collection folder is unavailable."}

      scope != active.scope ->
        {:error, "The selected collection changed. Reopen Correspondence."}

      true ->
        {:ok, scope}
    end
  end

  def preserve_revision!(%LocalRecord{} = row) do
    Repo.insert!(
      LocalRecord.changeset(%LocalRecord{}, %{
        scope: row.scope,
        kind: "revision",
        record_key: "calendar_event:#{row.record_key}:#{row.lock_version}",
        data: row.data,
        bytes: row.bytes
      })
    )
  end

  defp ensure_scope!(scope, location) do
    case active_scope(location) do
      {:ok, ^scope} -> :ok
      {:error, message} -> Repo.rollback({:error, message})
      _ -> Repo.rollback({:error, "The selected collection changed. Reopen Correspondence."})
    end
  end

  defp valid_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(scheme) in ["http", "https"]

      _ ->
        false
    end
  rescue
    URI.Error -> false
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, {:ok, value}}), do: {:ok, value}
  defp transaction_result({:error, {:error, msg}}), do: {:error, msg}
  defp transaction_result({:error, msg}) when is_binary(msg), do: {:error, msg}
  defp transaction_result({:error, _}), do: {:error, "Could not save the calendar event."}
  defp present(attrs, key), do: Map.has_key?(attrs, key) and attrs[key] != ""
  defp nonempty(v), do: is_binary(v) and String.trim(v) != ""

  defp valid_date(v) when is_binary(v) do
    if Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, v) do
      case Date.from_iso8601(v) do
        {:ok, d} -> Date.to_iso8601(d) == v
        _ -> false
      end
    else
      false
    end
  end

  defp valid_date(_), do: false
  defp valid_time(v) when is_binary(v), do: Regex.match?(~r/^([01]\d|2[0-3]):[0-5]\d$/, v)
  defp valid_time(_), do: false
end

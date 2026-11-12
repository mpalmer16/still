defmodule Still.Correspondence.CalendarImport do
  @moduledoc "Reviewed JSON import for local Correspondence calendar events."
  alias Still.{LocalRecord, Repo}
  alias Still.Correspondence.Calendar
  alias Still.Writing.CollectionLock
  import Ecto.Query

  @max_bytes 1_048_576
  @max_events 200
  @import_fields ~w(external_id title date start_time end_time end_date timezone venue address url notes category status recurrence)

  def preview(location, bytes) do
    with {:ok, attrs} <- parse(bytes),
         {:ok, scope} <- Calendar.active_scope(location),
         rows <-
           Repo.all(
             from r in LocalRecord, where: r.scope == ^scope and r.kind == "calendar_event"
           ) do
      existing = Enum.map(rows, &Calendar.decode/1)

      with false <- Enum.any?(existing, &match?({:error, _}, &1)) do
        by_external = Map.new(existing, fn {:ok, event} -> {event.external_id, event} end)

        {new, updated, unchanged} =
          Enum.reduce(attrs, {[], [], []}, fn attr, {n, u, s} ->
            case Map.get(by_external, attr["external_id"]) do
              nil ->
                {[%{attrs: attr} | n], u, s}

              old ->
                old_attrs = import_attrs(old)

                if old_attrs == attr do
                  {n, u, [%{id: old.id, attrs: attr} | s]}
                else
                  {n,
                   [
                     %{
                       id: old.id,
                       token: old.token,
                       attrs: attr,
                       previous: import_attrs(old)
                     }
                     | u
                   ], s}
                end
            end
          end)

        {:ok,
         %{
           location: location,
           new: Enum.reverse(new),
           updated: Enum.reverse(updated),
           unchanged: Enum.reverse(unchanged)
         }}
      else
        _ -> {:error, "A saved calendar event is malformed."}
      end
    end
  end

  def commit(%{location: location, new: new, updated: updated, unchanged: unchanged}) do
    with {:ok, scope} <- Calendar.active_scope(location) do
      CollectionLock.with_lock(Repo.config()[:database], fn ->
        result =
          Repo.transaction(fn ->
            with {:ok, ^scope} <- Calendar.active_scope(location),
                 :ok <- validate_plan(new, updated, unchanged),
                 :ok <- unchanged_valid(scope, unchanged),
                 :ok <- updated_valid(scope, updated),
                 :ok <- new_valid(scope, new) do
              Enum.each(new, fn %{attrs: attrs} ->
                write(scope, Ecto.UUID.generate(), attrs, nil)
              end)

              Enum.each(updated, fn %{id: id, attrs: attrs} ->
                row =
                  Repo.get_by!(LocalRecord, scope: scope, kind: "calendar_event", record_key: id)

                write(scope, id, attrs, row)
              end)

              %{added: length(new), updated: length(updated), unchanged: length(unchanged)}
            else
              {:error, message} -> Repo.rollback({:error, message})
            end
          end)

        case result do
          {:ok, counts} -> {:ok, counts}
          {:error, {:error, message}} -> {:error, message}
          {:error, _} -> {:error, "The calendar changed during import. Review the file again."}
        end
      end)
    end
  end

  def commit(_), do: {:error, "Review this calendar import again before applying it."}

  def parse(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, rows} when is_list(rows) and length(rows) in 1..@max_events <- Jason.decode(bytes),
         {:ok, attrs} <- validate_rows(rows),
         :ok <- unique_external_ids(attrs) do
      {:ok, attrs}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Choose a JSON array with between 1 and #{@max_events} calendar events."}
    end
  end

  def parse(_), do: {:error, "Choose a JSON file no larger than 1 MB."}

  defp validate_rows(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      unknown = if is_map(row), do: Map.keys(row) -- @import_fields, else: []

      case if(unknown == [],
             do: Calendar.validate(row),
             else: {:error, "Unsupported fields: #{Enum.join(unknown, ", ")}."}
           ) do
        {:ok, attrs} -> {:cont, {:ok, [Map.take(attrs, @import_fields) | acc]}}
        {:error, reason} -> {:halt, {:error, "Event #{index}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, Enum.reverse(attrs)}
      error -> error
    end
  end

  defp unique_external_ids(attrs) do
    ids = Enum.map(attrs, & &1["external_id"])

    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, "Each external_id may appear only once in a file."}
  end

  defp validate_plan(new, updated, unchanged) do
    rows =
      Enum.map(new, & &1.attrs) ++
        Enum.map(updated, & &1.attrs) ++ Enum.map(unchanged, & &1.attrs)

    with {:ok, validated} <- validate_rows(rows),
         :ok <- unique_external_ids(validated),
         true <- validated == rows do
      :ok
    else
      _ -> {:error, "Review this calendar import again before applying it."}
    end
  end

  defp unchanged_valid(scope, rows) do
    if Enum.all?(rows, fn %{id: id, attrs: attrs} ->
         case Repo.get_by(LocalRecord, scope: scope, kind: "calendar_event", record_key: id) do
           nil ->
             false

           row ->
             case Calendar.decode(row) do
               {:ok, event} -> import_attrs(event) == attrs
               _ -> false
             end
         end
       end),
       do: :ok,
       else: {:error, "An unchanged event changed after preview. Review the import again."}
  end

  defp updated_valid(scope, rows) do
    if Enum.all?(rows, fn %{id: id, token: expected} ->
         case Repo.get_by(LocalRecord, scope: scope, kind: "calendar_event", record_key: id) do
           %LocalRecord{} = row -> Calendar.token(row) == expected
           _ -> false
         end
       end), do: :ok, else: {:error, "An event changed after preview. Review the import again."}
  end

  defp new_valid(scope, rows) do
    existing =
      Repo.all(from r in LocalRecord, where: r.scope == ^scope and r.kind == "calendar_event")

    decoded = Enum.map(existing, &Calendar.decode/1)

    if Enum.any?(decoded, &match?({:error, _}, &1)) do
      {:error, "A saved calendar event is malformed. Resolve it before importing."}
    else
      ids = Enum.map(decoded, fn {:ok, e} -> e.external_id end)
      incoming = Enum.map(rows, & &1.attrs["external_id"])

      if Enum.all?(incoming, &(&1 not in ids)),
        do: :ok,
        else: {:error, "A new event now exists. Review the import again."}
    end
  end

  defp write(scope, id, attrs, nil) do
    Repo.insert!(
      LocalRecord.changeset(%LocalRecord{}, %{
        scope: scope,
        kind: "calendar_event",
        record_key: id,
        data: Map.put(attrs, "id", id),
        lock_version: 1
      })
    )
  end

  defp write(scope, id, attrs, row) do
    state = Map.take(row.data, ["hidden", "hidden_dates"])
    Calendar.preserve_revision!(row)

    Repo.update!(
      LocalRecord.changeset(row, %{
        scope: scope,
        kind: "calendar_event",
        record_key: id,
        data: attrs |> Map.merge(state) |> Map.put("id", id),
        lock_version: row.lock_version + 1
      })
    )
  end

  defp import_attrs(event) do
    Enum.reduce(@import_fields, %{}, fn key, acc ->
      atom = String.to_atom(key)
      if Map.has_key?(event, atom), do: Map.put(acc, key, Map.get(event, atom)), else: acc
    end)
  end
end

defmodule Still.Next do
  @moduledoc "Local tasks, their earlier notes, and the dates they bring into Correspondence."
  import Ecto.Query
  alias Still.{LocalRecord, Repo, Storage}
  alias Still.Next.Target
  alias Still.Writing.CollectionLock

  @kind "next"
  @history "next_revision"
  @statuses %{open: "open", done: "done", archived: "archived"}
  @status_atoms Map.new(@statuses, fn {atom, value} -> {value, atom} end)

  def today, do: NaiveDateTime.local_now() |> NaiveDateTime.to_date()

  def list(location) do
    with {:ok, scope} <- active_scope(location) do
      tasks_query(scope) |> Repo.all() |> decode_all()
    end
  end

  def for_target(location, %{type: type, id: id}) do
    with {:ok, scope} <- active_scope(location) do
      tasks_query(scope)
      |> where(
        [r],
        fragment("json_extract(?, '$.target.type')", r.data) == ^type and
          fragment("json_extract(?, '$.target.id')", r.data) == ^id and
          fragment("json_extract(?, '$.status')", r.data) == "open"
      )
      |> Repo.all()
      |> decode_all()
    end
  end

  def history(location, task) do
    with {:ok, scope} <- active_scope(location),
         true <- task.scope == scope do
      prefix = task.id <> ":%"

      Repo.all(
        from r in LocalRecord,
          where: r.scope == ^scope and r.kind == @history and like(r.record_key, ^prefix),
          order_by: [desc: r.lock_version]
      )
      |> decode_all()
    else
      false -> {:error, "The selected collection changed. Reopen Next."}
      error -> error
    end
  end

  def save(location, attrs, existing \\ nil) do
    with {:ok, scope} <- active_scope(location),
         {:ok, data} <- task_data(attrs, existing),
         :ok <- validate_link(location, data["target"], existing) do
      change(location, scope, existing, fn row ->
        if row do
          updated = Map.merge(row.data, data)
          if updated != row.data, do: preserve_revision!(row)
          persist(row, updated)
        else
          id = Ecto.UUID.generate()
          data = Map.merge(data, %{"id" => id, "status" => "open", "closed_at" => nil})

          %LocalRecord{}
          |> LocalRecord.changeset(%{scope: scope, kind: @kind, record_key: id, data: data})
          |> Repo.insert!()
        end
      end)
    end
  end

  def set_status(location, task, status) when is_map_key(@statuses, status) do
    with {:ok, scope} <- active_scope(location) do
      change(location, scope, task, fn row ->
        if row.data["status"] == @statuses[status] do
          row
        else
          preserve_revision!(row)
          closed_at = if status != :open, do: DateTime.utc_now() |> DateTime.to_iso8601()
          persist(row, %{row.data | "status" => @statuses[status], "closed_at" => closed_at})
        end
      end)
    end
  end

  def view(tasks, view, %Date{} = today, query \\ "") do
    needle = normalize_search(query)

    tasks
    |> Enum.filter(&in_view?(&1, view, today))
    |> Enum.filter(&matches?(&1, needle))
    |> sort(view, today)
  end

  def overdue?(task, today), do: task.due_on && Date.before?(task.due_on, today)

  def calendar_entries(tasks) do
    Enum.flat_map(tasks, fn
      %{status: :open} = task ->
        base = %{id: task.id, title: task.title}

        if task.planned_on && task.planned_on == task.due_on do
          [Map.merge(base, %{date: Date.to_iso8601(task.due_on), kind: "planned_and_due"})]
        else
          for {date, kind} <- [{task.planned_on, "planned"}, {task.due_on, "due"}], date do
            Map.merge(base, %{date: Date.to_iso8601(date), kind: kind})
          end
        end

      _ ->
        []
    end)
  end

  defp in_view?(task, "history", _today), do: task.status != :open
  defp in_view?(%{status: status}, _view, _today) when status != :open, do: false

  defp in_view?(task, "today", today),
    do: reached?(task.planned_on, today) || reached?(task.due_on, today)

  defp in_view?(task, "upcoming", today),
    do: Enum.any?([task.planned_on, task.due_on], &(&1 && Date.after?(&1, today)))

  defp in_view?(_task, _view, _today), do: true

  defp reached?(date, today), do: date && not Date.after?(date, today)

  defp sort(tasks, "history", _today), do: Enum.sort_by(tasks, &{&1.closed_at, &1.id}, :desc)

  defp sort(tasks, "today", today) do
    Enum.sort_by(tasks, fn task ->
      if reached?(task.due_on, today),
        do: {0, Date.to_iso8601(task.due_on), task.id},
        else: {1, Date.to_iso8601(task.planned_on), task.id}
    end)
  end

  defp sort(tasks, "upcoming", today) do
    Enum.sort_by(tasks, fn task ->
      dates = Enum.filter([task.planned_on, task.due_on], &(&1 && Date.after?(&1, today)))
      {dates |> Enum.map(&Date.to_iso8601/1) |> Enum.min(), task.id}
    end)
  end

  defp sort(tasks, _view, _today),
    do: Enum.sort_by(tasks, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}, :desc)

  defp matches?(_task, ""), do: true

  defp matches?(task, needle),
    do: String.contains?(normalize_search(task.title <> "\n" <> task.notes), needle)

  defp normalize_search(text),
    do: text |> String.trim() |> String.normalize(:nfc) |> String.downcase()

  defp task_data(attrs, existing) do
    values = %{
      title: attrs["title"] || (existing && existing.title) || "",
      notes: Map.get(attrs, "notes", (existing && existing.notes) || ""),
      planned_on: Map.get(attrs, "planned_on", existing && existing.planned_on),
      due_on: Map.get(attrs, "due_on", existing && existing.due_on),
      target: Map.get(attrs, "target", existing && existing.target)
    }

    with {:ok, title} <- text(values.title, 300, "title"),
         {:ok, notes} <- text(values.notes, 20_000, "notes"),
         true <- String.trim(title) != "",
         {:ok, planned_on} <- date(values.planned_on, "plan date"),
         {:ok, due_on} <- date(values.due_on, "deadline"),
         {:ok, target} <- target_data(values.target) do
      {:ok,
       %{
         "title" => String.trim(title),
         "notes" => notes,
         "planned_on" => planned_on,
         "due_on" => due_on,
         "target" => target
       }}
    else
      false -> {:error, "Give the item a title."}
      error -> error
    end
  end

  defp text(value, limit, label) do
    if is_binary(value) && String.valid?(value) && String.length(value) <= limit,
      do: {:ok, value},
      else: {:error, "Use up to #{limit} characters for the item #{label}."}
  end

  defp date(value, _) when value in [nil, ""], do: {:ok, nil}
  defp date(%Date{} = value, _), do: {:ok, Date.to_iso8601(value)}

  defp date(value, label) do
    if is_binary(value) && match?({:ok, _}, Date.from_iso8601(value)),
      do: {:ok, value},
      else: {:error, "Choose a valid #{label}."}
  end

  defp target_data(nil), do: {:ok, nil}

  defp target_data(%{type: type, id: id}) do
    case Target.parse(type, id) do
      %{id: uuid} -> {:ok, %{"type" => type, "id" => uuid}}
      nil -> {:error, "This correspondence link is invalid."}
    end
  end

  defp target_data(_), do: {:error, "This correspondence link is invalid."}

  defp validate_link(_location, nil, _existing), do: :ok

  defp validate_link(location, %{"type" => type, "id" => id}, existing) do
    target = Target.parse(type, id)

    if (existing && existing.target == target) || Target.label(location, target),
      do: :ok,
      else: {:error, "This correspondence item is unavailable. Add the item without the link."}
  end

  defp active_scope(location) do
    active = Storage.collection_location()

    cond do
      !active.configured ->
        {:error, "Choose a writing folder to use Next."}

      !active.available ->
        {:error, active.error || "The selected writing folder is unavailable."}

      !is_map(location) || location[:scope] != active.scope ->
        {:error, "The selected collection changed. Reopen Next."}

      true ->
        {:ok, active.scope}
    end
  end

  defp tasks_query(scope),
    do: from(r in LocalRecord, where: r.scope == ^scope and r.kind == @kind)

  defp change(location, scope, existing, fun) do
    CollectionLock.with_lock(Repo.config()[:database], fn ->
      Repo.transaction(fn ->
        case active_scope(location) do
          {:ok, ^scope} -> :ok
          {:error, message} -> Repo.rollback(message)
        end

        current = if existing, do: current_task!(scope, existing)
        fun.(current)
      end)
      |> case do
        {:ok, row} -> decode(row)
        {:error, message} -> {:error, message}
      end
    end)
  end

  defp current_task!(scope, %{scope: scope, id: id, revision: revision}) do
    case Repo.get_by(tasks_query(scope), record_key: id) do
      %LocalRecord{lock_version: ^revision} = row -> row
      _ -> Repo.rollback("This item changed in another view. Reopen it before saving.")
    end
  end

  defp current_task!(_, _), do: Repo.rollback("The selected collection changed. Reopen Next.")

  defp persist(row, data) when row.data == data, do: row

  defp persist(row, data) do
    row
    |> LocalRecord.changeset(%{data: data})
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> Repo.update!()
  end

  defp preserve_revision!(row) do
    %LocalRecord{}
    |> LocalRecord.changeset(%{
      scope: row.scope,
      kind: @history,
      record_key: "#{row.record_key}:#{row.lock_version}",
      lock_version: row.lock_version,
      data: row.data
    })
    |> Repo.insert!()
  end

  defp decode_all(rows) do
    decoded = Enum.map(rows, &decode/1)

    case Enum.find(decoded, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(decoded, &elem(&1, 1))}
      error -> error
    end
  end

  defp decode(%LocalRecord{data: data} = row) when is_map(data) do
    with %{"id" => id, "title" => title, "notes" => notes, "status" => status} <- data,
         true <- is_binary(title) && is_binary(notes),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, status} <- Map.fetch(@status_atoms, status),
         {:ok, planned_on} <- decode_date(data["planned_on"]),
         {:ok, due_on} <- decode_date(data["due_on"]),
         {:ok, target} <- decode_target(data["target"]) do
      {:ok,
       %{
         id: id,
         scope: row.scope,
         revision: row.lock_version,
         title: title,
         notes: notes,
         status: status,
         target: target,
         planned_on: planned_on,
         due_on: due_on,
         closed_at: data["closed_at"],
         inserted_at: row.inserted_at
       }}
    else
      _ -> {:error, "A saved item is malformed."}
    end
  end

  defp decode(_), do: {:error, "A saved item is malformed."}

  defp decode_date(nil), do: {:ok, nil}
  defp decode_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp decode_date(_), do: :error

  defp decode_target(nil), do: {:ok, nil}

  defp decode_target(%{"type" => type, "id" => id}) do
    case Target.parse(type, id) do
      nil -> :error
      target -> {:ok, target}
    end
  end

  defp decode_target(_), do: :error
end

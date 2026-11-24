defmodule Still.Correspondence.FundingApplications do
  @moduledoc "Funding drafts, immutable sent materials, and application decisions."

  import Ecto.Query
  alias Still.{Correspondence, LocalRecord, Poems, Repo}
  alias Still.Correspondence.Funding
  alias Still.Writing.CollectionLock

  @kind "funding_application"
  @outcomes ~w(awarded declined withdrawn)
  @draft %{"items" => [], "piece_ids" => [], "notes" => ""}

  @templates [
    {"grant", "Project grant", ["Project statement", "Budget", "Timeline", "Writer bio"]},
    {"fellowship", "Writing fellowship",
     ["Personal statement", "Writing sample requirements", "Writer bio", "References"]},
    {"residency", "Residency",
     ["Project proposal", "Writing sample requirements", "Availability", "Writer bio"]}
  ]

  def blank, do: @draft

  def templates, do: Enum.map(@templates, fn {id, label, _} -> {id, label} end)

  def add_template(draft, id) do
    case List.keyfind(@templates, id, 0) do
      {_, _, labels} ->
        existing = MapSet.new(draft["items"], &String.downcase(String.trim(&1["label"])))

        items =
          for label <- labels, not MapSet.member?(existing, String.downcase(label)) do
            %{"label" => label, "body" => "", "done" => false}
          end

        %{draft | "items" => Enum.take(draft["items"] ++ items, 50)}

      nil ->
        draft
    end
  end

  def outcomes, do: @outcomes
  def status_label("preparing"), do: "In preparation"
  def status_label("set_aside"), do: "Set aside"
  def status_label("submitted"), do: "Awaiting decision"
  def status_label(status), do: String.capitalize(status)

  def list(location) do
    with {:ok, scope} <- Funding.active_scope(location) do
      query =
        from r in LocalRecord,
          where: r.scope == ^scope and r.kind == @kind,
          order_by: [desc: r.updated_at, desc: r.id],
          select: %{
            "id" => r.record_key,
            "opportunity_id" => fragment("json_extract(?, '$.opportunity_id')", r.data),
            "title" => fragment("json_extract(?, '$.title')", r.data),
            "status" => fragment("json_extract(?, '$.status')", r.data),
            "submitted_on" => fragment("json_extract(?, '$.submission.date')", r.data),
            "decision_on" => fragment("json_extract(?, '$.decision.date')", r.data),
            "award" => fragment("json_extract(?, '$.decision.amount')", r.data)
          }

      {:ok, Repo.all(query)}
    end
  end

  def directory(location, filter) do
    with {:ok, applications} <- list(location),
         {:ok, opportunities} <- Funding.list(location) do
      opportunities = Map.new(opportunities, &{&1.id, &1})

      rows =
        for application <- applications do
          opportunity = opportunities[application["opportunity_id"]]

          Map.merge(application, %{
            "funder" => if(opportunity, do: opportunity.funder),
            "deadline" =>
              if(opportunity && application["status"] == "preparing", do: opportunity.deadline)
          })
        end

      rows =
        case filter do
          "sent" -> Enum.filter(rows, & &1["submitted_on"])
          "drafts" -> Enum.filter(rows, &(&1["status"] == "preparing"))
          _ -> rows
        end

      {:ok, Enum.sort_by(rows, &{&1["submitted_on"] || "", &1["decision_on"] || ""}, :desc)}
    end
  end

  def get(location, id) do
    with {:ok, scope} <- Funding.active_scope(location),
         {:ok, row} <- fetch(scope, id),
         do: {:ok, record(row)}
  end

  def start(location, opportunity_id, attrs, source_id \\ nil) do
    with {:ok, draft} <- validate_draft(attrs) do
      change(location, fn scope ->
        with {:ok, opportunity} <- Funding.get(location, opportunity_id),
             {:ok, source} <- copy_source(scope, source_id) do
          draft = if source, do: copied_draft(source.data), else: draft

          data =
            Map.merge(draft, %{
              "opportunity_id" => opportunity.id,
              "title" => opportunity_title(opportunity),
              "status" => "preparing"
            })

          persist(%LocalRecord{}, %{
            scope: scope,
            kind: @kind,
            record_key: Ecto.UUID.generate(),
            data: data
          })
        end
      end)
    end
  end

  def save(location, id, token, attrs) do
    with {:ok, draft} <- validate_draft(attrs) do
      update(location, id, token, "preparing", fn row -> {:ok, Map.merge(row.data, draft)} end)
    end
  end

  def set_aside(location, id, token) do
    update(location, id, token, "preparing", fn row ->
      {:ok, Map.put(row.data, "status", "set_aside")}
    end)
  end

  def resume(location, id, token) do
    update(location, id, token, "set_aside", fn row ->
      {:ok, Map.put(row.data, "status", "preparing")}
    end)
  end

  def review(location, application) do
    with {:ok, pieces} <- Poems.list(location),
         selected = MapSet.new(application["piece_ids"]),
         {:ok, expanded} <-
           pieces
           |> Enum.filter(&MapSet.member?(selected, &1.id))
           |> Correspondence.expand_linked_pieces(location) do
      by_id = Map.new(expanded, &{&1.id, &1})

      materials =
        Enum.map(application["piece_ids"], fn id ->
          case by_id[id] do
            nil ->
              %{"id" => id, "missing" => true}

            piece ->
              %{
                "id" => id,
                "title" => Poems.display_title(piece),
                "body" => piece.body,
                "title_in_body" => piece.title_in_body,
                "title_line" => piece.title_line,
                "title_source" => piece.title_source,
                "source_token" => piece.token
              }
          end
        end)

      {:ok, materials}
    end
  end

  def submit(location, id, token, reviewed, attrs) do
    update(location, id, token, "preparing", fn row ->
      with {:ok, date} <- date(attrs["date"]),
           {:ok, current} <- review(location, row.data),
           :ok <- confirm_review(current, reviewed),
           true <-
             attrs["coverage"] in ["complete", "partial"] ||
               {:error, "Choose how much of the submitted material is recorded."},
           true <-
             (attrs["coverage"] == "partial" or Enum.all?(current, &(!&1["missing"]))) ||
               {:error, "Restore the unavailable writing or mark the record as partial."},
           {:ok, confirmation} <- text(attrs["confirmation"], 10_000) do
        snapshot = %{
          "date" => date,
          "confirmation" => confirmation,
          "coverage" => attrs["coverage"],
          "pieces" => current,
          "items" => row.data["items"]
        }

        {:ok, Map.merge(row.data, %{"status" => "submitted", "submission" => snapshot})}
      end
    end)
  end

  def decide(location, id, token, attrs) do
    update(location, id, token, "submitted", fn row ->
      with true <- attrs["outcome"] in @outcomes || {:error, "Choose an outcome."},
           {:ok, date} <- date(attrs["date"]),
           true <-
             date >= row.data["submission"]["date"] ||
               {:error, "The decision date must be on or after submission."},
           {:ok, notes} <- text(attrs["notes"], 50_000),
           {:ok, amount} <- text(attrs["amount"], 300) do
        outcome = attrs["outcome"]

        decision = %{
          "date" => date,
          "notes" => notes,
          "amount" => if(outcome == "awarded", do: amount, else: "")
        }

        {:ok, Map.merge(row.data, %{"status" => outcome, "decision" => decision})}
      end
    end)
  end

  def opportunity_title(opportunity) do
    Enum.join(Enum.reject([opportunity.name, opportunity.cycle], &(&1 in [nil, ""])), " · ")
  end

  defp validate_draft(%{"items" => items, "piece_ids" => ids} = attrs)
       when is_list(items) and length(items) <= 50 and is_list(ids) and length(ids) <= 100 do
    with true <-
           Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) ||
             {:error, "Choose saved writing for the work sample."},
         {:ok, notes} <- text(attrs["notes"], 50_000),
         {:ok, items} <- validate_items(items) do
      {:ok, %{"items" => items, "piece_ids" => Enum.uniq(ids), "notes" => notes}}
    end
  end

  defp validate_draft(_),
    do: {:error, "An application supports up to 50 requirements and 100 pieces."}

  defp validate_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      with %{"label" => label} <- item,
           {:ok, label} <- text(label, 300),
           {:ok, body} <- text(item["body"], 100_000) do
        {:cont,
         {:ok,
          [%{"label" => label, "body" => body, "done" => item["done"] in [true, "true"]} | acc]}}
      else
        _ -> {:halt, {:error, "A requirement or answer is too long or invalid."}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp text(nil, _limit), do: {:ok, ""}
  defp text(value, limit) when is_binary(value) and byte_size(value) <= limit, do: {:ok, value}
  defp text(_, _), do: {:error, "One of the text fields is too long or invalid."}

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, Date.to_iso8601(date)}
      _ -> {:error, "Enter a valid date."}
    end
  end

  defp date(_), do: {:error, "Enter a valid date."}

  defp confirm_review(current, current), do: :ok

  defp confirm_review(_, _),
    do:
      {:error, "The work sample changed. Review the current materials before marking submitted."}

  defp copy_source(_scope, nil), do: {:ok, nil}
  defp copy_source(scope, id), do: fetch(scope, id)

  defp copied_draft(data) do
    data
    |> Map.take(Map.keys(@draft))
    |> Map.update!("items", fn items -> Enum.map(items, &Map.put(&1, "done", false)) end)
  end

  defp fetch(scope, id) do
    case Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id) do
      nil -> {:error, "This funding application is no longer available."}
      row -> {:ok, row}
    end
  end

  defp update(location, id, token, status, fun) do
    change(location, fn scope ->
      with {:ok, row} <- fetch(scope, id),
           true <-
             Funding.token(row) == token ||
               {:error, "This application changed. Reopen it before saving."},
           true <-
             row.data["status"] == status ||
               {:error, "This application can no longer make that change."},
           {:ok, data} <- fun.(row) do
        if data == row.data do
          {:ok, record(row)}
        else
          persist(row, %{data: data, lock_version: row.lock_version + 1})
        end
      end
    end)
  end

  defp change(location, fun) do
    CollectionLock.with_lock(Repo.config()[:database], fn ->
      Repo.transact(fn ->
        with {:ok, scope} <- Funding.active_scope(location), do: fun.(scope)
      end)
    end)
  end

  defp persist(row, attrs) do
    case Repo.insert_or_update(LocalRecord.changeset(row, attrs)) do
      {:ok, saved} -> {:ok, record(saved)}
      {:error, _} -> {:error, "Could not save the funding application."}
    end
  end

  defp record(row),
    do: Map.merge(row.data, %{"id" => row.record_key, "token" => Funding.token(row)})
end

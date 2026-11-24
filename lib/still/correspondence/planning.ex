defmodule Still.Correspondence.Planning do
  @moduledoc "Writer-selected preparations and recorded opportunities for Correspondence Home."

  alias Still.{Correspondence, Next}
  alias Still.Correspondence.{Funding, FundingApplications}

  def load(location, overview, params) do
    with {:ok, funding} <- Funding.list(location),
         {:ok, tasks} <- Next.list(location),
         {:ok, applications} <- FundingApplications.list(location) do
      days = if params["days"] in ["30", "60"], do: String.to_integer(params["days"]), else: 90

      {:ok,
       build(
         overview,
         funding,
         tasks,
         Next.today(),
         days,
         params["monitor"] == "true",
         applications
       )}
    end
  end

  def build(overview, funding, tasks, today, days, monitor?, applications \\ []) do
    journals = Map.new(overview.journals, &{&1.id, &1})
    funding_by_id = Map.new(funding, &{&1.id, &1})

    application_rows = Enum.map(applications, &application_row(&1, funding_by_id))
    applications_by_id = Map.new(application_rows, &{&1.id, &1})
    attempted = MapSet.new(applications, & &1["opportunity_id"])

    tasks =
      for %{status: :open, target: %{type: type, id: id}} = task <- tasks,
          type in ["funding", "journal", "packet", "funding_application"],
          do: preparation(task, funding_by_id[id], journals[id], applications_by_id[id], today)

    funding_rows =
      for opportunity <- funding,
          opportunity.eligibility_status != "ineligible",
          not MapSet.member?(attempted, opportunity.id),
          opportunity.priority == "pursue" or
            (monitor? and
               (opportunity.priority == "monitor" or
                  (is_nil(opportunity.priority) and opportunity.highlighted))),
          do: funding_row(opportunity, today)

    drafts = Enum.filter(overview.packets, &(&1.status == "preparing"))
    draft_journal_ids = MapSet.new(drafts, & &1.journal_id)

    journal_rows =
      for journal <- overview.journals,
          Correspondence.active_journal?(journal),
          journal.shortlisted,
          not MapSet.member?(draft_journal_ids, journal.id),
          do: journal_row(journal, today)

    draft_rows = Enum.map(drafts, &draft_row(&1, Map.get(journals, &1.journal_id), today))
    application_drafts = Enum.filter(application_rows, &(&1.status == "preparing"))
    awaiting_funding = Enum.filter(application_rows, &(&1.status == "submitted"))
    rows = tasks ++ draft_rows ++ application_drafts ++ funding_rows ++ journal_rows
    immediate = Date.add(today, 30)
    horizon = Date.add(today, days)

    {now, upcoming} =
      rows
      |> Enum.sort_by(&{iso_sort(&1.action_on), String.downcase(&1.title)})
      |> Enum.split_with(fn row ->
        row.commitment? and (is_nil(row.action_on) or Date.compare(row.action_on, today) != :gt)
      end)

    upcoming =
      Enum.filter(upcoming, fn row ->
        (is_nil(row.action_on) or Date.compare(row.action_on, horizon) != :gt) and
          (row.commitment? or is_nil(row.closes) or Date.compare(row.closes, today) != :lt)
      end)

    {near, later} =
      Enum.split_with(upcoming, &(&1.action_on && Date.compare(&1.action_on, immediate) != :gt))

    %{
      now: now,
      near: near,
      later: later,
      days: days,
      monitor?: monitor?,
      awaiting_funding: awaiting_funding
    }
  end

  defp preparation(task, funding, journal, application, today) do
    details =
      case task.target.type do
        "funding" -> if funding, do: funding_row(funding, today)
        "journal" -> if journal, do: journal_row(journal, today)
        "packet" -> nil
        "funding_application" -> application
      end

    row(task.target.type, task.target.id, task.title,
      action_on:
        Enum.min(Enum.reject([task.planned_on, task.due_on], &is_nil/1), Date, fn -> nil end),
      closes: details && details.closes,
      context: details && details.title,
      facts: details && details.facts,
      action_label: task_date_label(task),
      commitment?: true
    )
  end

  defp application_row(application, funding_by_id) do
    opportunity = funding_by_id[application["opportunity_id"]]
    preparing? = application["status"] == "preparing"

    row("funding_application", application["id"], application["title"],
      closes: if(preparing? && opportunity, do: date(opportunity.deadline)),
      context: if(opportunity, do: opportunity.funder),
      facts: [
        if(preparing?, do: "Funding application in preparation"),
        if(application["submitted_on"], do: "Submitted " <> application["submitted_on"]),
        if(preparing? && opportunity && opportunity.deadline_time,
          do: "Deadline time: #{opportunity.deadline_time} #{opportunity.timezone}"
        )
      ],
      commitment?: preparing?
    )
    |> Map.put(:status, application["status"])
  end

  defp draft_row(packet, journal, today) do
    details = if journal, do: journal_row(journal, today)

    row("packet", packet.id, packet.title || "Untitled packet",
      opens: details && details.opens,
      closes: details && details.closes,
      context: if(journal, do: journal.name, else: "No destination chosen"),
      facts: ["Packet in preparation" | if(details, do: details.facts, else: [])],
      commitment?: true
    )
  end

  defp funding_row(item, today) do
    opens = date(item.opens_on)
    deadline = date(item.deadline)
    future_opening? = opens && Date.after?(opens, today)
    active? = is_nil(deadline) or not Date.before?(deadline, today)

    row("funding", item.id, item.name,
      action_on: date(item.prepare_on) || if(future_opening?, do: opens, else: deadline),
      action_label:
        cond do
          item.prepare_on -> "Start preparing"
          future_opening? -> "Opens"
          deadline -> "Deadline"
          true -> "Opens"
        end,
      opens: opens,
      closes: deadline,
      context: item.funder,
      facts: [
        Funding.benefit_label(item.benefit),
        item.amount,
        if(item.fee, do: "Fee: " <> item.fee),
        item.travel,
        item.effort,
        item.fit,
        if(item.eligibility_status != "eligible", do: "Confirm eligibility"),
        if(is_nil(item.deadline), do: item.anticipated_window || "Confirm deadline"),
        if(item.deadline_time, do: "Deadline time: #{item.deadline_time} #{item.timezone}")
      ],
      commitment?: active? and item.priority == "pursue" and not is_nil(item.prepare_on)
    )
  end

  defp journal_row(journal, today) do
    window = journal.submission_window || %{}
    closes = date(window["closes"])
    opens = date(window["opens"])
    future_opening? = opens && Date.after?(opens, today)

    row("journal", journal.id, journal.name,
      action_on: if(future_opening?, do: opens, else: closes),
      action_label: if(future_opening?, do: "Opens", else: "Closes"),
      closes: closes,
      opens: opens,
      facts: [
        "Publication",
        if(journal.fee, do: "Fee: " <> journal.fee),
        if(!Correspondence.active_journal?(journal), do: "Place is inactive"),
        case window["mode"] do
          "always" -> "Open year-round"
          "dates" -> nil
          _ -> "Confirm reading dates"
        end
      ]
    )
  end

  defp row(type, id, title, opts) do
    %{
      type: type,
      id: id,
      title: title,
      context: opts[:context],
      opens: opts[:opens],
      closes: opts[:closes],
      facts: Enum.reject(opts[:facts] || [], &(&1 in [nil, ""])),
      action_on: opts[:action_on],
      action_label: opts[:action_label],
      commitment?: opts[:commitment?] || false
    }
  end

  defp task_date_label(%{planned_on: nil}), do: "Due"
  defp task_date_label(%{planned_on: _, due_on: nil}), do: "Plan"

  defp task_date_label(task),
    do: if(Date.before?(task.due_on, task.planned_on), do: "Due", else: "Plan")

  defp iso_sort(nil), do: "9999-12-31"
  defp iso_sort(date), do: Date.to_iso8601(date)

  defp date(nil), do: nil
  defp date(value), do: Date.from_iso8601!(value)
end

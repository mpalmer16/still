defmodule Still.Correspondence.PlanningTest do
  use ExUnit.Case, async: true

  alias Still.Correspondence.{Funding, Planning}

  @today ~D[2026-11-24]

  test "uses preparation before a distant deadline and keeps the reading window intact" do
    grant = opportunity("grant", %{"prepare_on" => "2026-11-24", "deadline" => "2027-05-01"})

    journal = %{
      id: "journal",
      name: "Journal",
      shortlisted: true,
      fee: nil,
      submission_window: %{"mode" => "dates", "opens" => "2027-01-15", "closes" => "2027-04-01"}
    }

    overview = %{journals: [journal], packets: []}
    plan = Planning.build(overview, [grant], [], @today, 90, false)

    assert [%{id: "grant", closes: ~D[2027-05-01]}] = plan.now
    assert [%{id: "journal", action_on: ~D[2027-01-15], closes: ~D[2027-04-01]}] = plan.later
    assert Planning.build(overview, [grant], [], @today, 30, false).later == []
  end

  test "monitoring is opt-in and anticipated dates remain wording" do
    watched = opportunity("watched", %{"priority" => "monitor", "anticipated_window" => "Spring"})
    excluded = opportunity("excluded", %{"eligibility_status" => "ineligible"})
    expired = opportunity("expired", %{"prepare_on" => "2026-10-01", "deadline" => "2026-11-01"})
    overview = %{journals: [], packets: []}

    assert %{now: [], near: [], later: []} =
             Planning.build(overview, [watched, excluded, expired], [], @today, 90, false)

    assert %{now: [], later: [%{id: "watched", action_on: nil, facts: facts}]} =
             Planning.build(overview, [watched, excluded, expired], [], @today, 90, true)

    assert "Spring" in facts
  end

  test "a writer's open Next step is visible even when the linked opportunity is monitored" do
    watched = opportunity("watched", %{"priority" => "monitor"})

    task = %{
      status: :open,
      target: %{type: "funding", id: "watched"},
      title: "Review eligibility",
      planned_on: ~D[2026-11-23],
      due_on: ~D[2027-01-12]
    }

    assert %{now: [%{title: "Review eligibility", action_on: ~D[2026-11-23]}]} =
             Planning.build(%{journals: [], packets: []}, [watched], [task], @today, 90, false)
  end

  defp opportunity(id, attrs) do
    base = %{"name" => id, "funder" => "Funder", "kind" => "grant", "priority" => "pursue"}
    {:ok, normalized} = Funding.validate(Map.merge(base, attrs))
    normalized |> Funding.atomize() |> Map.put(:id, id)
  end
end

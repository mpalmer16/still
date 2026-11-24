defmodule StillWeb.FundingApplicationLiveTest do
  use StillWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Still.{Next, Poems, Storage}
  alias Still.Correspondence.{Funding, FundingApplications}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {:ok, _} = Storage.set_folder(root)
    location = Storage.collection_location()

    {:ok, opportunity} =
      Funding.save(location, %{
        name: "Poetry Fellowship",
        funder: "Arts Council",
        kind: "fellowship",
        cycle: "First cycle"
      })

    %{location: location, opportunity: opportunity}
  end

  test "opens a draft from an opportunity row and switches between applications and submissions",
       %{
         conn: conn,
         location: location,
         opportunity: opportunity
       } do
    {:ok, opportunities, _} = live(conn, ~p"/correspondence/funding")
    row = "#funding-row-#{opportunity.id}"

    {:ok, draft, _} =
      opportunities
      |> element("#{row} a", "Prepare application")
      |> render_click()
      |> follow_redirect(conn)

    template = %{"template" => %{"id" => "grant"}}
    render_submit(element(draft, "#funding-template"), template)
    assert has_element?(draft, "#funding-requirement-1", "Budget")

    answer = "  Exact project wording."
    fields = %{"0" => %{"label" => "Project statement", "body" => answer}}
    attrs = %{"application" => %{"items" => fields, "notes" => "Keep this draft note."}}
    render_change(element(draft, "#funding-draft"), attrs)
    render_submit(element(draft, "#funding-template"), template)
    refute has_element?(draft, "#funding-requirement-4")

    {:ok, _, _} =
      draft |> element("#funding-draft") |> render_submit(attrs) |> follow_redirect(conn)

    {:ok, [prepared]} = FundingApplications.list(location)

    assert {:ok, %{"items" => [%{"body" => ^answer} | _]}} =
             FundingApplications.get(location, prepared["id"])

    {:ok, previous} =
      FundingApplications.start(location, opportunity.id, FundingApplications.blank())

    {:ok, sent} =
      FundingApplications.submit(location, previous["id"], previous["token"], [], %{
        "date" => "2025-11-10",
        "coverage" => "partial"
      })

    assert {:ok, _} =
             FundingApplications.decide(location, sent["id"], sent["token"], %{
               "date" => "2025-11-15",
               "outcome" => "awarded",
               "amount" => "USD 500"
             })

    {:ok, opportunities, _} = live(conn, ~p"/correspondence/funding")
    render_click(element(opportunities, "nav[aria-label='Funding view'] a", "Applications"))
    assert_patch(opportunities, ~p"/correspondence/funding/applications")
    draft_row = "#funding-application-row-#{prepared["id"]}"
    sent_row = "#funding-application-row-#{sent["id"]}"
    assert has_element?(opportunities, draft_row, "In preparation")
    assert has_element?(opportunities, sent_row, "USD 500")

    render_click(element(opportunities, "nav[aria-label='Application status'] a", "Submitted"))
    refute has_element?(opportunities, draft_row)
    assert has_element?(opportunities, sent_row, "Awarded")

    render_click(element(opportunities, "nav[aria-label='Application status'] a", "Drafts"))
    assert has_element?(opportunities, draft_row)
    refute has_element?(opportunities, sent_row)
  end

  test "prepares, reviews, submits, and records an award from Funding", %{
    conn: conn,
    location: location,
    opportunity: opportunity
  } do
    {:ok, first} =
      Poems.save(location, Poems.new(location), %{title: "First", body: "First original words.\n"})

    {:ok, second} =
      Poems.save(location, Poems.new(location), %{
        title: "Second",
        body: "Second original words.\n"
      })

    opportunity_path = ~p"/correspondence/funding/#{opportunity.id}"
    {:ok, detail, _} = live(conn, opportunity_path)

    {:ok, draft, _} =
      detail |> element("a", "Prepare application") |> render_click() |> follow_redirect(conn)

    render_click(element(draft, "button", "Add requirement"))

    for piece <- [first, second] do
      render_submit(element(draft, "#funding-add-piece"), %{"sample" => %{"id" => piece.id}})
    end

    render_click(element(draft, "button", "Move up"))
    body = "  A project about winter.\n\nThe next paragraph."

    attrs = %{
      "application" => %{
        "notes" => "Ask for the reference next week.",
        "items" => %{"0" => %{"label" => "Project statement", "body" => body, "done" => "true"}}
      }
    }

    {:ok, view, _} =
      draft |> element("#funding-draft") |> render_submit(attrs) |> follow_redirect(conn)

    {:ok, [%{"id" => id}]} = FundingApplications.list(location)
    app_path = ~p"/correspondence/funding/applications/#{id}"
    assert has_element?(view, "#funding-requirement-0", "Project statement")

    render_click(element(view, "button", "Set aside draft"))
    assert has_element?(view, "button", "Resume draft")
    refute has_element?(view, "#funding-draft")
    render_click(element(view, "button", "Resume draft"))
    assert has_element?(view, "#funding-requirement-0", "Project statement")
    assert has_element?(view, "a[href*='from=funding_application']", "Add to Next")

    assert {:ok, _} =
             Next.save(location, %{
               "title" => "Ask for a reference",
               "target" => %{type: "funding_application", id: id}
             })

    {:ok, home, _} = live(conn, ~p"/correspondence")

    assert has_element?(
             home,
             "#correspondence-planning a[href='#{app_path}']",
             "Poetry Fellowship"
           )

    assert has_element?(
             home,
             "#correspondence-planning a[href='#{app_path}']",
             "Ask for a reference"
           )

    render_click(element(view, "button", "Review materials"))
    assert has_element?(view, "#funding-submission-review summary", "Second")
    assert has_element?(view, "#funding-submission-review", "First original words.")

    {:ok, edited} = Poems.save(location, first, %{body: "First revised words.\n"})
    date = to_string(Next.today())

    submitted = %{
      "submission" => %{"date" => date, "coverage" => "complete", "confirmation" => "AB-123"}
    }

    render_submit(element(view, "#funding-submission"), submitted)
    assert has_element?(view, "[role=alert]", "The work sample changed")

    render_click(element(view, "button", "Review materials"))
    render_submit(element(view, "#funding-submission"), submitted)
    assert has_element?(view, "#funding-sent-materials", "AB-123")
    assert {:ok, _} = Poems.save(location, edited, %{body: "First newer words.\n"})

    {:ok, reopened, _} = live(conn, app_path)
    assert has_element?(reopened, "#funding-sent-materials", "First revised words.")
    refute has_element?(reopened, "#funding-sent-materials", "First newer words.")
    assert {:ok, %{"submission" => snapshot}} = FundingApplications.get(location, id)
    assert [%{"id" => second_id}, %{"id" => first_id}] = snapshot["pieces"]
    assert {second_id, first_id} == {second.id, first.id}
    assert [%{"body" => ^body}] = snapshot["items"]

    {:ok, home, _} = live(conn, ~p"/correspondence")

    assert has_element?(
             home,
             "#funding-awaiting-decisions a[href='#{app_path}']",
             "Poetry Fellowship"
           )

    render_submit(element(reopened, "#funding-decision"), %{
      "decision" => %{
        "date" => date,
        "outcome" => "awarded",
        "amount" => "USD 5,000",
        "notes" => "Received an award letter."
      }
    })

    assert has_element?(reopened, "#funding-recorded-decision", "USD 5,000")

    {:ok, next_cycle} =
      Funding.save(location, %{
        name: opportunity.name,
        funder: opportunity.funder,
        kind: opportunity.kind,
        cycle: "Second cycle"
      })

    {:ok, copy, _} =
      reopened
      |> element("#funding-copy-application")
      |> render_submit(%{"copy" => %{"opportunity_id" => next_cycle.id}})
      |> follow_redirect(conn)

    assert has_element?(copy, "h1", "Second cycle")
    assert has_element?(copy, "#funding-requirement-0", "Project statement")
    refute has_element?(copy, "#funding-requirement-0 input[type=checkbox][checked]")

    assert {:ok, %{"submission" => ^snapshot, "status" => "awarded"}} =
             FundingApplications.get(location, id)

    {:ok, detail, _} = live(conn, opportunity_path)

    assert has_element?(
             detail,
             "#funding-opportunity-applications a[href='#{app_path}']",
             "Awarded"
           )
  end

  test "records a partial older application and rejects a stale draft save", %{
    location: location,
    opportunity: opportunity
  } do
    draft = FundingApplications.blank()
    {:ok, app} = FundingApplications.start(location, opportunity.id, draft)

    {:ok, updated} =
      FundingApplications.save(location, app["id"], app["token"], %{
        draft
        | "notes" => "Earlier application"
      })

    assert {:error, message} = FundingApplications.save(location, app["id"], app["token"], draft)
    assert message =~ "application changed"

    assert {:ok,
            %{"status" => "submitted", "submission" => %{"coverage" => "partial", "pieces" => []}}} =
             FundingApplications.submit(location, updated["id"], updated["token"], [], %{
               "date" => "2025-11-10",
               "coverage" => "partial"
             })
  end
end

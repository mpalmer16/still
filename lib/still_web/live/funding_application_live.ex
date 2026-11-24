defmodule StillWeb.FundingApplicationLive do
  use StillWeb, :live_view
  on_mount {StillWeb.CorrespondenceWorkspace, :appearance}

  alias Still.{Next, Poems, Storage}
  alias Still.Correspondence.{Appearance, Funding, FundingApplications}
  alias StillWeb.{CopyText, CorrespondenceWorkspace}

  @impl true
  def mount(_params, _session, socket) do
    appearance = Appearance.current()

    {:ok,
     assign(socket,
       page_title: "Funding application",
       correspondence_light?: appearance.light?,
       correspondence_color: appearance.color,
       notice: nil,
       problem: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    location = Storage.collection_location()

    socket =
      assign(socket,
        location: location,
        application: nil,
        opportunity: nil,
        review: nil,
        tasks: [],
        target: nil,
        problem: nil,
        draft: FundingApplications.blank(),
        choices: [],
        opportunities: [],
        today: Date.to_iso8601(Next.today())
      )

    result =
      case socket.assigns.live_action do
        :new ->
          with {:ok, opportunity} <- Funding.get(location, params["opportunity_id"]),
               do: {:ok, nil, opportunity}

        :show ->
          with {:ok, application} <- FundingApplications.get(location, params["id"]),
               {:ok, opportunity} <- Funding.get(location, application["opportunity_id"]),
               do: {:ok, application, opportunity}
      end

    case result do
      {:ok, application, opportunity} ->
        socket =
          assign(socket,
            application: application,
            opportunity: opportunity,
            page_title: FundingApplications.opportunity_title(opportunity)
          )

        {:noreply, load_workspace(socket)}

      {:error, message} ->
        {:noreply, assign(socket, problem: message)}
    end
  end

  defp load_workspace(socket) do
    %{location: location, application: application} = socket.assigns

    socket =
      if application do
        target = %{type: "funding_application", id: application["id"]}

        case Next.for_target(location, target) do
          {:ok, tasks} -> assign(socket, target: target, tasks: tasks)
          {:error, message} -> assign(socket, target: target, problem: message)
        end
      else
        socket
      end

    socket =
      case Funding.list(location) do
        {:ok, opportunities} -> assign(socket, opportunities: opportunities)
        {:error, message} -> assign(socket, problem: message)
      end

    if is_nil(application) or application["status"] == "preparing" do
      case Poems.list(location) do
        {:ok, choices} ->
          assign(socket,
            choices: choices,
            draft:
              Map.take(
                application || FundingApplications.blank(),
                Map.keys(FundingApplications.blank())
              )
          )

        {:error, message} ->
          assign(socket, problem: message)
      end
    else
      socket
    end
  end

  @impl true
  def handle_event("edit", %{"application" => attrs}, socket) do
    {:noreply, assign(socket, draft: draft_params(attrs, socket.assigns.draft), review: nil)}
  end

  def handle_event("apply_template", %{"template" => %{"id" => id}}, socket) do
    draft = FundingApplications.add_template(socket.assigns.draft, id)
    {:noreply, assign(socket, draft: draft, review: nil)}
  end

  def handle_event("add_requirement", _, socket) do
    {:noreply,
     edit_draft(
       socket,
       "items",
       &Enum.take(&1 ++ [%{"label" => "", "body" => "", "done" => false}], 50)
     )}
  end

  def handle_event("remove_requirement", %{"index" => index}, socket) do
    {:noreply, edit_draft(socket, "items", &List.delete_at(&1, index_value(index)))}
  end

  def handle_event("add_piece", %{"sample" => %{"id" => id}}, socket) do
    if Enum.any?(socket.assigns.choices, &(&1.id == id)) do
      {:noreply, edit_draft(socket, "piece_ids", &Enum.take(Enum.uniq(&1 ++ [id]), 100))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_piece", %{"id" => id}, socket) do
    {:noreply, edit_draft(socket, "piece_ids", &List.delete(&1, id))}
  end

  def handle_event("move_piece", %{"index" => raw}, socket) do
    index = index_value(raw)

    {:noreply,
     edit_draft(socket, "piece_ids", fn ids ->
       if index > 0 and index < length(ids) do
         {id, rest} = List.pop_at(ids, index)
         List.insert_at(rest, index - 1, id)
       else
         ids
       end
     end)}
  end

  def handle_event("save", %{"application" => attrs}, socket) do
    %{application: application, location: location, opportunity: opportunity, draft: draft} =
      socket.assigns

    draft = draft_params(attrs, draft)
    socket = assign(socket, draft: draft, review: nil)

    if application do
      result = FundingApplications.save(location, application["id"], application["token"], draft)
      {:noreply, update_result(socket, result, "Application saved.")}
    else
      {:noreply,
       navigate_result(socket, FundingApplications.start(location, opportunity.id, draft))}
    end
  end

  def handle_event("set_aside", _, socket) do
    %{location: location, application: application, draft: draft} = socket.assigns

    if Map.take(application, Map.keys(draft)) == draft do
      result = FundingApplications.set_aside(location, application["id"], application["token"])
      {:noreply, update_result(socket, result, "Draft set aside.")}
    else
      {:noreply, assign(socket, problem: "Save your changes before setting the draft aside.")}
    end
  end

  def handle_event("resume", _, socket) do
    %{location: location, application: application} = socket.assigns
    result = FundingApplications.resume(location, application["id"], application["token"])
    socket = update_result(socket, result, "Draft resumed.")
    {:noreply, if(match?({:ok, _}, result), do: load_workspace(socket), else: socket)}
  end

  def handle_event("review", _, socket) do
    %{location: location, application: application, draft: draft} = socket.assigns

    if application["status"] == "preparing" and Map.take(application, Map.keys(draft)) == draft do
      case FundingApplications.review(location, application) do
        {:ok, materials} -> {:noreply, assign(socket, review: materials, problem: nil)}
        {:error, message} -> {:noreply, assign(socket, review: nil, problem: message)}
      end
    else
      {:noreply, assign(socket, problem: "Save your changes before reviewing what you sent.")}
    end
  end

  def handle_event("submit", %{"submission" => attrs}, socket) do
    %{location: location, application: application, review: review} = socket.assigns

    result =
      FundingApplications.submit(location, application["id"], application["token"], review, attrs)

    {:noreply, update_result(socket, result, "Submission recorded.")}
  end

  def handle_event("decide", %{"decision" => attrs}, socket) do
    %{location: location, application: application} = socket.assigns
    result = FundingApplications.decide(location, application["id"], application["token"], attrs)
    {:noreply, update_result(socket, result, "Decision recorded.")}
  end

  def handle_event("copy", %{"copy" => %{"opportunity_id" => id}}, socket) do
    %{location: location, application: application} = socket.assigns

    result =
      FundingApplications.start(location, id, FundingApplications.blank(), application["id"])

    {:noreply, navigate_result(socket, result)}
  end

  def handle_event("dismiss_correspondence_notice", _, socket),
    do: {:noreply, assign(socket, notice: nil)}

  defp edit_draft(socket, key, fun) do
    assign(socket, draft: Map.update!(socket.assigns.draft, key, fun), review: nil)
  end

  defp draft_params(attrs, draft) do
    items =
      draft["items"]
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        case get_in(attrs, ["items", Integer.to_string(index)]) do
          %{"label" => label, "body" => body} = fields ->
            %{"label" => label, "body" => body, "done" => fields["done"] == "true"}

          _ ->
            item
        end
      end)

    %{draft | "items" => items, "notes" => Map.get(attrs, "notes", draft["notes"])}
  end

  defp index_value(raw) do
    case Integer.parse(raw) do
      {index, ""} when index >= 0 -> index
      _ -> 1_000
    end
  end

  defp navigate_result(socket, {:ok, application}),
    do: push_navigate(socket, to: ~p"/correspondence/funding/applications/#{application["id"]}")

  defp navigate_result(socket, {:error, message}), do: assign(socket, problem: message)

  defp update_result(socket, {:ok, application}, notice) do
    assign(socket,
      application: application,
      review: nil,
      problem: nil,
      notice: notice,
      draft: Map.take(application, Map.keys(FundingApplications.blank()))
    )
  end

  defp update_result(socket, {:error, message}, _notice), do: assign(socket, problem: message)

  defp status(value), do: FundingApplications.status_label(value)

  defp piece_label(choices, id) do
    case Enum.find(choices, &(&1.id == id)) do
      nil -> "Unavailable writing"
      piece -> Poems.display_title(piece)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <CorrespondenceWorkspace.workspace
      flash={@flash}
      appearance_light?={@correspondence_light?}
      appearance_color={@correspondence_color}
      funding_section?
      nav_mode={:navigate}
      notice={@notice}
      next_target={@target}
      related_tasks={@tasks}
    >
      <section class="corr-page" id="funding-application">
        <p :if={@problem} class="corr-message error" role="alert">{@problem}</p>
        <div :if={@opportunity} class="funding-application-editor">
          <div class="corr-breadcrumb">
            <.link navigate={~p"/correspondence/funding/applications"}>← Applications</.link>
          </div>
          <header class="corr-page-heading">
            <div class="corr-packet-heading-copy">
              <h1>{@page_title}</h1>
              <p class="corr-meta">
                {@opportunity.funder} · {if @application,
                  do: status(@application["status"]),
                  else: "New application"}
              </p>
            </div>
            <button
              :if={!@application || @application["status"] == "preparing"}
              class="corr-button corr-packet-save has-changes"
              type="submit"
              form="funding-draft"
              phx-disable-with="Saving…"
            >
              {if @application, do: "Save application", else: "Create draft"}
            </button>
          </header>

          <%= if !@application || @application["status"] == "preparing" do %>
            <div class="funding-application-grid">
              <aside class="editorial-packet-library funding-application-sidebar">
                <div class="corr-section-heading">
                  <h2>Application details</h2>
                </div>
                <p :if={@opportunity.deadline} class="corr-meta">
                  Deadline <time datetime={@opportunity.deadline}>{@opportunity.deadline}</time>
                  <span :if={@opportunity.deadline_time}>{@opportunity.deadline_time} {@opportunity.timezone}</span>
                </p>
                <.link
                  navigate={~p"/correspondence/funding/#{@opportunity.id}"}
                  class="corr-text-link"
                >Opportunity details</.link>
                <a
                  :if={StillWeb.CorrespondenceFunding.safe_url(@opportunity.application_url)}
                  href={@opportunity.application_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="corr-text-link"
                >Funder’s application page ↗</a>
                <form id="funding-template" phx-submit="apply_template">
                  <label>
                    Start from a template
                    <select name="template[id]" required>
                      <option value="">Choose a template</option>
                      <option :for={{id, label} <- FundingApplications.templates()} value={id}>
                        {label}
                      </option>
                    </select>
                  </label>
                  <button type="submit" class="corr-button">Add template requirements</button>
                </form>
              </aside>
              <div class="funding-application-main">
                <form
                  id="funding-draft"
                  class="corr-destination-panel"
                  phx-change="edit"
                  phx-submit="save"
                >
                  <fieldset class="funding-requirements">
                    <legend>Requirements and answers</legend>
                    <fieldset
                      :for={{item, index} <- Enum.with_index(@draft["items"])}
                      class="funding-requirement"
                      id={"funding-requirement-#{index}"}
                    >
                      <legend>
                        {if item["label"] == "", do: "Requirement", else: item["label"]}
                      </legend>
                      <label>Requirement
                      <input name={"application[items][#{index}][label]"} value={item["label"]} /></label>
                      <label>Answer or material <textarea
                        name={"application[items][#{index}][body]"}
                        rows="5"
                      ><%= item["body"] %></textarea></label>
                      <label><input
                        type="checkbox"
                        name={"application[items][#{index}][done]"}
                        value="true"
                        checked={item["done"]}
                      /> Ready</label>
                      <button type="button" phx-click="remove_requirement" phx-value-index={index}>Remove requirement</button>
                    </fieldset>
                    <button type="button" phx-click="add_requirement">Add requirement</button>
                  </fieldset>
                  <label>Preparation notes <textarea name="application[notes]" rows="4"><%= @draft["notes"] %></textarea></label>
                </form>

                <section class="corr-destination-panel" aria-labelledby="funding-work-sample">
                  <h2 id="funding-work-sample">Work sample</h2>
                  <ol :if={@draft["piece_ids"] != []}>
                    <li :for={{id, index} <- Enum.with_index(@draft["piece_ids"])}>
                      {piece_label(@choices, id)}
                      <button
                        :if={index > 0}
                        type="button"
                        phx-click="move_piece"
                        phx-value-index={index}
                        aria-label={"Move #{piece_label(@choices, id)} up"}
                      >Move up</button>
                      <button
                        type="button"
                        phx-click="remove_piece"
                        phx-value-id={id}
                        aria-label={"Remove #{piece_label(@choices, id)}"}
                      >Remove</button>
                    </li>
                  </ol>
                  <form id="funding-add-piece" phx-submit="add_piece">
                    <label>
                      Saved writing
                      <select name="sample[id]" required>
                        <option value="">Choose a piece</option>
                        <option
                          :for={piece <- @choices}
                          :if={piece.id not in @draft["piece_ids"]}
                          value={piece.id}
                        >
                          {Poems.display_title(piece)}
                        </option>
                      </select>
                    </label>
                    <button type="submit">Add to sample</button>
                  </form>
                </section>
                <div :if={@application} class="funding-application-actions">
                  <button class="corr-button" type="button" phx-click="review">Review materials</button>
                  <button class="corr-button" type="button" phx-click="set_aside">Set aside draft</button>
                </div>
                <section :if={@review} id="funding-submission-review" class="corr-destination-panel">
                  <h2>Review materials</h2>
                  <p>After applying, mark submitted to preserve the materials shown here.</p>
                  <.materials items={@application["items"]} pieces={@review} />
                  <form id="funding-submission" phx-submit="submit">
                    <label>Submission date
                    <input type="date" name="submission[date]" value={@today} required /></label>
                    <label>
                      Materials recorded
                      <select name="submission[coverage]" required>
                        <option value="">Choose one</option>
                        <option value="complete">All submitted materials are recorded</option>
                        <option value="partial">
                          Only some or none of the materials are recorded
                        </option>
                      </select>
                    </label>
                    <label>Confirmation number or note <textarea
                      name="submission[confirmation]"
                      rows="2"
                    ></textarea></label>
                    <button type="submit">Mark submitted</button>
                  </form>
                </section>
              </div>
            </div>
          <% else %>
            <button :if={@application["status"] == "set_aside"} type="button" phx-click="resume">Resume draft</button>
            <section
              :if={@application["submission"]}
              id="funding-sent-materials"
              class="corr-destination-panel"
            >
              <h2>Submitted {@application["submission"]["date"]}</h2>
              <p :if={@application["submission"]["coverage"] == "partial"}>
                Partial record of submitted materials.
              </p>
              <p :if={@application["submission"]["confirmation"] != ""}>
                {@application["submission"]["confirmation"]}
              </p>
              <.materials
                items={@application["submission"]["items"]}
                pieces={@application["submission"]["pieces"]}
              />
            </section>
            <form
              :if={@application["status"] == "submitted"}
              id="funding-decision"
              class="corr-destination-panel"
              phx-submit="decide"
            >
              <h2>Record a decision</h2>
              <label>
                Outcome
                <select name="decision[outcome]" required>
                  <option value="">Choose an outcome</option>
                  <option :for={outcome <- FundingApplications.outcomes()} value={outcome}>
                    {status(outcome)}
                  </option>
                </select>
              </label>
              <label>Decision date <input type="date" name="decision[date]" value={@today} required /></label>
              <label>Amount awarded, if applicable
              <input name="decision[amount]" placeholder="USD 5,000" /></label>
              <label>Response or notes <textarea name="decision[notes]" rows="4"></textarea></label>
              <button type="submit">Save decision</button>
            </form>
            <section
              :if={@application["decision"]}
              id="funding-recorded-decision"
              class="corr-destination-panel"
            >
              <h2>{status(@application["status"])} {@application["decision"]["date"]}</h2>
              <p :if={@application["decision"]["amount"] != ""}>
                {@application["decision"]["amount"]}
              </p>
              <p class="funding-preserved-text">{@application["decision"]["notes"]}</p>
            </section>
          <% end %>

          <form
            :if={@application}
            id="funding-copy-application"
            class="corr-destination-panel funding-copy-panel"
            phx-submit="copy"
          >
            <label>
              Copy saved materials to
              <select name="copy[opportunity_id]" required>
                <option
                  :for={opportunity <- @opportunities}
                  value={opportunity.id}
                  selected={opportunity.id == @opportunity.id}
                >
                  {FundingApplications.opportunity_title(opportunity)}
                </option>
              </select>
            </label>
            <button type="submit">Copy to new application</button>
          </form>
        </div>
      </section>
    </CorrespondenceWorkspace.workspace>
    """
  end

  defp materials(assigns) do
    ~H"""
    <div :for={{item, index} <- Enum.with_index(@items)} :if={item["body"] != ""}>
      <h3>{item["label"]}</h3>
      <p class="funding-preserved-text">{item["body"]}</p>
      <CopyText.copy_text id={"funding-copy-answer-#{index}"} body={item["body"]} label="Copy answer" />
    </div>
    <div :for={piece <- @pieces}>
      <p :if={piece["missing"]}>Unavailable writing</p>
      <details :if={!piece["missing"]}>
        <summary>{piece["title"]}</summary>
        <p class="funding-preserved-text">{piece["body"]}</p>
        <CopyText.copy_text
          id={"funding-copy-piece-#{piece["id"]}"}
          body={piece["body"]}
          title={piece["title"]}
          title_source={piece["title_source"]}
          title_in_body={piece["title_in_body"]}
          label="Copy writing"
        />
      </details>
    </div>
    """
  end
end

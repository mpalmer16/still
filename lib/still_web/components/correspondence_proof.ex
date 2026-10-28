defmodule StillWeb.CorrespondenceProof do
  @moduledoc "Two complete manuscript versions, with optional quiet change markings."
  use StillWeb, :html

  attr :piece, :map, required: true
  attr :comparison, :map, required: true
  attr :sources, :list, required: true
  attr :plain, :boolean, default: false

  def reading(assigns) do
    ~H"""
    <section id="work-proof" class="corr-proof" aria-labelledby="proof-heading">
      <header class="proof-heading">
        <div>
          <p class="proof-eyebrow">
            <.link patch={~p"/correspondence/writing/#{@piece.id}"}>{@comparison.current_title}</.link>
            · across its versions
          </p>
          <h1 id="proof-heading">Then &amp; now<span>.</span></h1>
          <p>
            {if @comparison.source.kind == :sent,
              do: "The words that traveled. The words you have kept working on.",
              else: "A page as it was. A page as it is."}
          </p>
        </div>
        <.link
          id="close-proof"
          patch={~p"/correspondence/writing/#{@piece.id}"}
          class="corr-text-link"
        >Return to the work <span aria-hidden="true">↗</span></.link>
      </header>

      <div class="proof-controls">
        <form id="proof-source-form" phx-change="compare_work" phx-submit="compare_work">
          <label for="proof-source">Look back to</label>
          <select id="proof-source" name="proof[source]">
            <option
              :for={source <- @sources}
              value={source.key}
              selected={source.key == @comparison.source.key}
            >
              {source.label} · {date(source.date)} · {source.title}
            </option>
          </select>
          <button type="submit" class="proof-select-submit">Compare</button>
        </form>
        <nav aria-label="Comparison markings" class="proof-reading-mode">
          <.link
            id="proof-show-changes"
            patch={proof_path(@piece.id, @comparison.source.key, false)}
            aria-current={if !@plain, do: "true"}
          >What changed</.link>
          <.link
            id="proof-just-read"
            patch={proof_path(@piece.id, @comparison.source.key, true)}
            aria-current={if @plain, do: "true"}
          >Just read</.link>
        </nav>
      </div>

      <div id="proof-status" class="proof-status" role="status">
        <p>{status(@comparison)}</p>
        <div
          :if={!@plain && @comparison.detailed? && !@comparison.body_same?}
          class="proof-legend"
          aria-label="Change markings"
        >
          <span><i class="proof-old-swatch" aria-hidden="true"></i>Earlier passage</span>
          <span><i class="proof-new-swatch" aria-hidden="true"></i>Current passage</span>
        </div>
      </div>

      <div class={"proof-pages #{if @plain, do: "proof-plain"}"}>
        <article
          id="proof-earlier"
          class="proof-page proof-page-earlier"
          aria-label="Earlier manuscript"
        >
          <header>
            <div class="proof-page-top">
              <span class="proof-eyebrow">Then</span><span>{date(@comparison.source.date)}</span>
            </div>
            <p class="proof-destination">{@comparison.source.label}</p>
            <h3 class={if !@plain && !@comparison.title_same?, do: "proof-title-changed"}>
              {@comparison.source.title}
            </h3>
          </header>
          <pre :if={@plain || !@comparison.detailed?} class="proof-text" phx-no-format>{@comparison.source.body}</pre>
          <pre :if={!@plain && @comparison.detailed?} class="proof-text" phx-no-format><.passages segments={@comparison.earlier} /></pre>
          <p :if={@comparison.source.body == ""} class="proof-empty-page">An empty page.</p>
          <.link
            :if={@comparison.source.packet_id}
            id="proof-open-packet"
            patch={~p"/correspondence/packets/#{@comparison.source.packet_id}"}
            class="proof-page-link"
          >Read the recorded correspondence <span aria-hidden="true">↗</span></.link>
        </article>
        <article
          id="proof-current"
          class="proof-page proof-page-current"
          aria-label="Current manuscript"
        >
          <header>
            <div class="proof-page-top">
              <span class="proof-eyebrow">Now</span><span>Current saved page</span>
            </div>
            <p class="proof-destination">Here, in your collection</p>
            <h3 class={if !@plain && !@comparison.title_same?, do: "proof-title-changed"}>
              {@comparison.current_title}
            </h3>
          </header>
          <pre :if={@plain || !@comparison.detailed?} class="proof-text" phx-no-format>{@piece.body}</pre>
          <pre :if={!@plain && @comparison.detailed?} class="proof-text" phx-no-format><.passages segments={@comparison.current} /></pre>
          <p :if={@piece.body == ""} class="proof-empty-page">An empty page.</p>
          <.link
            id="proof-edit-current"
            navigate={~p"/writing/#{@piece.id}/edit"}
            class="proof-page-link"
          >Continue in Now <span aria-hidden="true">↗</span></.link>
        </article>
      </div>
      <footer class="proof-footnote">
        <span :if={@comparison.source.kind == :sent}>The sent copy stays with its recorded packet.</span>
        <span :if={@comparison.source.kind == :saved}>An earlier save, held alongside the current page.</span>
        <span>Both pages keep their own line breaks and spacing.</span>
      </footer>
    </section>
    """
  end

  attr :segments, :list, required: true

  defp passages(assigns) do
    ~H"""
    <span phx-no-format><%= for segment <- @segments do %><mark :if={segment.kind != :same} class={"proof-#{segment.kind}"}>{segment.text}</mark><%= if segment.kind == :same do %>{segment.text}<% end %><% end %></span>
    """
  end

  defp proof_path(id, source, plain) do
    params = [compare: source] ++ if(plain, do: [view: "plain"], else: [])
    ~p"/correspondence/writing/#{id}?#{params}"
  end

  defp status(%{body_same?: true, title_same?: true}),
    do: "This version matches your current page."

  defp status(%{body_same?: true}), do: "The words match. The title has changed."

  defp status(%{line_endings_only?: true}),
    do: "The words and spacing match; the files use different line endings."

  defp status(%{spacing_only?: true}), do: "The changes are in spacing or line breaks."
  defp status(%{detailed?: false}), do: "These longer versions are shown as complete pages."
  defp status(_), do: "Read what changed, or let the two versions speak for themselves."

  defp date(nil), do: "Date not recorded"
  defp date(%Date{} = date), do: Calendar.strftime(date, "%d %b %Y")
  defp date(%DateTime{} = date), do: Calendar.strftime(date, "%d %b %Y · %H:%M UTC")

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} ->
        date(datetime)

      _ ->
        case Date.from_iso8601(value) do
          {:ok, parsed} -> date(parsed)
          _ -> "Date not recorded"
        end
    end
  end

  defp date(_), do: "Date not recorded"
end

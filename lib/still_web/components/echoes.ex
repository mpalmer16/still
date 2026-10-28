defmodule StillWeb.Echoes do
  use StillWeb, :html
  alias Still.Writing.Attention

  attr :fragments, :list, required: true

  def field(assigns) do
    fragments =
      Enum.map(assigns.fragments, fn fragment ->
        excerpt = Attention.excerpt(fragment.entry.body, fragment.line)
        unfolded = excerpt.before <> fragment.line <> excerpt.after

        more =
          (String.trim(excerpt.before) != "" || String.trim(excerpt.after) != "") &&
            String.length(unfolded) <= 240

        Map.merge(fragment, %{
          unfolded: unfolded,
          unfolds: more
        })
      end)

    assigns = assign(assigns, :fragments, fragments)

    ~H"""
    <aside
      :for={fragment <- @fragments}
      id={"drawn-before-#{fragment.entry.id}"}
      class={"gravity-presence field-#{fragment.side} gravity-#{fragment.distance} motion-#{fragment.motion} #{if fragment.departing, do: "gravity-receding"}"}
      style={"--field-y: #{fragment.height}vh; --pull: #{fragment.strength}; --arrival-delay: #{fragment.delay}ms;"}
      aria-label={if fragment.entry.origin == "before", do: "From before", else: "Written here"}
      aria-hidden={if fragment.departing, do: "true", else: nil}
      inert={fragment.departing}
    >
      <.link
        navigate={~p"/w/#{fragment.entry.id}?read=1&approach=#{fragment.side}"}
        class="gravity-door"
      >
        <span class="gravity-horizon" aria-hidden="true"></span>
        <div class={"gravity-words #{if fragment.unfolds, do: "echo-can-unfold"}"}>
          <div class="echo-glimpse">
            <div><.shaped_words body={fragment.line} /></div>
          </div>
          <div :if={fragment.unfolds} class="echo-unfolded">
            <div><.shaped_words body={fragment.unfolded} trim_terminal_line={true} /></div>
          </div>
        </div>
        <span :if={fragment.entry.title} class="gravity-title"><.list_title text={
          fragment.entry.title
        } /></span>
        <span class="gravity-place">{fragment.place.label}<span :if={
          Still.Writing.source_number(fragment.entry)
        }> · source {Still.Writing.source_number(fragment.entry)}</span></span>
      </.link>
    </aside>
    """
  end

  attr :body, :string, required: true
  attr :query, :string, default: ""
  attr :id_prefix, :string, default: "passage"
  attr :target_line, :integer, default: nil
  attr :active_line, :integer, default: nil

  def reading(assigns) do
    passages = Attention.passages(assigns.body)

    assigns =
      assigns
      |> assign(:passages, Enum.with_index(passages))
      |> assign(:last_passage, length(passages) - 1)

    ~H"""
    <div class="echo-reading">
      <div
        :for={{passage, index} <- @passages}
        class={
          if passage.kind == :passage,
            do: "echo-passage #{if @active_line == passage.first_line, do: "passage-listening"}",
            else: "echo-space"
        }
      >
        <.shaped_words
          body={passage.text}
          query={@query}
          id_prefix={@id_prefix}
          target_line={@target_line}
          start_line={passage.first_line}
          trim_terminal_line={index < @last_passage}
        />
        <button
          :if={passage.kind == :passage}
          id={"listen-passage-#{passage.first_line}"}
          type="button"
          phx-click="listen_passage"
          phx-value-line={passage.first_line}
          aria-label={"Listen beside the passage beginning on line #{passage.first_line}"}
          aria-pressed={to_string(@active_line == passage.first_line)}
          class="passage-listen"
        ><span aria-hidden="true" class="passage-ear"></span><span
          aria-hidden="true"
          class="listen-label"
        >Listen here</span></button>
      </div>
      <.shaped_words :if={@passages == []} body={@body} id_prefix={@id_prefix} />
      <div :if={@active_line} class="passage-listening-note">
        <span>Beside this passage</span><button
          id="listen-whole"
          type="button"
          phx-click="listen_whole"
          class="quiet-link"
        >Whole page</button>
      </div>
    </div>
    """
  end
end

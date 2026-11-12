defmodule StillWeb.Echoes do
  use StillWeb, :html
  alias Still.Writing.Attention
  alias Still.Writing.Gravity

  def immediate(field), do: Enum.map(field, &Map.merge(&1, %{departing: false, delay: 0}))

  attr :fragments, :list, required: true
  attr :responsive, :boolean, default: false

  def field(assigns) do
    fragments =
      Enum.map(assigns.fragments, fn fragment ->
        excerpt = Attention.excerpt(Gravity.echo_text(fragment.entry.body), fragment.line)
        unfolded = excerpt.before <> fragment.line <> excerpt.after

        more =
          (String.trim(excerpt.before) != "" || String.trim(excerpt.after) != "") &&
            String.length(unfolded) <= 240

        Map.merge(fragment, %{
          unfolded: unfolded,
          unfolds: more,
          echo_title:
            if(is_binary(fragment.entry.title),
              do: Gravity.echo_text(fragment.entry.title) |> String.trim()
            )
        })
      end)

    assigns = assign(assigns, :fragments, fragments)

    ~H"""
    <aside
      :for={fragment <- @fragments}
      id={"drawn-before-#{fragment.entry.id}"}
      class={"gravity-presence field-#{fragment.side} gravity-#{fragment.distance} motion-#{fragment.motion} #{if @responsive, do: "passage-echo"} #{if fragment.departing, do: "gravity-receding"}"}
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
        <span :if={fragment.echo_title not in [nil, ""]} class="gravity-title"><.list_title text={
          fragment.echo_title
        } /></span>
        <span class="gravity-place">{Still.Writing.Geography.reference_label(
          fragment.place,
          Still.Writing.source_number(fragment.entry)
        )}</span>
      </.link>
    </aside>
    """
  end

  attr :body, :string, required: true
  attr :query, :string, default: ""
  attr :id_prefix, :string, default: "passage"
  attr :target_line, :integer, default: nil
  attr :active_line, :integer, default: nil
  attr :listening, :boolean, default: true
  attr :document_id, :any, default: nil
  attr :start_line, :integer, default: 1

  def reading(assigns) do
    passages =
      Enum.map(
        Attention.passages(assigns.body),
        &Map.update!(&1, :first_line, fn line -> line + assigns.start_line - 1 end)
      )

    assigns =
      assigns
      |> assign(:passages, Enum.with_index(passages))
      |> assign(:last_passage, length(passages) - 1)

    ~H"""
    <div
      class="echo-reading"
      id={if @listening && @document_id, do: "echo-attention-#{@id_prefix}-#{@document_id}"}
      phx-hook={if @listening && @document_id, do: "PassageAttention"}
      data-echo-document={@document_id}
    >
      <div
        :for={{passage, index} <- @passages}
        data-echo-line={
          if @listening && @document_id && passage.kind == :passage, do: passage.first_line
        }
        tabindex={if @listening && @document_id && passage.kind == :passage, do: "0"}
        class={
          if passage.kind == :passage,
            do: "echo-passage #{if @active_line == passage.first_line, do: "passage-focused"}",
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
      </div>
      <.shaped_words :if={@passages == []} body={@body} id_prefix={@id_prefix} />
      <div
        :if={
          @active_line &&
            Enum.any?(@passages, fn {passage, _} -> passage.first_line == @active_line end)
        }
        class="passage-focused-note"
      >
        <span>Beside this passage</span><button
          id="whole-page-echoes"
          data-clear-passage-focus
          type="button"
          phx-click="clear_passage_focus"
          class="quiet-link"
        >Whole page</button>
      </div>
    </div>
    """
  end
end

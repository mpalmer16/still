defmodule StillWeb.PoemReference do
  use StillWeb, :html

  attr :segment, :map, required: true
  attr :id, :string, default: nil
  attr :editing, :boolean, default: false
  attr :query, :string, default: ""
  attr :return_to, :string, default: nil

  def passage(assigns) do
    ~H"""
    <figure
      id={@id}
      tabindex={if @id, do: "-1"}
      class={"poem-insert #{if @segment.status != :available, do: "poem-insert-unavailable"}"}
      data-writing-part={if @editing, do: "reference"}
      data-reference-raw={if @editing, do: @segment.raw}
      aria-label="Linked poem"
    >
      <blockquote :if={@segment.status == :available} class="poem-insert-words" phx-no-format><.highlight text={@segment.source.body} query={@query} /></blockquote>
      <p :if={@segment.status != :available} class="file-note" role="status">
        Source unavailable · {@segment.message}
      </p>
      <figcaption class="poem-insert-caption">
        <%= if @segment.status == :available do %>
          <span>{Still.Poems.display_title(@segment.source)}</span>
          <.link
            navigate={original_path(@segment.source.id, @return_to)}
            class="quiet-link"
          >Open original</.link>
        <% else %>
          <span>{@segment.path}</span>
        <% end %>
        <button :if={@editing} type="button" data-remove-poem class="quiet-link">Remove link</button>
      </figcaption>
    </figure>
    """
  end

  defp original_path(id, nil), do: ~p"/writing/#{id}/edit"
  defp original_path(id, return_to), do: ~p"/writing/#{id}/edit?reference_return=#{return_to}"
end

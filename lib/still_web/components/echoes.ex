defmodule StillWeb.Echoes do
  use StillWeb, :html

  attr :fragments, :list, required: true

  def field(assigns) do
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
        <div class="gravity-words"><.shaped_words body={fragment.line} /></div>
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
end

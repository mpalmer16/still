defmodule StillWeb.NextLinks do
  @moduledoc false
  use StillWeb, :html

  attr :target, :map, required: true
  attr :tasks, :list, default: []

  def related(assigns) do
    ~H"""
    <aside class="corr-next-links" aria-label="Related items">
      <.link
        :for={task <- @tasks}
        class="corr-next-task"
        navigate={~p"/correspondence/next?#{%{edit: task.id}}"}
      >{task.title} ↗</.link>
      <.link
        class="corr-next-add"
        navigate={~p"/correspondence/next?#{%{from: @target.type, ref: @target.id}}"}
      >+ Add to Next</.link>
    </aside>
    """
  end

  def source_path(%{type: "piece", id: id}), do: ~p"/correspondence/writing/#{id}"
  def source_path(%{type: "journal", id: id}), do: ~p"/correspondence/journals/#{id}"
  def source_path(%{type: "packet", id: id}), do: ~p"/correspondence/packets/#{id}"
  def source_path(%{type: "event", id: id}), do: ~p"/correspondence/calendar/events/#{id}/edit"

  def source_path(%{type: "funding_application", id: id}),
    do: ~p"/correspondence/funding/applications/#{id}"

  def source_path(%{type: "funding", id: id}), do: ~p"/correspondence/funding/#{id}"
end

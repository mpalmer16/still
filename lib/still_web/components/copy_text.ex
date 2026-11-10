defmodule StillWeb.CopyText do
  use Phoenix.Component

  attr :id, :string, required: true
  attr :body, :string, required: true
  attr :title, :string, default: nil
  attr :title_source, :string, default: "explicit"
  attr :title_in_body, :boolean, default: false
  attr :editing, :boolean, default: false
  attr :body_selector, :string, default: nil
  attr :title_selector, :string, default: nil
  attr :reference_sources, :map, default: %{}

  def copy_text(assigns) do
    assigns =
      assign(
        assigns,
        :payload,
        Jason.encode!(%{
          body: assigns.body,
          title: assigns.title,
          title_source: assigns.title_source,
          title_in_body: assigns.title_in_body
        })
      )

    ~H"""
    <span
      id={@id}
      class="copy-text"
      phx-hook="CopyText"
      data-persisted={@payload}
      data-body-selector={if @editing, do: @body_selector}
      data-title-selector={if @editing, do: @title_selector}
      data-reference-sources={Jason.encode!(@reference_sources)}
    >
      <button type="button" class="copy-text-button" aria-label="Copy text" title="Copy text">
        <svg viewBox="0 0 20 20" aria-hidden="true" focusable="false">
          <rect
            x="7"
            y="3"
            width="10"
            height="12"
            rx="1.5"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          />
          <path
            d="M13 17H4.5A1.5 1.5 0 0 1 3 15.5V6"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
          />
        </svg>
      </button>
      <span data-copy-status role="status" aria-live="polite" class="copy-text-status"></span>
    </span>
    """
  end
end

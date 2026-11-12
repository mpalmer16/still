defmodule StillWeb.NotebookIndex do
  use StillWeb, :html

  alias Still.Writing
  alias StillWeb.ReadingLinks

  attr(:notebook, :map, required: true)
  attr(:entry_id, :integer, required: true)
  attr(:context, :map, default: %{})
  attr(:patch, :boolean, default: false)

  def sidebar(assigns) do
    ~H"""
    <aside id="notebook-sidebar" aria-label="Notebook index">
      <.link navigate={~p"/notebooks"} class="quiet-link">All notebooks</.link>
      <h2>{@notebook.label || "Notebook"}</h2>
      <section
        :for={section <- @notebook.sections}
        class="notebook-reader-section"
        aria-label={section.label}
      >
        <h3 :if={length(@notebook.sections) > 1}>{section.label}</h3>
        <ol>
          <li :for={item <- section.entries} id={"reader-list-#{item.id}"}>
            <%= if @patch do %>
              <.link
                patch={reader_path(item, @notebook, @context)}
                aria-current={if item.id == @entry_id, do: "page", else: nil}
              >
                <.item_title item={item} />
              </.link>
            <% else %>
              <.link
                navigate={reader_path(item, @notebook, @context)}
                aria-current={if item.id == @entry_id, do: "page", else: nil}
              >
                <.item_title item={item} />
              </.link>
            <% end %>
          </li>
        </ol>
      </section>
    </aside>
    """
  end

  attr(:item, :map, required: true)

  defp item_title(assigns) do
    ~H"""
    <span :if={Writing.source_number(@item)} class="notebook-piece-number">{Writing.source_number(
      @item
    )}</span>
    <span class="notebook-piece-title"><.list_title text={Writing.opening(@item)} /></span>
    """
  end

  defp reader_path(entry, notebook, context) do
    ReadingLinks.reader(
      entry,
      context
      |> Map.put_new("from", "notebook")
      |> Map.put("notebook", notebook.key)
      |> Map.put("version", nil)
    )
  end
end

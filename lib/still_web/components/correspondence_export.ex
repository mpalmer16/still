defmodule StillWeb.CorrespondenceExport do
  @moduledoc "A copyable JSON export for Correspondence records."
  use StillWeb, :html

  attr :json, :string, default: nil
  attr :label, :string, required: true
  attr :detail, :string, default: nil

  def panel(assigns) do
    ~H"""
    <section :if={@json} class="corr-json-export" aria-labelledby="correspondence-export-title">
      <header>
        <h2 id="correspondence-export-title">{@label} JSON</h2>
        <StillWeb.CopyText.copy_text
          id="copy-correspondence-json"
          body={@json}
          label="Copy JSON"
          title_in_body={true}
        />
        <button type="button" phx-click="close_json_export">Close</button>
      </header>
      <p>{@detail || "Includes saved notes. Review the contents before sharing."}</p>
      <textarea
        id="correspondence-export-json"
        aria-labelledby="correspondence-export-title"
        readonly
        spellcheck="false"
        rows="6"
      >{@json}</textarea>
    </section>
    """
  end
end

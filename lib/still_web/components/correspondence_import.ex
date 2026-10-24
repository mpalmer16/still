defmodule StillWeb.CorrespondenceImport do
  @moduledoc "A reviewed, add-only import of submission destinations."
  use StillWeb, :html
  alias Still.Correspondence.PlaceImport

  attr :upload, :any, required: true
  attr :plan, :any, default: nil
  attr :result, :any, default: nil

  def page(assigns) do
    assigns = assign(assigns, :example, PlaceImport.example())

    ~H"""
    <section id="places-import" class="corr-place-import" aria-labelledby="places-import-heading">
      <.link patch={~p"/correspondence/journals"} class="editorial-place-back">← Places</.link>
      <h1 id="places-import-heading">Import Places</h1>
      <p>
        Choose a JSON file, then review it before adding anything. Existing places, including inactive ones, stay unchanged. Repeated names are skipped.
      </p>
      <form
        id="places-import-form"
        phx-change="validate_places_upload"
        phx-submit="preview_places_import"
      >
        <label for={@upload.ref}>Places JSON file</label>
        <.live_file_input upload={@upload} />
        <p class="corr-meta">One .json file, up to 1 MB and 200 places.</p>
        <p :for={error <- upload_errors(@upload)} role="alert">{upload_error(error)}</p>
        <p :for={entry <- @upload.entries}>
          {entry.client_name}
          <span :for={error <- upload_errors(@upload, entry)} role="alert">{upload_error(error)}</span>
        </p>
        <button type="submit" class="corr-button" phx-disable-with="Reading…">Review places →</button>
      </form>
      <section :if={@plan} id="places-import-preview" class="corr-import-review">
        <h2>{length(@plan.places)} to add · {length(@plan.skipped)} skipped</h2>
        <ul>
          <li :for={place <- @plan.places}>{place.name}</li>
        </ul>
        <p :if={@plan.skipped != []}>Already present or repeated: {Enum.join(@plan.skipped, ", ")}</p>
        <p>
          Imported details are personal notes, not source-checked facts. Check each publication’s current guidelines before submitting.
        </p>
        <button
          :if={@plan.places != []}
          id="confirm-places-import"
          type="button"
          phx-click="import_places"
          class="corr-button"
          phx-disable-with="Adding…"
        >Import {length(@plan.places)} {if length(@plan.places) == 1, do: "place", else: "places"} →</button>
      </section>
      <section :if={@result} id="places-import-result" aria-live="polite" class="corr-import-review">
        <p>
          Added {length(@result.imported)} {if length(@result.imported) == 1,
            do: "place",
            else: "places"}. Skipped {length(@result.skipped)}.
        </p>
        <p :if={@result.error} role="alert">
          {@result.error} Places already added have been kept. You can review the file again to retry the remainder.
        </p>
        <.link patch={~p"/correspondence/journals"} class="corr-text-link">View Places →</.link>
      </section>
      <details class="corr-import-example" open>
        <summary>JSON example</summary>
        <p>
          Use an array of places like this. Only <code>name</code>
          is required; other fields may be omitted. Text fields are strings. <code>shortlisted</code>
          is true or false. <code>simultaneous_policy</code>
          is <code>unknown</code>, <code>allowed</code>, or <code>not_allowed</code>. Use empty strings for unknown details and HTTP or HTTPS links for web addresses.
        </p>
        <pre><code>{@example}</code></pre>
      </details>
    </section>
    """
  end

  defp upload_error(:too_large), do: "The file is too large. Choose a file no larger than 1 MB."
  defp upload_error(:not_accepted), do: "Choose a .json file."
  defp upload_error(:too_many_files), do: "Choose one file at a time."
  defp upload_error(_), do: "The file could not be uploaded. Choose it again."
end

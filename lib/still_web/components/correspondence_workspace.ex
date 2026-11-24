defmodule StillWeb.CorrespondenceWorkspace do
  @moduledoc "Shared room chrome for Correspondence and its Next view."

  use StillWeb, :html

  alias Still.Correspondence.Appearance
  alias StillWeb.NextLinks

  def on_mount(:appearance, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(
       socket,
       :correspondence_appearance,
       :handle_event,
       &handle_appearance_event/3
     )}
  end

  defp handle_appearance_event("toggle_palette", _params, socket) do
    socket.assigns.correspondence_light?
    |> then(&Appearance.set_light(!&1))
    |> apply_appearance(socket)
  end

  defp handle_appearance_event(
         "change_correspondence_color",
         %{"appearance" => %{"color" => color}},
         socket
       ) do
    color
    |> Appearance.choose_color()
    |> apply_appearance(socket)
  end

  defp handle_appearance_event(_event, _params, socket), do: {:cont, socket}

  defp apply_appearance({:ok, appearance}, socket) do
    {:halt,
     Phoenix.Component.assign(socket,
       correspondence_light?: appearance.light?,
       correspondence_color: appearance.color
     )}
  end

  defp apply_appearance({:error, _reason}, socket) do
    {:halt,
     Phoenix.Component.assign(socket,
       problem: "Could not remember the correspondence color.",
       notice: nil
     )}
  end

  attr :flash, :map, required: true
  attr :appearance_light?, :boolean, required: true
  attr :appearance_color, :string, required: true
  attr :live_action, :atom, default: nil
  attr :places_path, :string, default: nil
  attr :funding_section?, :boolean, default: false
  attr :active_next?, :boolean, default: false
  attr :nav_mode, :atom, default: :patch
  attr :problem, :any, default: nil
  attr :notice, :any, default: nil
  attr :next_target, :any, default: nil
  attr :related_tasks, :list, default: []
  slot :inner_block, required: true

  def workspace(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active="correspondence"
      room_color={if @appearance_light?, do: "light", else: @appearance_color}
      file_exports
      correspondence
    >
      <div
        class={"correspondence-room corr-workspace #{if @appearance_light?, do: "is-light", else: ""}"}
        data-color={@appearance_color}
      >
        <header class="corr-header">
          <div class="corr-brand">
            <.link
              patch={if @nav_mode == :patch, do: ~p"/correspondence"}
              navigate={if @nav_mode == :navigate, do: ~p"/correspondence"}
            ><span class="corr-brand-mark" aria-hidden="true">s.</span>Correspondence</.link>
          </div>
          <nav aria-label="Correspondence">
            <.link
              patch={if @nav_mode == :patch, do: ~p"/correspondence"}
              navigate={if @nav_mode == :navigate, do: ~p"/correspondence"}
              aria-current={if @live_action == :home, do: "page"}
              class={if @live_action == :home, do: "active", else: nil}
            >Home</.link>
            <.link
              patch={if @nav_mode == :patch, do: ~p"/correspondence/writing"}
              navigate={if @nav_mode == :navigate, do: ~p"/correspondence/writing"}
              aria-current={if @live_action in [:collection, :piece], do: "page"}
              class={if @live_action in [:collection, :piece], do: "active", else: nil}
            >Works</.link>
            <.link
              patch={if @nav_mode == :patch, do: @places_path || ~p"/correspondence/journals"}
              navigate={if @nav_mode == :navigate, do: @places_path || ~p"/correspondence/journals"}
              aria-current={
                if @live_action in [:journals, :journal, :new_journal, :import_journals], do: "page"
              }
              class={
                if @live_action in [:journals, :journal, :new_journal, :import_journals],
                  do: "active",
                  else: nil
              }
            >Places</.link>
            <.link
              patch={if @nav_mode == :patch, do: ~p"/correspondence/funding"}
              navigate={if @nav_mode == :navigate, do: ~p"/correspondence/funding"}
              aria-current={if @funding_section?, do: "page"}
              class={if @funding_section?, do: "active", else: nil}
            >Funding</.link>
            <.link
              patch={if @nav_mode == :patch, do: ~p"/correspondence/packets"}
              navigate={if @nav_mode == :navigate, do: ~p"/correspondence/packets"}
              aria-current={if @live_action in [:packets, :packet, :new_packet], do: "page"}
              class={if @live_action in [:packets, :packet, :new_packet], do: "active", else: nil}
            >Packets</.link>
            <.link
              patch={if @nav_mode == :patch, do: ~p"/correspondence/calendar"}
              navigate={if @nav_mode == :navigate, do: ~p"/correspondence/calendar"}
              aria-current={
                if @live_action in [
                     :calendar,
                     :import_calendar,
                     :new_calendar_event,
                     :edit_calendar_event
                   ],
                   do: "page"
              }
              class={
                if @live_action in [
                     :calendar,
                     :import_calendar,
                     :new_calendar_event,
                     :edit_calendar_event
                   ], do: "active", else: nil
              }
            >Calendar</.link>
            <.link
              patch={if @active_next?, do: ~p"/correspondence/next"}
              navigate={if !@active_next?, do: ~p"/correspondence/next"}
              aria-current={if @active_next?, do: "page"}
              class={if @active_next?, do: "active", else: nil}
            >Next</.link>
          </nav>
          <div class="corr-header-actions">
            <details class="corr-popover corr-appearance">
              <summary aria-label="Correspondence appearance" title="Appearance">
                {if @appearance_light?, do: "☀", else: "☾"}
              </summary>
              <div class="corr-popover-panel">
                <button
                  type="button"
                  phx-click="toggle_palette"
                  class="corr-theme"
                  aria-pressed={to_string(@appearance_light?)}
                >{if @appearance_light?, do: "Use dark appearance", else: "Use light appearance"}</button>
                <form id="correspondence-color-form" phx-change="change_correspondence_color">
                  <label for="correspondence-color">Color</label>
                  <select id="correspondence-color" name="appearance[color]">
                    <option
                      :for={{label, color} <- Appearance.choices()}
                      value={color}
                      selected={color == @appearance_color}
                    >
                      {label}
                    </option>
                  </select>
                </form>
              </div>
            </details>
            <.link id="back-to-still" navigate={~p"/"} class="corr-return">
              Back to Still <span aria-hidden="true">↗</span>
            </.link>
          </div>
        </header>

        <div :if={@problem} class="corr-message error" role="alert">
          {@problem}<.link navigate={~p"/storage"}>Storage &amp; Backups</.link>
        </div>
        <div :if={@notice} class="corr-message corr-dismissible-notice">
          <span id="correspondence-notice" role="status">{@notice}</span>
          <button type="button" phx-click="dismiss_correspondence_notice" aria-label="Dismiss message">
            Dismiss
          </button>
        </div>
        <NextLinks.related :if={@next_target} target={@next_target} tasks={@related_tasks} />
        {render_slot(@inner_block)}
      </div>
    </Layouts.app>
    """
  end
end

defmodule StillWeb.Layouts do
  use StillWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :active, :string, default: "write"
  attr :room_light, :integer, default: 38
  attr :light_open, :boolean, default: false
  attr :room_letters, :integer, default: 50
  attr :letters_open, :boolean, default: false
  attr :writing_controls, :boolean, default: false
  attr :writing_menu_open, :boolean, default: false
  attr :writing_picker_open, :boolean, default: false
  attr :file_exports, :boolean, default: false
  attr :room_width, :integer, default: 0
  attr :width_open, :boolean, default: false
  attr :landscape_open, :boolean, default: false
  attr :places, :list, default: []

  attr :place, :map,
    default: %{
      key: "now",
      label: "Write",
      region: "",
      x: 50,
      y: 50,
      tone: 0,
      anchor_x: 50,
      anchor_y: 50
    }

  attr :return_writing, :any, default: nil
  attr :return_beside, :any, default: nil
  attr :return_list, :boolean, default: false
  slot :inner_block, required: true
  slot :writing_menu
  slot :writing_overlay

  def app(assigns) do
    ~H"""
    <div
      id={if @file_exports, do: "writing-export-status"}
      phx-hook={if @file_exports, do: "WritingExports"}
      class={"site-frame #{if @landscape_open, do: "landscape-revealed"}"}
      spellcheck="false"
      style={"--light: #{@room_light}; --letters: #{@room_letters / 100}; --place-x: #{@place.x}%; --place-y: #{@place.y}%; --place-tone: #{@place.tone};#{if @room_width > 0, do: " --page-width: #{@room_width}px;"}"}
    >
      <a href="#page-content" class="skip-link">Skip to the page</a>
      <div class="room-light" aria-hidden="true"></div>
      <div
        id="room-content"
        inert={@landscape_open || @writing_picker_open || (@writing_controls && @writing_menu_open)}
        aria-hidden={
          if @landscape_open || @writing_picker_open || (@writing_controls && @writing_menu_open),
            do: "true"
        }
      >
        <header class="site-header">
          <.link navigate={~p"/?new=1"} class="wordmark" aria-label="Still, a new page">still<span class="wordmark-stop">.</span></.link>
          <nav class="site-nav" aria-label="Main navigation">
            <.link
              id="return-to-writing"
              aria-current={if @active == "write", do: "page"}
              navigate={return_path(@return_writing, @return_beside, @return_list)}
              class={if(@active == "write", do: "nav-active", else: nil)}
            >Write</.link>
            <.link
              id="open-notebooks"
              navigate={~p"/notebooks"}
              aria-current={if @active == "notebooks", do: "page"}
              class={if(@active == "notebooks", do: "nav-active", else: nil)}
            >Notebooks</.link>
            <.link
              id="wander"
              aria-current={if @active == "before", do: "page"}
              navigate={~p"/wander"}
              class={if(@active == "before", do: "nav-active", else: nil)}
            >Wander</.link>

            <.link
              navigate={~p"/pages"}
              aria-current={if @active == "pages", do: "page"}
              class={if(@active == "pages", do: "nav-active", else: nil)}
            >Find</.link>
            <.link
              id="open-correspondence"
              navigate={~p"/correspondence"}
              aria-current={if @active == "correspondence", do: "page"}
              class={if(@active == "correspondence", do: "nav-active", else: nil)}
            >Correspondence</.link>
          </nav>
        </header>
        <main id="page-content" tabindex="-1">{render_slot(@inner_block)}</main>
      </div>

      <%= if @writing_controls do %>
        <button
          id="writing-menu-toggle"
          type="button"
          phx-click="toggle_writing_menu"
          class="writing-menu-toggle room-control"
          aria-haspopup="dialog"
          aria-controls="writing-menu"
          aria-expanded={to_string(@writing_menu_open)}
          hidden={@writing_menu_open || @writing_picker_open || @landscape_open}
        >Menu</button>
        <div
          :if={@writing_menu_open}
          class="writing-menu-backdrop"
          phx-click="close_writing_menu"
          aria-hidden="true"
        >
        </div>
        <.focus_wrap
          id="writing-menu"
          class="writing-menu"
          hidden={!@writing_menu_open}
          role="dialog"
          aria-modal="true"
          aria-labelledby="writing-menu-heading"
          phx-window-keydown="close_writing_menu"
          phx-key="Escape"
        >
          <header class="writing-menu-heading">
            <h2 id="writing-menu-heading">Writing</h2>
            <button
              id="writing-menu-close"
              type="button"
              phx-click="close_writing_menu"
              class="quiet-link"
              aria-label="Close menu and return to writing"
            >Close</button>
          </header>
          {render_slot(@writing_menu)}
          <.room_tools {assigns} />
        </.focus_wrap>
      <% else %>
        <.room_tools {assigns} />
      <% end %>

      {render_slot(@writing_overlay)}

      <section
        :if={@landscape_open}
        id="room-landscape"
        class="room-landscape"
        role="dialog"
        aria-modal="true"
        aria-label="The room"
      >
        <button
          id="room-close"
          type="button"
          phx-click="close_room"
          class="landscape-close room-control"
          aria-label="Return to the page"
        >Return</button>
        <.link
          id="landscape-now"
          navigate={return_path(@return_writing, @return_beside, @return_list)}
          class={"landscape-place landscape-now #{if @place.key == "now", do: "place-current"}"}
          style="--x: 50%; --y: 72%;"
        >Write</.link>
        <.link
          :for={place <- @places}
          id={place_id(place.key)}
          navigate={~p"/notebooks?notebook=#{place.key}"}
          class={"landscape-place #{if @place.key == place.key, do: "place-current"}"}
          style={"--x: #{place.x}%; --y: #{place.y}%; --tone: #{place.tone};"}
          title={region_label(place.region)}
        >
          <span class="landscape-name">{place.label}</span>
          <span :if={region_label(place.region) != ""} class="landscape-region">{region_label(
            place.region
          )}</span>
        </.link>
        <.link id="landscape-index" navigate={~p"/notebooks"} class="landscape-index room-control">
          All notebooks
        </.link>
      </section>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp return_path(_writing, _beside, _list), do: ~p"/"

  defp place_id(key), do: "place-" <> String.replace(key, ~r/[^\p{L}\p{N}_-]/u, "-")

  defp region_label(:early), do: "Early notebooks"
  defp region_label(:current), do: "Current notebooks"
  defp region_label(:now), do: ""
  defp region_label(:elsewhere), do: "Before"
  defp region_label(region), do: to_string(region)

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="flash-stack" aria-live="polite">
      <p :for={{kind, message} <- @flash} class={"flash flash-#{kind}"}>{message}</p>
      <p
        id="connection-lost"
        class="flash phx-client-error"
        hidden
        phx-disconnected={JS.remove_attribute("hidden")}
        phx-connected={JS.set_attribute({"hidden", ""})}
      >
        Connection lost. This browser keeps a copy while you write.
      </p>
    </div>
    """
  end

  defp room_tools(assigns) do
    ~H"""
    <div
      class={if @writing_controls, do: "writing-menu-room-controls", else: "room-light-control"}
      inert={@landscape_open}
    >
      <button
        id="light-toggle"
        type="button"
        phx-click="toggle_light"
        aria-expanded={to_string(@light_open)}
        aria-controls="room-light-form"
        class="room-control"
      >Light</button>
      <button
        id="letters-toggle"
        type="button"
        phx-click="toggle_letters"
        aria-expanded={to_string(@letters_open)}
        aria-controls="room-letters-form"
        class="room-control"
      >Letters</button>
      <button
        :if={@writing_controls}
        id="page-width-toggle"
        type="button"
        phx-click="toggle_width"
        aria-expanded={to_string(@width_open)}
        aria-controls="room-page-form"
        class="room-control"
      >Page width</button>
      <form
        :if={@writing_controls && @width_open}
        id="room-page-form"
        phx-change="change_width"
        phx-submit="change_width"
        class="letters-adjustment page-width-adjustment"
      >
        <label for="room-page-width" class="sr-only">Writing page width</label>
        <input
          id="room-page-width"
          name="page[width]"
          type="range"
          min="560"
          max="1600"
          step="20"
          value={if @room_width == 0, do: 740, else: @room_width}
          phx-debounce="100"
          aria-valuetext={
            if @room_width == 0,
              do: "Default width",
              else: "Up to #{@room_width} pixels, leaving space for echoes"
          }
        />
        <span class="page-width-value">{if @room_width == 0, do: "Default", else: "#{@room_width}px"}</span>
        <button type="button" phx-click="reset_width" class="room-control">Reset</button>
        <button id="room-close" type="button" phx-click="close_room" class="room-control">Done</button>
        <small>The screen limits the width to leave room for echoes.</small>
      </form>
      <form
        :if={@light_open}
        id="room-light-form"
        phx-change="change_light"
        phx-submit="change_light"
        class="light-adjustment"
      >
        <label for="room-light-angle" class="sr-only">Change the light</label>
        <input
          id="room-light-angle"
          name="light[angle]"
          type="range"
          min="0"
          max="360"
          step="1"
          value={@room_light}
          phx-debounce="100"
          aria-label="Change the light"
          aria-valuetext={"Light position #{@room_light} of 360"}
        />
        <button id="room-close" type="button" phx-click="close_room" class="light-done room-control">Done</button>
      </form>
      <form
        :if={@letters_open}
        id="room-letters-form"
        phx-change="change_letters"
        phx-submit="change_letters"
        class="letters-adjustment"
      >
        <label for="room-letters-size" class="sr-only">Change the size of the writing</label>
        <input
          id="room-letters-size"
          name="letters[size]"
          type="range"
          min="0"
          max="100"
          step="1"
          value={@room_letters}
          phx-debounce="100"
          aria-label="Change the size of the writing"
          aria-valuetext={"#{round(17 + @room_letters / 100 * 8 + max(0, @room_letters / 100 - 0.5) * 16)} pixels"}
        />
        <button id="room-close" type="button" phx-click="close_room" class="room-control">Done</button>
      </form>
    </div>

    <button
      id="landscape-toggle"
      type="button"
      phx-click="toggle_landscape"
      class={
        if @writing_controls,
          do: "quiet-link writing-menu-room-link",
          else: "place-whisper room-control"
      }
      title={region_label(@place.region)}
      aria-label={"Reveal the room, #{Still.Writing.Geography.reference_label(@place, Map.get(@place, :source_number))}"}
      aria-expanded={to_string(@landscape_open)}
      aria-controls="room-landscape"
      inert={@landscape_open}
      aria-hidden={if @landscape_open, do: "true"}
    >
      <span :if={!@writing_controls} class="place-name">{Still.Writing.Geography.reference_label(
        @place,
        Map.get(@place, :source_number)
      )}</span>
      <span :if={!@writing_controls && region_label(@place.region) != ""} class="place-region">{region_label(
        @place.region
      )}</span>
      <span :if={@writing_controls}>Explore the room</span>
    </button>
    """
  end
end

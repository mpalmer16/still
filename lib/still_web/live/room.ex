defmodule StillWeb.Room do
  @moduledoc "Shared room interactions, kept separate from the words being written."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  alias Still.Writing

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:room_light, Writing.room_light())
     |> assign(:light_open, false)
     |> assign(:room_letters, Writing.room_letters())
     |> assign(:letters_open, false)
     |> assign(:room_width, Still.Writing.Appearance.width())
     |> assign(:width_open, false)
     |> assign(:writing_menu_open, false)
     |> assign(:landscape_open, false)
     |> assign(:places, [])
     |> assign(:place, Writing.geography(nil))
     |> assign(:return_writing, Writing.current_writing())
     |> assign(:return_beside, Writing.current_beside())
     |> assign(:return_list, Writing.current_list_draft?())
     |> attach_hook(:room_events, :handle_event, &handle_event/3)}
  end

  defp handle_event("toggle_light", _params, socket) do
    opening = not socket.assigns.light_open

    {:halt,
     socket
     |> assign(:light_open, opening)
     |> assign(:letters_open, false)
     |> assign(:width_open, false)
     |> assign(:landscape_open, false)
     |> maybe_focus(opening, "room-light-angle")}
  end

  defp handle_event("toggle_letters", _params, socket) do
    opening = not socket.assigns.letters_open

    {:halt,
     socket
     |> assign(:letters_open, opening)
     |> assign(:light_open, false)
     |> assign(:width_open, false)
     |> assign(:landscape_open, false)
     |> maybe_focus(opening, "room-letters-size")}
  end

  defp handle_event("toggle_landscape", _params, socket) do
    opening = not socket.assigns.landscape_open

    {:halt,
     socket
     |> assign(:landscape_open, opening)
     |> assign(:light_open, false)
     |> assign(:letters_open, false)
     |> assign(:width_open, false)
     |> assign(:writing_menu_open, false)
     |> assign(:places, if(opening, do: Writing.places(), else: socket.assigns.places))
     |> assign(:return_writing, Writing.current_writing())
     |> assign(:return_beside, Writing.current_beside())
     |> maybe_focus(opening, "room-close")}
  end

  defp handle_event("close_room", _params, socket) do
    {:halt,
     socket
     |> assign(:light_open, false)
     |> assign(:letters_open, false)
     |> assign(:width_open, false)
     |> assign(:landscape_open, false)
     |> assign(:writing_menu_open, false)
     |> push_event("room-focus", editor_focus(socket))}
  end

  defp handle_event("toggle_writing_menu", _, socket) do
    if socket.assigns.writing_menu_open do
      close_writing_menu(socket)
    else
      {:halt,
       socket
       |> assign(:writing_menu_open, true)
       |> assign(:light_open, false)
       |> assign(:letters_open, false)
       |> assign(:width_open, false)
       |> assign(:landscape_open, false)
       |> push_event("room-focus", %{id: "writing-menu-close", clear_return: true})}
    end
  end

  defp handle_event("close_writing_menu", _, socket) do
    if socket.assigns.writing_menu_open, do: close_writing_menu(socket), else: {:halt, socket}
  end

  defp handle_event("change_light", %{"light" => %{"angle" => value}}, socket) do
    with {angle, ""} <- parse_integer(value),
         {:ok, saved} <- Writing.set_room_light(angle) do
      {:halt, assign(socket, :room_light, saved)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("change_light", _params, socket), do: {:halt, socket}

  defp handle_event("change_letters", %{"letters" => %{"size" => value}}, socket) do
    with {letters, ""} <- parse_integer(value),
         {:ok, saved} <- Writing.set_room_letters(letters) do
      {:halt,
       socket
       |> assign(:room_letters, saved)
       |> push_event("letters-changed", %{size: saved})}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("change_letters", _params, socket), do: {:halt, socket}

  defp handle_event("toggle_width", _, socket) do
    opening = not socket.assigns.width_open

    {:halt,
     socket
     |> assign(:width_open, opening)
     |> assign(:light_open, false)
     |> assign(:letters_open, false)
     |> assign(:landscape_open, false)
     |> maybe_focus(opening, "room-page-width")}
  end

  defp handle_event("change_width", %{"page" => %{"width" => value}}, socket) do
    with {width, ""} <- parse_integer(value),
         {:ok, saved} <- Still.Writing.Appearance.set_width(width) do
      {:halt,
       socket
       |> assign(:room_width, saved)
       |> push_event("writing-width-changed", %{width: saved})}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("change_width", _, socket), do: {:halt, socket}

  defp handle_event("reset_width", _, socket) do
    case Still.Writing.Appearance.set_width(0) do
      {:ok, _} ->
        {:halt,
         socket |> assign(:room_width, 0) |> push_event("writing-width-changed", %{width: 0})}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp close_writing_menu(socket) do
    {:halt,
     socket
     |> assign(:writing_menu_open, false)
     |> assign(:light_open, false)
     |> assign(:letters_open, false)
     |> assign(:width_open, false)
     |> push_event("room-focus", editor_focus(socket))}
  end

  defp editor_focus(socket) do
    if Map.get(socket.assigns, :editing, false) && Map.has_key?(socket.assigns, :piece),
      do: %{id: "file-writing-body", clear_return: true},
      else: %{}
  end

  defp parse_integer(value) when is_binary(value), do: Integer.parse(value)
  defp parse_integer(value) when is_integer(value), do: {value, ""}
  defp parse_integer(_value), do: :error

  defp maybe_focus(socket, true, id), do: push_event(socket, "room-focus", %{id: id})
  defp maybe_focus(socket, false, _id), do: push_event(socket, "room-focus", %{})
end

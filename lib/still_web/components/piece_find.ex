defmodule StillWeb.PieceFind do
  @moduledoc "A quiet, local Find control for one open piece."
  use StillWeb, :html

  @max_query_length 200

  def query(value), do: Still.Writing.Search.query(value) |> String.slice(0, @max_query_length)

  def match_count(text, query) when is_binary(text) do
    query = query(query)

    if query == "" do
      0
    else
      text
      |> Still.Writing.Search.parts(query)
      |> Enum.count(& &1.match)
    end
  end

  def match_count(_, _), do: 0

  def first_match_line(text, query) when is_binary(text) do
    query = query(query)

    if query == "" do
      nil
    else
      text
      |> String.split("\n", trim: false)
      |> Enum.find_index(&(match_count(&1, query) > 0))
      |> case do
        nil -> nil
        index -> index + 1
      end
    end
  end

  def first_match_line(_, _), do: nil

  attr :open, :boolean, required: true
  attr :query, :string, required: true
  attr :matches, :integer, required: true

  def panel(assigns) do
    ~H"""
    <div class="piece-find">
      <button
        :if={!@open}
        type="button"
        id="open-piece-find"
        class="quiet-link"
        phx-click="open_piece_find"
      >Find in this piece</button>
      <form
        :if={@open}
        id="piece-find-form"
        phx-change="find_in_piece"
        phx-submit="find_in_piece"
        role="search"
      >
        <label for="piece-find-query">Find in this piece</label>
        <input
          id="piece-find-query"
          type="search"
          name="piece_find[query]"
          value={@query}
          maxlength="200"
          autocomplete="off"
          phx-debounce="120"
        />
        <p id="piece-find-status" role="status" aria-live="polite">
          {cond do
            @query == "" -> "Type words to find them in this piece."
            @matches == 0 -> "No matches in this piece."
            @matches == 1 -> "1 matching word in this piece."
            true -> "#{@matches} matching words in this piece."
          end}
        </p>
        <button type="submit" class="quiet-link">Find</button>
        <button type="button" id="close-piece-find" class="quiet-link" phx-click="close_piece_find">
          Close
        </button>
      </form>
    </div>
    """
  end
end

defmodule StillWeb.CoreComponents do
  @moduledoc "Shared inputs for Still's two writing surfaces."
  use Phoenix.Component

  attr :field, Phoenix.HTML.FormField, required: true
  attr :type, :string, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(autocomplete autofocus placeholder spellcheck)

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <textarea id={@id || @field.id} name={@field.name} class={@class} {@rest}>{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
    """
  end

  def input(%{type: "search"} = assigns) do
    ~H"""
    <input
      type="search"
      id={@id || @field.id}
      name={@field.name}
      value={Phoenix.HTML.Form.normalize_value("search", @field.value)}
      class={@class}
      {@rest}
    />
    """
  end

  attr :text, :string, required: true

  def list_title(assigns) do
    assigns = assign(assigns, :words, String.split(assigns.text, ~r/(?<=:)/, trim: true))

    ~H"""
    <span :for={word <- @words} class="title-word">{word}</span>
    """
  end

  attr :text, :string, required: true
  attr :query, :string, default: ""

  def highlight(assigns) do
    assigns = assign(assigns, :parts, Still.Writing.Search.parts(assigns.text, assigns.query))

    ~H"""
    <span phx-no-format><%= for part <- @parts do %><mark :if={part.match}>{part.text}</mark><%= if !part.match do %>{part.text}<% end %><% end %></span>
    """
  end

  attr :body, :string, required: true
  attr :query, :string, default: ""
  attr :id_prefix, :string, default: nil
  attr :target_line, :integer, default: nil
  attr :start_line, :integer, default: 1
  attr :trim_terminal_line, :boolean, default: false

  def shaped_words(assigns) do
    lines = String.split(assigns.body, "\n", trim: false)

    lines =
      if assigns.trim_terminal_line && String.ends_with?(assigns.body, "\n"),
        do: Enum.drop(lines, -1),
        else: lines

    assigns = assign(assigns, :lines, Enum.with_index(lines, assigns.start_line))

    ~H"""
    <div
      :for={{line, index} <- @lines}
      id={if @id_prefix, do: "#{@id_prefix}-#{index}"}
      class="authored-line"
      data-authored-line
      data-search-target={if @target_line == index, do: "true"}
      tabindex={if @target_line == index, do: "-1"}
      style={line_indent(line)}
      phx-no-format
    ><.highlight text={line} query={@query} /></div>
    """
  end

  # The literal leading whitespace controls only how a soft wrap hangs.
  # No line is classified as a voice, branch, verse, or final passage.
  defp line_indent(line) do
    [prefix] = Regex.run(~r/^[\t ]*/, line)

    columns =
      prefix
      |> String.to_charlist()
      |> Enum.reduce(0, fn
        ?\t, column -> column + (8 - rem(column, 8))
        ?\s, column -> column + 1
      end)

    "--indent: #{columns * 0.25}em"
  end
end

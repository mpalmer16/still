defmodule Still.Writing.ListInterpretation do
  @moduledoc "A cautious, optional reading of a List's opening, never a text validator."

  @doc "Suggest a title while retaining the complete text and the untouched remaining body."
  def propose(body) when is_binary(body) do
    with [_, opening, _newline, remainder] <-
           Regex.run(~r/\A([^\r\n]+)(\r\n|\n|\r)([\s\S]*)\z/u, body),
         title = String.trim(opening),
         true <- title_line?(opening, title),
         {remaining_body, separated?} = after_separator(remainder),
         true <- list_shape?(remaining_body, separated?) do
      %{original_body: body, title: title, body: remaining_body}
    else
      _ -> nil
    end
  end

  defp title_line?(opening, title) do
    String.length(title) in 1..180 and
      length(String.split(title)) <= 20 and
      not Regex.match?(~r/\A\s|[:\r\n]|[.!?]\z/u, opening) and
      not bullet_line?(opening)
  end

  defp after_separator(remainder) do
    case Regex.run(~r/\A(?:[ \t]*(?:\r\n|\n|\r))+([\s\S]*)\z/u, remainder) do
      [_, body] -> {body, true}
      _ -> {remainder, false}
    end
  end

  defp list_shape?(body, separated?) do
    lines = body |> String.split(~r/\r\n|\n|\r/u) |> Enum.reject(&(String.trim(&1) == ""))

    case lines do
      [] ->
        false

      [first | _] ->
        colon_lines = Enum.count(lines, &colon_line?/1)
        bullet_lines = Enum.count(lines, &bullet_line?/1)

        # A blank boundary makes one clearly shaped line plausible. Without it,
        # require several items so a poem's opening is not casually made a title.
        (colon_line?(first) and (separated? or colon_lines >= 2)) or
          (bullet_line?(first) and (separated? or bullet_lines >= 2)) or
          (separated? and comma_line?(first))
    end
  end

  defp colon_line?(line) do
    text =
      line
      |> String.trim()
      |> String.replace(~r/\b(?:https?|file|mailto):\S*|\b\d{1,2}:\d{2}\b/iu, "")

    colons = text |> String.graphemes() |> Enum.count(&(&1 == ":"))

    colons >= 2 or
      (colons == 1 and String.ends_with?(text, ":") and
         length(String.split(text)) <= 8)
  end

  defp bullet_line?(line),
    do: Regex.match?(~r/\A[ \t]*(?:[-*+•–—]|\d+[.)])[ \t]+\S/u, line)

  defp comma_line?(line) do
    items = String.split(line, ",")

    length(items) >= 3 and not Regex.match?(~r/[.!?]/u, line) and
      Enum.all?(items, fn item ->
        item = String.trim(item)
        item != "" and length(String.split(item)) <= 7
      end)
  end
end

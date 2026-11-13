defmodule StillWeb.CalendarTime do
  @moduledoc "Formats validated 24-hour clock values for display."

  @doc """
  Formats an `HH:MM` value as a compact 12-hour time, or returns `nil` when
  there is no valid time to display.
  """
  def format(nil), do: nil
  def format(""), do: nil

  def format(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{2}):(\d{2})\z/, value) do
      [_, hour_text, minute_text] ->
        hour = String.to_integer(hour_text)
        minute = String.to_integer(minute_text)

        case Time.new(hour, minute, 0) do
          {:ok, _time} ->
            display_hour =
              case rem(hour, 12) do
                0 -> 12
                value -> value
              end

            period = if hour < 12, do: "am", else: "pm"
            "#{display_hour}:#{minute_text} #{period}"

          {:error, _reason} ->
            nil
        end

      _ ->
        nil
    end
  end

  def format(_), do: nil
end

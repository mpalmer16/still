defmodule Still.Writing.Appearance do
  @moduledoc "The writing room's local color and page width."
  alias Still.Appearance

  def color do
    "writing_color"
    |> Appearance.settings()
    |> Map.get("color")
    |> Appearance.color_or_default(:writing)
  end

  def set_color(color) do
    if Appearance.valid_color?(color, :writing) do
      with :ok <- Appearance.remember("writing_color", %{"color" => color}), do: {:ok, color}
    else
      {:error, :invalid_color}
    end
  end

  def width do
    case Appearance.settings("writing_width") do
      %{"width" => width} when width == 0 or width in 560..1600 -> width
      _ -> 0
    end
  end

  def set_width(width) when width == 0 or width in 560..1600 do
    with :ok <- Appearance.remember("writing_width", %{"width" => width}), do: {:ok, width}
  end

  def set_width(_), do: {:error, :invalid_width}
end

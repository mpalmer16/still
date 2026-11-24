defmodule Still.Correspondence.Appearance do
  @moduledoc "The remembered local colors of the correspondence room."

  alias Still.Appearance

  def choices, do: Appearance.choices(:dark)

  def current do
    data = Appearance.settings("correspondence")

    %{
      color: Appearance.color_or_default(data["color"], :dark),
      light?: data["light"] == true
    }
  end

  def choose_color(color) do
    if Appearance.valid_color?(color, :dark),
      do: remember(%{color: color, light?: false}),
      else: {:error, :invalid_color}
  end

  def set_light(light?) when is_boolean(light?),
    do: remember(%{current() | light?: light?})

  defp remember(appearance) do
    data = %{"color" => appearance.color, "light" => appearance.light?}

    with :ok <- Appearance.remember("correspondence", data), do: {:ok, appearance}
  end
end

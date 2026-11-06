defmodule Still.Correspondence.Appearance do
  @moduledoc "The remembered local colors of the correspondence room."

  alias Still.{LocalRecord, Repo}

  @colors ~w(graphite blue forest plum)

  def choices,
    do: [{"Graphite", "graphite"}, {"Night blue", "blue"}, {"Forest", "forest"}, {"Plum", "plum"}]

  def current do
    data =
      case Repo.get_by(LocalRecord,
             scope: "local",
             kind: "appearance",
             record_key: "correspondence"
           ) do
        %LocalRecord{data: data} when is_map(data) -> data
        _ -> %{}
      end

    %{
      color: if(data["color"] in @colors, do: data["color"], else: "graphite"),
      light?: data["light"] == true
    }
  end

  def choose_color(color) when color in @colors,
    do: remember(%{color: color, light?: false})

  def choose_color(_), do: {:error, :invalid_color}

  def set_light(light?) when is_boolean(light?),
    do: remember(%{current() | light?: light?})

  defp remember(appearance) do
    data = %{"color" => appearance.color, "light" => appearance.light?}

    case Repo.insert(
           %LocalRecord{
             scope: "local",
             kind: "appearance",
             record_key: "correspondence",
             data: data
           },
           on_conflict: [set: [data: data, updated_at: DateTime.utc_now()]],
           conflict_target: [:scope, :kind, :record_key]
         ) do
      {:ok, _} -> {:ok, appearance}
      {:error, reason} -> {:error, reason}
    end
  end
end

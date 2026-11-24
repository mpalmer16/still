defmodule Still.Appearance do
  @moduledoc "Palette choices and local appearance preferences shared by both rooms."

  alias Still.{LocalRecord, Repo}

  @dark_choices [
    {"Graphite", "graphite"},
    {"Sepia", "sepia"},
    {"Night blue", "blue"},
    {"Forest", "forest"},
    {"Plum", "plum"}
  ]

  def choices(:dark), do: @dark_choices
  def choices(:writing), do: @dark_choices ++ [{"Light", "light"}]

  def valid_color?(color, mode), do: Enum.any?(choices(mode), fn {_, value} -> value == color end)

  def color_or_default(color, mode) do
    if valid_color?(color, mode), do: color, else: "graphite"
  end

  def settings(key) do
    case Repo.get_by(LocalRecord, scope: "local", kind: "appearance", record_key: key) do
      %LocalRecord{data: data} when is_map(data) -> data
      _ -> %{}
    end
  end

  def remember(key, data) do
    case Repo.insert(
           %LocalRecord{scope: "local", kind: "appearance", record_key: key, data: data},
           on_conflict: [set: [data: data, updated_at: DateTime.utc_now()]],
           conflict_target: [:scope, :kind, :record_key]
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end
end

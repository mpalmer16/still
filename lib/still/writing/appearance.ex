defmodule Still.Writing.Appearance do
  @moduledoc "The writer's local page width, independent of words and reading type size."
  alias Still.{LocalRecord, Repo}

  def width do
    case Repo.get_by(LocalRecord, scope: "local", kind: "appearance", record_key: "writing_width") do
      %{data: %{"width" => width}} when width == 0 or width in 560..1600 -> width
      _ -> 0
    end
  end

  def set_width(width) when width == 0 or width in 560..1600 do
    data = %{"width" => width}

    case Repo.insert(
           %LocalRecord{
             scope: "local",
             kind: "appearance",
             record_key: "writing_width",
             data: data
           },
           on_conflict: [set: [data: data, updated_at: DateTime.utc_now()]],
           conflict_target: [:scope, :kind, :record_key]
         ) do
      {:ok, _} -> {:ok, width}
      error -> error
    end
  end

  def set_width(_), do: {:error, :invalid_width}
end

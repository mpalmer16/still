defmodule Still.Writing.RoomState do
  @moduledoc false
  use Ecto.Schema

  schema "room_states" do
    field :recent, :map, default: %{}
    field :light, :integer, default: 38
    field :letters, :integer, default: 50
    belongs_to :writing, Still.Writing.Entry
    belongs_to :draft_beside, Still.Writing.Entry
  end
end

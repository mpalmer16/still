defmodule Still.Repo.Migrations.GiveTheRoomLetters do
  use Ecto.Migration

  def change do
    alter table(:room_states) do
      add :letters, :integer, null: false, default: 50
    end
  end
end

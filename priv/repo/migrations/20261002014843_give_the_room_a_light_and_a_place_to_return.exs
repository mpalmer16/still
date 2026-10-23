defmodule Still.Repo.Migrations.GiveTheRoomALightAndAPlaceToReturn do
  use Ecto.Migration

  def change do
    alter table(:room_states) do
      add :light, :integer, null: false, default: 38
      add :writing_id, references(:entries, on_delete: :nilify_all)
    end
  end
end

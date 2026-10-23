defmodule Still.Repo.Migrations.RememberTheUnsavedWritingSpace do
  use Ecto.Migration

  def change do
    alter table(:room_states) do
      add :draft_beside_id, references(:entries, on_delete: :nilify_all)
    end
  end
end

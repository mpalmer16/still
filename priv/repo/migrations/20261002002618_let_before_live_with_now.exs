defmodule Still.Repo.Migrations.LetBeforeLiveWithNow do
  use Ecto.Migration

  def change do
    alter table(:entries) do
      add :title, :text
      add :origin, :string, null: false, default: "now"
      add :source_key, :string
      add :source_group, :string
      add :notebook, :string
      add :source_order, :integer
      add :source, :map, null: false, default: %{}
      add :returned_at, :utc_datetime_usec
      add :beside_id, references(:entries, on_delete: :nilify_all)
    end

    create unique_index(:entries, [:source_key])
    create index(:entries, [:source_group])
    create index(:entries, [:notebook, :source_order])
    create index(:entries, [:beside_id])

    alter table(:versions) do
      add :title, :text
    end

    create table(:room_states) do
      add :recent, :map, null: false, default: %{}
    end
  end
end

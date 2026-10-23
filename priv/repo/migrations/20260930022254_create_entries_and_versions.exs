defmodule Still.Repo.Migrations.CreateEntriesAndVersions do
  use Ecto.Migration

  def change do
    create table(:entries) do
      add :body, :text, null: false
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create index(:entries, [:inserted_at])

    create table(:versions) do
      add :entry_id, references(:entries, on_delete: :restrict), null: false
      add :body, :text, null: false
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:versions, [:entry_id, :inserted_at])
  end
end

defmodule Still.Repo.Migrations.OrdinaryFilesAndLocalRecords do
  use Ecto.Migration

  def change do
    create table(:collection_folders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :root, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:collection_folders, [:root])

    create table(:notebooks) do
      add :key, :string, null: false
      add :label, :string, null: false
      add :series, :string
      add :year, :integer
      add :number_label, :string
      add :description, :text
      add :pen, :text
      add :current, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notebooks, [:key])
    create unique_index(:notebooks, [:current], where: "current = 1", name: :one_current_notebook)

    alter table(:entries) do
      add :file_id, :string
      add :collection_scope, :string
      add :relative_path, :text
      add :file_token, :string
      add :file_prefix, :binary, default: <<>>
      add :title_line, :integer
      add :title_anchor, :text
      add :title_needs_review, :boolean, default: false, null: false
      add :file_missing, :boolean, default: false, null: false
      add :trashed, :boolean, default: false, null: false
      add :pending, :map
      add :notebook_id, references(:notebooks, on_delete: :restrict)
      add :list_label, :string
    end

    create unique_index(:entries, [:file_id])
    create unique_index(:entries, [:collection_scope, :relative_path])
    create index(:entries, [:notebook_id])

    alter table(:versions) do
      add :file_prefix, :binary, default: <<>>
      add :title_line, :integer
      add :title_anchor, :text
    end

    create table(:local_records) do
      add :scope, :string, null: false
      add :kind, :string, null: false
      add :record_key, :string, null: false
      add :data, :map, default: %{}, null: false
      add :bytes, :binary
      add :lock_version, :integer, default: 1, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_records, [:scope, :kind, :record_key])
  end
end

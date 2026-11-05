defmodule Still.Repo.Migrations.AddNotebookNumberingChoice do
  use Ecto.Migration

  def change do
    alter table(:notebooks) do
      add :numbered, :boolean, default: true, null: false
    end
  end
end

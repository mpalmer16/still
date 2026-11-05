defmodule Still.Repo.Migrations.BindNotebooksToFolders do
  use Ecto.Migration

  def change do
    alter table(:notebooks) do
      add :collection_scope, :string
      add :relative_path, :text
      add :folder_identity, :string
    end

    create unique_index(:notebooks, [:collection_scope, :relative_path],
             where: "collection_scope IS NOT NULL AND relative_path IS NOT NULL",
             name: :notebooks_scope_path
           )

    create unique_index(:notebooks, [:collection_scope, :folder_identity],
             where: "collection_scope IS NOT NULL AND folder_identity IS NOT NULL",
             name: :notebooks_scope_identity
           )
  end
end

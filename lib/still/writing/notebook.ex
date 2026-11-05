defmodule Still.Writing.Notebook do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "notebooks" do
    field :key, :string
    field :label, :string
    field :series, :string
    field :year, :integer
    field :number_label, :string
    field :description, :string
    field :pen, :string
    field :current, :boolean, default: false
    field :numbered, :boolean, default: true
    field :collection_scope, :string
    field :relative_path, :string
    field :folder_identity, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(notebook, attrs) do
    notebook
    |> cast(attrs, [
      :key,
      :label,
      :series,
      :year,
      :number_label,
      :description,
      :pen,
      :current,
      :numbered,
      :collection_scope,
      :relative_path,
      :folder_identity
    ])
    |> validate_required([:key, :label])
    |> validate_length(:key, max: 1_024)
    |> validate_length(:label, max: 200)
    |> validate_length(:series, max: 200)
    |> validate_length(:number_label, max: 100)
    |> validate_length(:description, max: 10_000)
    |> validate_length(:pen, max: 500)
    |> validate_number(:year, greater_than: 0, less_than: 10_000)
    |> unique_constraint(:key)
    |> unique_constraint(:current, name: :one_current_notebook)
    |> unique_constraint([:collection_scope, :relative_path], name: :notebooks_scope_path)
    |> unique_constraint([:collection_scope, :folder_identity], name: :notebooks_scope_identity)
  end
end

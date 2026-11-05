defmodule Still.Writing.CollectionFolder do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "collection_folders" do
    field :root, :string
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Still.LocalRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  schema "local_records" do
    field(:scope, :string)
    field(:kind, :string)
    field(:record_key, :string)
    field(:data, :map)
    field(:bytes, :binary)
    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:scope, :kind, :record_key, :data, :bytes, :lock_version])
    |> validate_required([:scope, :kind, :record_key, :data, :lock_version])
    |> unique_constraint([:scope, :kind, :record_key])
  end
end

defmodule Still.Writing.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "entries" do
    field :title, :string
    field :body, :string
    field :origin, :string, default: "now"
    field :source_key, :string
    field :source_group, :string
    field :notebook, :string
    field :source_order, :integer
    field :source, :map, default: %{}
    field :returned_at, :utc_datetime_usec
    belongs_to :beside, __MODULE__
    field :lock_version, :integer, default: 1
    has_many :versions, Still.Writing.Version
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :title,
      :body,
      :origin,
      :source_key,
      :source_group,
      :notebook,
      :source_order,
      :source,
      :beside_id
    ])
    |> validate_required([:body])
    |> validate_length(:body, max: 100_000)
    |> validate_length(:title, max: 1_000)
    |> validate_inclusion(:origin, ["now", "before"])
    |> unique_constraint(:source_key)
    |> foreign_key_constraint(:beside_id)
  end
end

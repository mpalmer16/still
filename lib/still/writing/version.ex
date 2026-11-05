defmodule Still.Writing.Version do
  use Ecto.Schema

  schema "versions" do
    field :title, :string
    field :body, :string
    field :file_prefix, :binary, default: <<>>
    field :title_line, :integer
    field :title_anchor, :string
    belongs_to :entry, Still.Writing.Entry
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end

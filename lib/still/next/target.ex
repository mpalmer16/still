defmodule Still.Next.Target do
  @moduledoc "Stable references from tasks into the active Correspondence collection."
  alias Still.{Correspondence, Poems}
  alias Still.Correspondence.{Calendar, Funding, FundingApplications}

  def parse(type, id)
      when type in ~w(piece journal packet event funding funding_application) and
             byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> %{type: type, id: uuid}
      :error -> nil
    end
  end

  def parse(_, _), do: nil

  def label(location, %{type: type, id: id}) do
    case find(location, type, id) do
      {:ok, item} ->
        case type do
          "piece" -> Poems.display_title(item)
          type when type in ["journal", "funding"] -> item.name
          "funding_application" -> item["title"]
          _ -> item.title
        end

      {:error, _} ->
        nil
    end
  end

  def kind("piece"), do: "Work"
  def kind("journal"), do: "Place"
  def kind("packet"), do: "Packet"
  def kind("event"), do: "Calendar event"
  def kind("funding_application"), do: "Funding application"
  def kind("funding"), do: "Funding opportunity"

  defp find(location, "piece", id), do: Poems.get(location, id)
  defp find(location, "journal", id), do: Correspondence.journal(location, id)
  defp find(location, "packet", id), do: Correspondence.packet(location, id)
  defp find(location, "event", id), do: Calendar.get(location, id)
  defp find(location, "funding_application", id), do: FundingApplications.get(location, id)
  defp find(location, "funding", id), do: Funding.get(location, id)
end

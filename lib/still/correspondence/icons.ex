defmodule Still.Correspondence.Icons do
  @moduledoc "Collection-local icon copies. Journal words and their edit tokens never change."
  alias Still.Correspondence
  alias Still.Correspondence.IconFetcher

  def source_key(journal) do
    Jason.encode!([Map.get(journal, :icon_url), Map.get(journal, :website)]) |> digest()
  end

  def candidates(journal) do
    fallback =
      case Map.get(journal, :website) do
        site when is_binary(site) and site != "" ->
          [URI.merge(site, "/favicon.ico") |> URI.to_string()]

        _ ->
          []
      end

    [Map.get(journal, :icon_url) | fallback]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  def cached(location, journal) do
    case Correspondence.read_icon_cache(location, journal) do
      {:ok, cache} -> decode(cache)
      _ -> :missing
    end
  end

  def ensure(location, journal, fetcher \\ &IconFetcher.fetch/1) do
    if candidates(journal) == [], do: nil, else: ensure_cache(location, journal, fetcher)
  end

  defp ensure_cache(location, journal, fetcher) do
    case cached(location, journal) do
      {:ok, uri} ->
        uri

      :unavailable ->
        nil

      :missing ->
        result =
          Enum.find_value(candidates(journal), fn url ->
            case fetcher.(url) do
              {:ok, %{bytes: bytes}} ->
                case IconFetcher.raster(bytes) do
                  {:ok, image} -> image
                  _ -> nil
                end

              _ ->
                nil
            end
          end)

        cache =
          if result do
            %{
              "mime" => result.mime,
              "data" => Base.encode64(result.bytes),
              "sha256" => digest(result.bytes)
            }
          else
            %{"retry_after" => System.system_time(:second) + 86_400}
          end

        case Correspondence.write_icon_cache(location, journal, cache) do
          :ok ->
            case decode(cache) do
              {:ok, uri} -> uri
              _ -> nil
            end

          _ ->
            nil
        end
    end
  rescue
    _ -> nil
  end

  defp decode(%{"mime" => mime, "data" => encoded, "sha256" => expected})
       when is_binary(encoded) and byte_size(encoded) <= 349_528 do
    with {:ok, bytes} <- Base.decode64(encoded),
         true <- digest(bytes) == expected,
         {:ok, %{mime: ^mime}} <- IconFetcher.raster(bytes) do
      {:ok, "data:#{mime};base64,#{encoded}"}
    else
      _ -> :missing
    end
  end

  defp decode(%{"retry_after" => timestamp}) when is_integer(timestamp) do
    if timestamp > System.system_time(:second), do: :unavailable, else: :missing
  end

  defp decode(_), do: :missing

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

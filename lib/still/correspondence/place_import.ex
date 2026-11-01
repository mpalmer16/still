defmodule Still.Correspondence.PlaceImport do
  @moduledoc "Add-only JSON import with validation, preview, and collection-scoped writes."
  alias Still.Correspondence

  @max_bytes 1_048_576
  @max_places 200
  @fields ~w(name website submission_url interests guidelines windows fee simultaneous_policy response_expectation notes shortlisted keywords reach reach_note icon_url description)

  def example do
    Jason.encode!(
      [
        %{
          name: "Example Poetry Review",
          description: "An independent journal of poetry and short prose.",
          website: "https://example.org",
          icon_url: "https://example.org/favicon.ico",
          submission_url: "https://example.org/submit",
          interests: "Poetry and short prose",
          keywords: "landscape, memory, rural life",
          reach: "stretch",
          reach_note: "A personal impression; read a recent issue before choosing.",
          guidelines: "Up to three poems. Check the publication's current guidelines.",
          windows: "Unknown — check the publication",
          fee: "",
          simultaneous_policy: "unknown",
          response_expectation: "",
          notes: "A place to consider. Details still need checking.",
          shortlisted: false
        }
      ],
      pretty: true
    )
  end

  def parse(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    case Jason.decode(bytes) do
      {:ok, rows} when is_list(rows) and length(rows) in 1..@max_places ->
        rows
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
          case validate(row) do
            {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
            {:error, reason} -> {:halt, {:error, "Place #{index}: #{reason}"}}
          end
        end)
        |> case do
          {:ok, rows} -> {:ok, Enum.reverse(rows)}
          error -> error
        end

      {:ok, _} ->
        {:error, "Use a JSON array containing between 1 and #{@max_places} places."}

      {:error, _} ->
        {:error, "This file is not valid UTF-8 JSON. Use the example below."}
    end
  end

  def parse(_), do: {:error, "Choose a JSON file no larger than 1 MB."}

  def preview(location, bytes) do
    with {:ok, rows} <- parse(bytes),
         {:ok, existing} <- Correspondence.journals(location) do
      {new, skipped, _names} =
        Enum.reduce(rows, {[], [], MapSet.new(existing, &key(&1.name))}, fn row,
                                                                            {new, skipped, names} ->
          name = key(row.name)

          if MapSet.member?(names, name),
            do: {new, [row.name | skipped], names},
            else: {[row | new], skipped, MapSet.put(names, name)}
        end)

      {:ok, %{location: location, places: Enum.reverse(new), skipped: Enum.reverse(skipped)}}
    end
  end

  @doc "Adds reviewed places. On a write failure, reports completed work; retrying never overwrites it."
  def commit(%{location: location, places: places, skipped: skipped}) do
    initial = %{imported: [], skipped: skipped, error: nil}

    Enum.reduce_while(places, initial, fn place, result ->
      case add(location, place) do
        {:ok, _} -> {:cont, %{result | imported: result.imported ++ [place.name]}}
        :duplicate -> {:cont, %{result | skipped: result.skipped ++ [place.name]}}
        {:error, reason} -> {:halt, %{result | error: "Could not add #{place.name}: #{reason}"}}
      end
    end)
  end

  defp add(location, place) do
    with {:ok, existing} <- Correspondence.journals(location) do
      if Enum.any?(existing, &(key(&1.name) == key(place.name))) do
        :duplicate
      else
        case Correspondence.save_journal(location, place) do
          {:error, "A journal with this name already exists."} -> :duplicate
          result -> result
        end
      end
    end
  end

  defp validate(row) when is_map(row) do
    unknown = Map.keys(row) -- @fields

    cond do
      Enum.any?(row, fn {field, value} -> field != "shortlisted" && !is_binary(value) end) ->
        {:error, "Text fields must be JSON strings; omit unknown details or use an empty string."}

      unknown != [] ->
        {:error, "Unsupported fields: #{Enum.join(Enum.sort(unknown), ", ")}."}

      Map.has_key?(row, "shortlisted") and !is_boolean(row["shortlisted"]) ->
        {:error, "shortlisted must be true or false."}

      Map.has_key?(row, "simultaneous_policy") and
          row["simultaneous_policy"] not in ["unknown", "allowed", "not_allowed"] ->
        {:error, "simultaneous_policy must be unknown, allowed, or not_allowed."}

      true ->
        row =
          Enum.reduce(["website", "submission_url"], row, fn field, acc ->
            if acc[field] == "", do: Map.put(acc, field, nil), else: acc
          end)

        Correspondence.validate_journal(Map.put(row, "verified", false))
    end
  end

  defp validate(_), do: {:error, "Each place must be a JSON object with a name."}
  defp key(name), do: name |> String.trim() |> String.downcase()
end

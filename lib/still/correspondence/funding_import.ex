defmodule Still.Correspondence.FundingImport do
  @moduledoc "Reviewed add-only JSON import for local funding opportunities."
  alias Still.Repo
  alias Still.Correspondence.Funding
  alias Still.Writing.CollectionLock

  @max_bytes 1_048_576
  @max_rows 200
  @structured_fields ~w(opens_on prepare_on deadline deadline_time timezone application_url source_url checked_on)

  def example do
    Jason.encode!(
      [
        %{
          "name" => "Example Writers Grant",
          "funder" => "Example Arts Council",
          "kind" => "grant",
          "cycle" => "2027",
          "deadline" => "2027-02-01",
          "source_url" => "https://example.org/grants",
          "checked_on" => "2026-11-18",
          "highlighted" => false
        }
      ],
      pretty: true
    )
  end

  def parse(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, rows} when is_list(rows) and length(rows) in 1..@max_rows <- Jason.decode(bytes),
         {:ok, attrs} <- validate_rows(rows, &validate_json_row/1) do
      {:ok, attrs}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, %Jason.DecodeError{}} -> {:error, "This file is not valid UTF-8 JSON."}
      _ -> {:error, "Choose a JSON array with between 1 and #{@max_rows} opportunities."}
    end
  end

  def parse(_), do: {:error, "Choose a JSON file no larger than 1 MB."}

  def preview(location, bytes) do
    with {:ok, rows} <- parse(bytes),
         {:ok, saved} <- Funding.list(location) do
      saved_keys = MapSet.new(saved, &Funding.identity/1)

      {opportunities, skipped, _seen} =
        Enum.reduce(rows, {[], [], MapSet.new()}, fn row, {new, skip, seen} ->
          key = Funding.identity(row)

          cond do
            MapSet.member?(seen, key) ->
              {new, [%{name: row["name"], reason: "Duplicate row in this file"} | skip], seen}

            MapSet.member?(saved_keys, key) ->
              {new, [%{name: row["name"], reason: "Already in this collection"} | skip],
               MapSet.put(seen, key)}

            true ->
              {[Funding.atomize(row) | new], skip, MapSet.put(seen, key)}
          end
        end)

      {:ok,
       %{
         location: location,
         opportunities: Enum.reverse(opportunities),
         skipped: Enum.reverse(skipped)
       }}
    end
  end

  def commit(%{location: location, opportunities: rows, skipped: skipped})
      when is_list(rows) and is_list(skipped) do
    with {:ok, scope} <- Funding.active_scope(location),
         {:ok, normalized} <- validate_plan(rows, skipped) do
      CollectionLock.with_lock(Repo.config()[:database], fn ->
        result =
          Repo.transaction(fn ->
            with {:ok, ^scope} <- Funding.active_scope(location),
                 {:ok, current} <- Funding.list(location) do
              current_keys = MapSet.new(current, &Funding.identity/1)

              {added, raced} =
                Enum.split_with(normalized, fn row ->
                  not MapSet.member?(current_keys, Funding.identity(row))
                end)

              Enum.each(added, &Funding.insert_import!(scope, stringify(&1)))

              %{
                imported: Enum.map(added, & &1.name),
                skipped: Enum.map(skipped, & &1.name) ++ Enum.map(raced, & &1.name)
              }
            else
              {:error, message} ->
                Repo.rollback({:error, message})

              _ ->
                Repo.rollback(
                  {:error, "The selected collection changed. Review the import again."}
                )
            end
          end)

        case result do
          {:ok, value} -> {:ok, value}
          {:error, {:error, message}} -> {:error, message}
          _ -> {:error, "The selected collection changed during import. Review the file again."}
        end
      end)
    end
  end

  def commit(_), do: {:error, "Review this funding import again before applying it."}

  defp validate_rows(rows, validate) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case validate.(row) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        {:error, reason} -> {:halt, {:error, "Opportunity #{index}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp unique_rows(rows) do
    keys = Enum.map(rows, &Funding.identity/1)

    if length(keys) == MapSet.size(MapSet.new(keys)),
      do: :ok,
      else: {:error, "Duplicate opportunities in the reviewed plan."}
  end

  defp validate_plan(rows, skipped) do
    with true <-
           Enum.all?(
             skipped,
             &match?(%{name: name, reason: reason} when is_binary(name) and is_binary(reason), &1)
           ),
         {:ok, normalized} <- validate_rows(rows, &Funding.validate/1),
         :ok <- unique_rows(normalized) do
      {:ok, Enum.map(normalized, &Funding.atomize/1)}
    else
      _ -> {:error, "Review this funding import again before applying it."}
    end
  end

  defp stringify(row), do: Map.new(row, fn {key, value} -> {to_string(key), value} end)

  defp validate_json_row(row) when is_map(row) do
    invalid_type? =
      Enum.any?(row, fn
        {"highlighted", value} -> not is_boolean(value)
        {_key, value} -> not is_binary(value)
      end)

    cond do
      invalid_type? ->
        {:error, "Use JSON strings for text fields and a JSON boolean for highlighted."}

      Enum.any?(@structured_fields, &(row[&1] == "")) ->
        {:error, "Omit unknown dates, times, and URLs."}

      true ->
        Funding.validate(row)
    end
  end

  defp validate_json_row(_), do: {:error, "Each funding opportunity must be an object."}
end

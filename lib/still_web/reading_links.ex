defmodule StillWeb.ReadingLinks do
  @moduledoc "Build safe, local links between focused reading and its source."

  alias Still.Writing.{Entry, ReadingPlace}

  @reader_keys ["from", "notebook", "q", "earlier", "shown", "at", "version", "written"]

  def reader(entry_or_id, context \\ %{}) do
    id = id(entry_or_id)

    build_reader_path(
      id,
      normalized(entry_or_id, context),
      notebook_reader?(entry_or_id, context)
    )
  end

  @doc "Build a link from a verified Find result without querying each earlier version again."
  def find_result(%{entry: %Entry{} = entry, version: version}, context) do
    context = Map.put(context, "version", if(version, do: version.id))
    build_reader_path(entry.id, context, notebook_reader?(entry, context))
  end

  defp build_reader_path(id, context, notebook?) do
    params =
      context
      |> Map.take(@reader_keys)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == false end)

    query = URI.encode_query(params)
    base = if notebook?, do: "/notebooks/read/#{id}", else: "/read/#{id}"
    base <> if(query == "", do: "", else: "?" <> query)
  end

  def notebook_reader?(%Entry{} = entry, context) do
    context_value(context, "from") == "notebook" or
      (is_binary(entry.notebook) and String.trim(entry.notebook) != "") or
      is_integer(entry.notebook_id)
  end

  def notebook_reader?(_, context), do: context_value(context, "from") == "notebook"

  def resume(%{entry: entry, context: context}), do: reader(entry, context)
  def resume(_), do: nil

  def origin(%{entry: entry, context: context}) do
    case context_value(context, "from") do
      "notebook" ->
        key = context_value(context, "notebook")

        if is_binary(key) and key != "" do
          "/notebooks?" <>
            URI.encode_query(%{"notebook" => key, "at" => to_string(id(entry))}) <>
            "#list-#{id(entry)}"
        else
          "/notebooks"
        end

      _ ->
        params = %{
          "q" => context_value(context, "q") || "",
          "shown" => to_string(context_value(context, "shown") || 40),
          "at" => context_value(context, "at") || "current-#{id(entry)}"
        }

        params =
          if truthy?(context_value(context, "earlier")),
            do: Map.put(params, "earlier", "1"),
            else: params

        params =
          if truthy?(context_value(context, "written")),
            do: Map.put(params, "written", "1"),
            else: params

        "/pages?" <> URI.encode_query(params) <> "#results-#{safe_anchor(params["at"])}"
    end
  end

  def origin(_), do: "/pages"

  def wander(entry_or_id, context \\ %{}) do
    id = id(entry_or_id)
    params = [read: "1"]
    params = add(params, :q, context_value(context, "q"))

    params =
      if truthy?(context_value(context, "earlier")), do: params ++ [earlier: "1"], else: params

    params = add(params, :version, context_value(context, "version"))

    params =
      if truthy?(context_value(context, "written")), do: params ++ [written: "1"], else: params

    "/w/#{id}?" <> URI.encode_query(params)
  end

  defp normalized(%Entry{} = entry, context), do: ReadingPlace.context(entry, context)
  defp normalized(_entry, context) when is_map(context), do: context
  defp normalized(_, _), do: %{}
  defp id(%Entry{id: id}), do: id
  defp id(id) when is_integer(id) and id > 0, do: id

  defp id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> n
      _ -> 0
    end
  end

  defp id(_), do: 0

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key, Map.get(context, String.to_atom(key)))

  defp context_value(_, _), do: nil
  defp truthy?(v), do: v in [true, "true", "1", 1]
  defp add(params, _key, value) when value in [nil, ""], do: params
  defp add(params, key, value), do: params ++ [{key, value}]

  defp safe_anchor(value) when is_binary(value),
    do: String.replace(value, ~r/[^A-Za-z0-9_-]/, "-")

  defp safe_anchor(_), do: "current"
end

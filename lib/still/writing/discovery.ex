defmodule Still.Writing.Discovery do
  @moduledoc "One verified file projection for a reading operation, never a timed cache."

  alias Still.{Repo, Storage}
  alias Still.Writing.Files

  @key {__MODULE__, :snapshot}
  @memo_key {__MODULE__, :memo}

  def memo(key, fun) do
    case Process.get(@memo_key) do
      nil ->
        fun.()

      values ->
        case Map.fetch(values, key) do
          {:ok, value} ->
            value

          :error ->
            value = fun.()
            Process.put(@memo_key, Map.put(values, key, value))
            value
        end
    end
  end

  def with_snapshot(fun, opts \\ []) when is_function(fun, 0) do
    location = Storage.collection_location()
    recover? = Keyword.get(opts, :recover, false)

    case current(location, recover: recover?) do
      {:ok, _} ->
        fun.()

      :none ->
        previous = Process.get(@key)
        previous_memo = Process.get(@memo_key)
        Process.put(@memo_key, %{})

        {scope, problem} =
          cond do
            not location.configured ->
              {nil, nil}

            not location.available ->
              {nil, location.error || "The selected writing folder is unavailable."}

            true ->
              case Files.synchronize(location, recover: recover?) do
                {:ok, _} -> {location.scope, nil}
                {:error, message} -> {nil, message}
              end
          end

        Process.put(
          @key,
          {Repo.config()[:database], location.scope, location.available, scope, problem, recover?}
        )

        try do
          fun.()
        after
          if previous, do: Process.put(@key, previous), else: Process.delete(@key)

          if previous_memo,
            do: Process.put(@memo_key, previous_memo),
            else: Process.delete(@memo_key)
        end
    end
  end

  def current(location) do
    current(location, [])
  end

  def current(location, opts) do
    recover? = Keyword.get(opts, :recover, false)

    case Process.get(@key) do
      {database, selected_scope, available, verified_scope, _problem, verified_recovery?}
      when selected_scope == location.scope and available == location.available ->
        if database == Repo.config()[:database] and (not recover? or verified_recovery?),
          do: {:ok, verified_scope},
          else: :none

      _ ->
        :none
    end
  end

  def problem(location \\ Storage.collection_location()) do
    case {current(location), Process.get(@key)} do
      {{:ok, _}, {_, _, _, _, problem, _}} -> problem
      _ -> nil
    end
  end
end

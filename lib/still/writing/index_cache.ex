defmodule Still.Writing.IndexCache do
  @moduledoc "A bounded, process-shared cache for derived writing indexes."
  use GenServer

  @table __MODULE__
  @max_keys 20_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a cached derived value and its exact source stamp, if present."
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, stamp, value, _used}] ->
        {stamp, value}

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Stores a derived value. Source stamps are supplied by the caller."
  def put(key, stamp, value) do
    GenServer.call(__MODULE__, {:put, key, stamp, value})
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{table: table, sequence: 0}}
  end

  @impl true
  def handle_call({:put, key, stamp, value}, _from, state) do
    sequence = state.sequence + 1
    true = :ets.insert(@table, {key, stamp, value, sequence})
    evict_if_needed(sequence)
    {:reply, value, %{state | sequence: sequence}}
  end

  defp evict_if_needed(sequence) do
    size = :ets.info(@table, :size)

    if size > @max_keys do
      count = max(div(@max_keys, 20), 1)

      @table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 3))
      |> Enum.take(count)
      |> Enum.each(fn {key, _stamp, _value, _used} -> :ets.delete(@table, key) end)
    end

    sequence
  end
end

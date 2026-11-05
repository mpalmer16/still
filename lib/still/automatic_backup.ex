defmodule Still.AutomaticBackup do
  @moduledoc "Refreshes the local database backup periodically during a Mac app session."
  use GenServer, shutdown: 10_000
  require Logger

  @initial_delay :timer.minutes(1)
  @interval :timer.minutes(5)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :check, @initial_delay)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, previous_error) do
    error =
      case Still.Storage.backup_if_needed() do
        {:error, reason} -> reason
        _ -> nil
      end

    if error && error != previous_error, do: Logger.warning("Automatic backup: #{error}")

    Process.send_after(self(), :check, @interval)
    {:noreply, error}
  end

  # The backup opens short-lived linked SQLite connections.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
end

defmodule Still.Writing.CollectionLock do
  @moduledoc """
  A process-owned SQLite advisory lock for filesystem operations tied to a database.

  The lock database contains no application data. It is deliberately retained after
  release so another process can never lock a different inode after a cleanup race.
  SQLite releases the transaction lock when its connection process exits.
  """

  @busy_timeout 1_000
  @retry_delay 100
  @wait_timeout 5_000

  def with_lock(database, fun) when is_binary(database) and is_function(fun, 0) do
    with {:ok, lock_path} <- lock_path(database) do
      key = {__MODULE__, lock_path}

      if Process.get(key) do
        fun.()
      else
        Process.put(key, true)

        try do
          lock_and_run(lock_path, fun)
        after
          Process.delete(key)
        end
      end
    end
  rescue
    error ->
      {:error, "Could not safely access this collection: #{Exception.message(error)}"}
  end

  defp lock_path(database) do
    canonical = canonical_path(database)

    directory = Path.dirname(canonical)

    if File.dir?(directory) do
      name = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
      {:ok, Path.join(directory, ".still-writing-#{name}.lock.sqlite3")}
    else
      {:error, "The local database folder is unavailable."}
    end
  end

  defp canonical_path(path) do
    Path.expand(path)
    |> Path.split()
    |> Enum.reduce("", fn part, parent ->
      candidate = if parent == "", do: part, else: Path.join(parent, part)

      case :file.read_link_all(String.to_charlist(candidate)) do
        {:ok, target} -> Path.expand(List.to_string(target), parent)
        _ -> candidate
      end
    end)
  end

  defp lock_and_run(path, fun) do
    with {:ok, connection} <- start_connection(path) do
      case acquire(connection, System.monotonic_time(:millisecond)) do
        :ok ->
          try do
            fun.()
          after
            release(connection)
            stop_connection(connection)
          end

        error ->
          stop_connection(connection)
          error
      end
    end
  end

  defp start_connection(path) do
    with :ok <- ensure_lock_file(path) do
      case Exqlite.start_link(database: path, mode: :readwrite, busy_timeout: @busy_timeout) do
        {:ok, connection} -> {:ok, connection}
        {:error, error} -> {:error, "Could not open the collection lock: #{inspect(error)}"}
      end
    end
  end

  defp ensure_lock_file(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %{type: :regular}} -> :ok
          _ -> {:error, "The collection lock path is not an ordinary file."}
        end

      {:error, reason} ->
        {:error, "Could not create the collection lock: #{:file.format_error(reason)}"}
    end
  end

  defp acquire(connection, started_at) do
    case Exqlite.query(connection, "BEGIN IMMEDIATE") do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        if busy?(error) and System.monotonic_time(:millisecond) - started_at < @wait_timeout do
          Process.sleep(@retry_delay)
          acquire(connection, started_at)
        else
          {:error,
           if(busy?(error),
             do: "Another Still instance is still updating this collection. Try again shortly.",
             else: "Could not acquire the collection lock: #{Exception.message(error)}"
           )}
        end
    end
  end

  defp busy?(error) do
    message = Exception.message(error) |> String.downcase()
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp release(connection) do
    _ = Exqlite.query(connection, "ROLLBACK")
    :ok
  catch
    _, _ -> :ok
  end

  defp stop_connection(connection) do
    if Process.alive?(connection), do: GenServer.stop(connection, :normal, 5_000)
    :ok
  catch
    _, _ -> :ok
  end
end

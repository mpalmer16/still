defmodule Still.Desk do
  @moduledoc "Machine-local cursor for the one page that is open in Still."

  alias Still.Repo

  @state_key "still_desk_v1"
  @local_cursor "local"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type cursor :: %{id: String.t(), saved: boolean(), beside: pos_integer() | nil}

  @doc "Return the cursor for this local draft or configured collection."
  def current(location) when is_map(location) do
    with_state(fn state -> {:ok, current_cursor(state, location)} end)
  end

  def current(_location), do: {:error, "Could not read the current page cursor."}

  @doc "Return only an unfinished page for Write; a saved, clean page starts afresh."
  def for_write(location) when is_map(location) do
    with_state(fn state ->
      current = current_cursor(state, location)
      local = state.cursors |> Map.get(@local_cursor) |> decode_cursor()
      {:ok, Enum.find([current, local], &unfinished?/1)}
    end)
  end

  def for_write(_), do: {:error, "Could not read the current page cursor."}

  defp current_cursor(state, location) do
    key = saved_key(location)

    cursor =
      if state.active == @local_cursor,
        do: Map.get(state.cursors, @local_cursor),
        else: (key && Map.get(state.cursors, key)) || Map.get(state.cursors, @local_cursor)

    decode_cursor(cursor)
  end

  defp unfinished?(nil), do: false
  defp unfinished?(cursor), do: Map.get(cursor, :dirty, not cursor.saved)

  @doc "Remember the open page without storing its words or a filesystem path."
  def remember(location, cursor) when is_map(location) and is_map(cursor) do
    with {:ok, cursor} <- normalize_cursor(cursor),
         {:ok, key} <- cursor_key(location, cursor) do
      update_state(fn state ->
        cursors =
          if cursor.saved do
            case Map.get(state.cursors, @local_cursor) do
              %{"id" => id} when id == cursor.id -> Map.delete(state.cursors, @local_cursor)
              _ -> state.cursors
            end
          else
            state.cursors
          end

        %{state | cursors: Map.put(cursors, key, encode_cursor(cursor)), active: key}
      end)
    end
  end

  def remember(_location, _cursor), do: {:error, "Could not remember the current page."}

  @doc "Clear this page only when the stored cursor still points to the given id."
  def clear(location, id) when is_map(location) and is_binary(id) do
    keys = [@local_cursor, saved_key(location)] |> Enum.reject(&is_nil/1)

    update_state(fn state ->
      cursors =
        Enum.reduce(keys, state.cursors, fn key, acc ->
          case Map.get(acc, key) do
            %{"id" => ^id} -> Map.delete(acc, key)
            _ -> acc
          end
        end)

      active =
        if state.active in keys and not Map.has_key?(cursors, state.active),
          do: nil,
          else: state.active

      %{state | cursors: cursors, active: active}
    end)
  end

  def clear(_location, _id), do: {:error, "Could not clear the current page cursor."}

  defp normalize_cursor(%{id: id, saved: saved, beside: beside} = cursor)
       when is_binary(id) and is_boolean(saved) and
              (is_nil(beside) or (is_integer(beside) and beside > 0)) do
    if Regex.match?(@uuid, id) and (not Map.has_key?(cursor, :dirty) or is_boolean(cursor.dirty)) do
      normalized = %{id: String.downcase(id), saved: saved, beside: beside}

      {:ok,
       if(Map.has_key?(cursor, :dirty),
         do: Map.put(normalized, :dirty, cursor.dirty),
         else: normalized
       )}
    else
      {:error, "The page cursor has an invalid id."}
    end
  end

  defp normalize_cursor(_cursor), do: {:error, "The page cursor is incomplete."}

  defp cursor_key(_location, %{saved: false}), do: {:ok, @local_cursor}

  defp cursor_key(%{configured: true, scope: scope}, %{saved: true})
       when is_binary(scope),
       do:
         if(valid_scope?(scope),
           do: {:ok, "collection:" <> scope},
           else: {:error, "A saved page needs a valid collection scope."}
         )

  defp cursor_key(_location, %{saved: true}),
    do: {:error, "A saved page needs a configured collection."}

  defp saved_key(%{configured: true, scope: scope}) when is_binary(scope) do
    if valid_scope?(scope), do: "collection:" <> scope
  end

  defp saved_key(_location), do: nil
  defp valid_scope?(scope), do: Regex.match?(~r/\A(?:[0-9a-f]{64}|[0-9a-f-]{36})\z/i, scope)

  defp encode_cursor(cursor) do
    data = %{"id" => cursor.id, "saved" => cursor.saved, "beside" => cursor.beside}
    if Map.has_key?(cursor, :dirty), do: Map.put(data, "dirty", cursor.dirty), else: data
  end

  defp decode_cursor(nil), do: nil

  defp decode_cursor(cursor) do
    decoded = %{id: cursor["id"], saved: cursor["saved"], beside: cursor["beside"]}
    if Map.has_key?(cursor, "dirty"), do: Map.put(decoded, :dirty, cursor["dirty"]), else: decoded
  end

  defp with_state(fun) do
    with_lock(fn ->
      with {:ok, state} <- read_state() do
        fun.(state)
      end
    end)
  end

  defp update_state(fun) do
    with_lock(fn ->
      with {:ok, state} <- read_state(),
           next = fun.(state),
           :ok <- write_state(next) do
        :ok
      end
    end)
  end

  defp with_lock(fun) do
    path = state_path()
    lock = {{__MODULE__, path}, self()}

    case :global.trans(lock, fun) do
      {:aborted, reason} ->
        {:error, "Could not access the current page cursor: #{inspect(reason)}"}

      result ->
        result
    end
  rescue
    error -> {:error, "Could not access the current page cursor: #{Exception.message(error)}"}
  end

  defp read_state do
    case File.read(state_path()) do
      {:error, :enoent} ->
        {:ok, %{cursors: %{}, active: nil}}

      {:ok, payload} ->
        decode_state(payload)

      {:error, reason} ->
        {:error, "Could not read the current page cursor: #{file_error(reason)}"}
    end
  end

  defp decode_state(payload) do
    with {:ok, %{@state_key => %{"cursors" => cursors, "active" => active}}}
         when is_map(cursors) <- Jason.decode(payload),
         true <- Enum.all?(cursors, &valid_stored_cursor?/1),
         true <- valid_active?(active, cursors) do
      {:ok, %{cursors: cursors, active: active}}
    else
      _ ->
        {:error,
         "The current page cursor is damaged. Keep a backup of the state file before changing it."}
    end
  end

  defp valid_active?(nil, _cursors), do: true
  defp valid_active?(@local_cursor, cursors), do: Map.has_key?(cursors, @local_cursor)

  defp valid_active?("collection:" <> scope = key, cursors),
    do: valid_scope?(scope) and Map.has_key?(cursors, key)

  defp valid_active?(_active, _cursors), do: false

  defp valid_stored_cursor?({@local_cursor, %{"saved" => false} = cursor}),
    do: valid_encoded_cursor?(cursor)

  defp valid_stored_cursor?({"collection:" <> scope, %{"saved" => true} = cursor}) do
    valid_scope?(scope) and valid_encoded_cursor?(cursor)
  end

  defp valid_stored_cursor?(_), do: false

  defp valid_encoded_cursor?(%{"id" => id, "saved" => saved, "beside" => beside} = cursor)
       when is_binary(id) and is_boolean(saved) and
              (is_nil(beside) or (is_integer(beside) and beside > 0)) do
    Regex.match?(@uuid, id) and (not Map.has_key?(cursor, "dirty") or is_boolean(cursor["dirty"]))
  end

  defp valid_encoded_cursor?(_), do: false

  defp write_state(state) do
    path = state_path()
    directory = Path.dirname(path)
    temp = path <> ".partial-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}"

    payload =
      Jason.encode!(%{
        @state_key => %{"cursors" => state.cursors, "active" => state.active}
      })

    try do
      with :ok <- File.mkdir_p(directory),
           :ok <- write_temp(temp, payload),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, path),
           :ok <- sync_directory(directory) do
        :ok
      else
        {:error, reason} ->
          {:error, "Could not save the current page cursor: #{file_error(reason)}"}
      end
    after
      File.rm(temp)
    end
  rescue
    error -> {:error, "Could not save the current page cursor: #{Exception.message(error)}"}
  end

  defp write_temp(temp, payload) do
    case File.open(temp, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        try do
          with :ok <- IO.binwrite(file, payload),
               :ok <- :file.sync(file) do
            :ok
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw]) do
      {:ok, file} ->
        try do
          case :file.sync(file) do
            :ok -> :ok
            {:error, reason} when reason in [:eisdir, :einval, :eopnotsupp] -> :ok
            {:error, reason} -> {:error, reason}
          end
        after
          :file.close(file)
        end

      {:error, reason} when reason in [:eisdir, :einval, :eopnotsupp] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_path do
    configured =
      Application.get_env(:still, :storage_state_directory) ||
        System.get_env("STILL_LOCAL_STATE_DIRECTORY")

    base = configured || Path.join(System.user_home!(), ".config/still")

    database =
      Repo.config()[:database]
      |> Path.expand()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join(base, "desk-#{database}.json")
  end

  defp file_error(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp file_error(reason), do: inspect(reason)
end

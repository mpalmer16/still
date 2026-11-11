defmodule Still.Correspondence.PacketNotes do
  @moduledoc "Ongoing, independently versioned notes attached to a correspondence packet."

  alias Still.{Correspondence, LocalRecord, Repo, Storage}
  alias Still.Writing.CollectionLock

  @kind "packet_notes"
  @revision_kind "revision"

  @doc "Reads ongoing notes, falling back to legacy preparation notes without writing."
  def get(location, packet_or_id) do
    with {:ok, id} <- packet_id(packet_or_id),
         {:ok, active} <- active_location(location) do
      CollectionLock.with_lock(Repo.config()[:database], fn ->
        with :ok <- ensure_current_scope(active.scope),
             {:ok, packet} <- Correspondence.packet(%{scope: active.scope}, id),
             {:ok, row} <- notes_row(active.scope, id) do
          case row do
            nil -> {:ok, %{packet_id: id, body: packet.preparation_notes || "", token: nil}}
            row -> decode_notes(row, id)
          end
        end
      end)
    end
  end

  @doc "Saves ongoing notes with stale-edit protection and a preserved prior version."
  def save(location, packet_id, body, expected_token)
      when is_binary(packet_id) and (is_nil(expected_token) or is_binary(expected_token)) do
    with :ok <- valid_body(body),
         {:ok, active} <- active_location(location) do
      CollectionLock.with_lock(Repo.config()[:database], fn ->
        save_locked(active.scope, packet_id, body, expected_token)
      end)
    end
  end

  def save(_, _, _, _), do: {:error, "Reopen this packet before saving notes."}

  defp save_locked(scope, id, body, expected_token) do
    result =
      try do
        Repo.transaction(fn ->
          ensure_current_scope!(scope)

          case Correspondence.packet(%{scope: scope}, id) do
            {:ok, _packet} -> :ok
            {:error, message} -> Repo.rollback({:error, message})
          end

          current = Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id)

          case current_token(current, id) do
            ^expected_token ->
              :ok

            _ ->
              Repo.rollback(
                {:error, "These notes changed on disk. Reopen them before continuing."}
              )
          end

          if current && match?(%{"body" => ^body}, current.data) do
            case decode_notes(current, id) do
              {:ok, notes} -> Repo.rollback({:ok, notes})
              {:error, message} -> Repo.rollback({:error, message})
            end
          end

          if current do
            revision = %{
              scope: scope,
              kind: @revision_kind,
              record_key: "#{@kind}:#{id}:#{current.lock_version}",
              data: current.data,
              bytes: current.bytes
            }

            Repo.insert!(LocalRecord.changeset(%LocalRecord{}, revision))
          end

          attrs = %{
            scope: scope,
            kind: @kind,
            record_key: id,
            data: %{"packet_id" => id, "body" => body},
            lock_version: (current && current.lock_version + 1) || 1
          }

          saved =
            if current,
              do: current |> LocalRecord.changeset(attrs) |> Repo.update!(),
              else: %LocalRecord{} |> LocalRecord.changeset(attrs) |> Repo.insert!()

          case decode_notes(saved, id) do
            {:ok, notes} -> notes
            {:error, message} -> Repo.rollback({:error, message})
          end
        end)
      rescue
        _ -> {:error, :concurrent_write}
      end

    case result do
      {:ok, notes} ->
        {:ok, notes}

      {:error, {:ok, notes}} ->
        {:ok, notes}

      {:error, {:error, message}} ->
        {:error, message}

      {:error, :concurrent_write} ->
        {:error, "These notes changed on disk. Reopen them before continuing."}
    end
  end

  defp notes_row(scope, id) do
    case Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id) do
      nil ->
        {:ok, nil}

      row ->
        case decode_notes(row, id) do
          {:ok, _} -> {:ok, row}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp decode_notes(%LocalRecord{data: %{"packet_id" => id, "body" => body}} = row, id)
       when is_binary(body) do
    with :ok <- valid_body(body) do
      {:ok, %{packet_id: id, body: body, token: token(row)}}
    else
      _ -> {:error, "The saved packet notes are malformed."}
    end
  end

  defp decode_notes(_, _), do: {:error, "The saved packet notes are malformed."}

  defp current_token(nil, _id), do: nil

  defp current_token(row, id) do
    case decode_notes(row, id) do
      {:ok, %{token: token}} -> token
      _ -> :invalid
    end
  end

  defp token(%LocalRecord{data: data, lock_version: version}) do
    :crypto.hash(:sha256, Jason.encode!(%{"data" => data, "lock_version" => version}))
    |> Base.encode16(case: :lower)
  end

  defp packet_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp packet_id(id) when is_binary(id), do: {:ok, id}
  defp packet_id(_), do: {:error, "The packet identifier is invalid."}

  defp valid_body(body) when is_binary(body) do
    if String.valid?(body) and :binary.match(body, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, "Notes must be valid Unicode text without NUL characters."}
  end

  defp valid_body(_), do: {:error, "Notes must be text."}

  defp active_location(location) do
    active = Storage.collection_location()
    scope = if is_map(location), do: location[:scope] || location["scope"], else: nil

    cond do
      not active.configured ->
        {:error, "Choose a collection folder before using Correspondence."}

      not active.available ->
        {:error, active.error || "The selected collection folder is unavailable."}

      is_binary(scope) and scope != active.scope ->
        {:error, "The active collection changed. Reopen Correspondence before continuing."}

      true ->
        {:ok, active}
    end
  end

  defp ensure_current_scope(scope) do
    active = Storage.collection_location()

    if active.available and active.scope == scope,
      do: :ok,
      else: {:error, "The active collection changed. Reopen Correspondence before continuing."}
  end

  defp ensure_current_scope!(scope) do
    case ensure_current_scope(scope) do
      :ok -> :ok
      {:error, message} -> Repo.rollback({:error, message})
    end
  end
end

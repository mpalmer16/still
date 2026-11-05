defmodule Still.Correspondence.Proofs do
  @moduledoc "Pure comparisons between a saved page and its earlier Correspondence sources."

  alias Still.Poems

  @max_lines 600
  @max_line_product 160_000
  @max_bytes 200_000

  @doc "Returns immutable sent snapshots and saved revisions belonging to this piece."
  def sources(piece, revisions, history) do
    piece_id = value(piece, :id)
    entry_id = value(piece, :entry_id)

    if is_binary(piece_id) and piece_id != "" do
      sent =
        list(history)
        |> Enum.flat_map(&sent_source(&1, piece_id))
        |> Enum.sort_by(&{date_key(&1.date), &1.key}, :desc)

      saved =
        list(revisions)
        |> Enum.flat_map(&saved_source(&1, piece_id, entry_id))
        |> Enum.sort_by(&{date_key(&1.date), &1.key}, :desc)

      sent ++ saved
    else
      []
    end
  end

  @doc "Compares exact source text with the current page without changing either side."
  def compare(source, piece) do
    source_body = binary(value(source, :body))
    current_body = binary(value(piece, :body))
    source_title = value(source, :title)
    current_title = Poems.display_title(piece || %{title: nil, body: current_body})

    same? = source_body == current_body
    detailed? = same? or detailed_size?(source_body, current_body)

    {earlier, current} =
      if detailed? do
        if same? do
          {segments(:same, source_body), segments(:same, current_body)}
        else
          diff_segments(source_body, current_body)
        end
      else
        {segments(:removed, source_body), segments(:added, current_body)}
      end

    line_endings_only? =
      not same? and normalize_line_endings(source_body) == normalize_line_endings(current_body)

    spacing_only? =
      not same? and not line_endings_only? and
        remove_whitespace(source_body) == remove_whitespace(current_body)

    %{
      source: source,
      current_title: current_title,
      earlier: earlier,
      current: current,
      body_same?: same?,
      title_same?: source_title == current_title,
      spacing_only?: spacing_only?,
      line_endings_only?: line_endings_only?,
      detailed?: detailed?
    }
  end

  defp sent_source(row, piece_id) do
    packet = value(row, :packet)
    snapshot_piece = value(row, :snapshot)
    snapshot = value(packet, :snapshot)
    packet_id = value(packet, :id)
    snapshot_id = value(snapshot, :id)
    ref = value(packet, :snapshot_ref)
    body = value(snapshot_piece, :body)
    title = value(snapshot_piece, :title)
    frozen_journal = value(snapshot, :journal_name)
    date = value(snapshot, :date)
    status = value(packet, :status)

    valid? =
      is_binary(packet_id) and packet_id != "" and is_binary(snapshot_id) and snapshot_id != "" and
        ref == snapshot_id and value(snapshot, :packet_id) == packet_id and
        value(snapshot_piece, :id) == piece_id and is_binary(body) and is_binary(title) and
        is_binary(frozen_journal) and frozen_journal != "" and is_binary(date) and
        valid_date?(date) and
        status in ["submitted", "awaiting", "declined", "accepted", "withdrawn"]

    if valid? do
      [
        %{
          key: "sent:#{packet_id}",
          kind: :sent,
          title: title,
          body: body,
          label: "Sent to #{frozen_journal}",
          date: date,
          packet_id: packet_id
        }
      ]
    else
      []
    end
  end

  defp saved_source(revision, piece_id, entry_id) do
    id = value(revision, :id)
    body = value(revision, :body)
    date = value(revision, :updated_at) || value(revision, :created_at)
    owner = value(revision, :piece_id) || value(revision, :entry_id)

    valid? =
      valid_revision_id?(id) and is_binary(body) and is_binary(date) and valid_date?(date) and
        (is_nil(owner) or owner in [piece_id, entry_id])

    if valid? do
      [
        %{
          key: "saved:#{id}",
          kind: :saved,
          title: Poems.display_title(revision),
          body: body,
          label: "Saved version",
          date: date,
          packet_id: nil
        }
      ]
    else
      []
    end
  end

  defp valid_revision_id?(id) when is_integer(id), do: id > 0
  defp valid_revision_id?(id) when is_binary(id), do: id != ""
  defp valid_revision_id?(_), do: false

  defp diff_segments(source_body, current_body) do
    source_lines = lines(source_body)
    current_lines = lines(current_body)

    List.myers_difference(source_lines, current_lines)
    |> Enum.reduce({[], []}, fn
      {:eq, content}, {earlier, current} ->
        text = IO.iodata_to_binary(content)
        {append_segment(earlier, :same, text), append_segment(current, :same, text)}

      {:del, content}, {earlier, current} ->
        {append_segment(earlier, :removed, IO.iodata_to_binary(content)), current}

      {:ins, content}, {earlier, current} ->
        {earlier, append_segment(current, :added, IO.iodata_to_binary(content))}
    end)
    |> then(fn {earlier, current} -> {Enum.reverse(earlier), Enum.reverse(current)} end)
  end

  defp detailed_size?(source_body, current_body) do
    byte_size(source_body) <= @max_bytes and byte_size(current_body) <= @max_bytes and
      line_count(source_body) <= @max_lines and line_count(current_body) <= @max_lines and
      line_count(source_body) * line_count(current_body) <= @max_line_product
  end

  defp line_count(""), do: 0
  defp line_count(body), do: length(lines(body))

  # Newline bytes remain attached to each authored line for a byte-exact diff.
  defp lines(""), do: []

  defp lines(body),
    do:
      Regex.scan(~r/[^\r\n]*(?:\r\n|\n|\r|$)/u, body)
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))

  defp segments(_kind, ""), do: []
  defp segments(kind, text), do: [%{kind: kind, text: text}]

  defp append_segment(segments, _kind, ""), do: segments

  defp append_segment([%{kind: kind, text: prior} | rest], kind, text),
    do: [%{kind: kind, text: prior <> text} | rest]

  defp append_segment(segments, kind, text), do: [%{kind: kind, text: text} | segments]

  defp normalize_line_endings(body), do: String.replace(body, ~r/\r\n|\r/u, "\n")
  defp remove_whitespace(body), do: String.replace(body, ~r/\s+/u, "")

  defp valid_date?(value) do
    match?({:ok, _}, Date.from_iso8601(value)) or
      match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp date_key(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_unix(datetime, :microsecond)

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} ->
            unix_epoch_days = Date.to_gregorian_days(~D[1970-01-01])
            (Date.to_gregorian_days(date) - unix_epoch_days) * 86_400_000_000

          _ ->
            0
        end
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _key), do: nil

  defp binary(value) when is_binary(value), do: value
  defp binary(_), do: ""

  defp list(values) when is_list(values), do: values
  defp list(_), do: []
end

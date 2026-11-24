defmodule Still.Correspondence.Funding do
  @moduledoc "Collection-scoped local grant and fellowship opportunities."
  alias Still.{LocalRecord, Repo, Storage}
  alias Still.Writing.CollectionLock
  import Ecto.Query

  @kind "funding_opportunity"
  @atom_fields ~w(name funder kind cycle amount eligibility description opens_on deadline deadline_time timezone application_url source_url checked_on notes highlighted priority eligibility_status benefit prepare_on fee travel effort fit anticipated_window)a
  @field_atoms Map.new(@atom_fields, &{Atom.to_string(&1), &1})
  @fields Map.keys(@field_atoms)
  @item_limits %{"name" => 300, "funder" => 300, "notes" => 10_000}
  @kinds [
    {"Grant", "grant"},
    {"Fellowship", "fellowship"},
    {"Residency", "residency"},
    {"Prize", "prize"},
    {"Scholarship", "scholarship"},
    {"Other", "other"}
  ]

  @priorities [{"Pursue", "pursue"}, {"Monitor", "monitor"}, {"Pass", "pass"}]
  @eligibility_statuses [
    {"Eligible", "eligible"},
    {"Needs confirmation", "check"},
    {"Ineligible", "ineligible"}
  ]
  @benefits [
    {"Unrestricted financial support", "unrestricted"},
    {"Restricted funding", "restricted"},
    {"In-kind benefits", "in_kind"},
    {"Publication", "publication"},
    {"Artistic development", "development"}
  ]

  def priorities, do: @priorities
  def eligibility_statuses, do: @eligibility_statuses
  def benefits, do: @benefits

  def benefit_label(value),
    do: Enum.find_value(@benefits, fn {label, key} -> value == key && label end) || nil

  def kinds, do: @kinds
  def fields, do: @fields
  def atom_fields, do: @atom_fields
  def atomize(attrs), do: Map.new(@atom_fields, &{&1, Map.get(attrs, Atom.to_string(&1))})

  def list(location) do
    with {:ok, scope} <- active_scope(location) do
      Repo.all(from r in LocalRecord, where: r.scope == ^scope and r.kind == @kind)
      |> Enum.map(&decode/1)
      |> collect_decoded()
      |> case do
        {:ok, rows} -> {:ok, Enum.sort_by(rows, &key/1)}
        error -> error
      end
    end
  end

  def get(location, id) when is_binary(id) do
    with {:ok, scope} <- active_scope(location),
         %LocalRecord{} = row <-
           Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id),
         {:ok, record} <- decode(row) do
      {:ok, record}
    else
      nil -> {:error, "This funding opportunity is no longer available."}
      error -> error
    end
  end

  def get(_, _), do: {:error, "Reopen this funding opportunity before continuing."}

  def save(location, attrs, id \\ nil, expected_token \\ nil) do
    with {:ok, attrs} <- validate(attrs), {:ok, scope} <- active_scope(location) do
      CollectionLock.with_lock(Repo.config()[:database], fn ->
        Repo.transaction(fn ->
          ensure_scope!(scope, location)

          current =
            if is_binary(id),
              do: Repo.get_by(LocalRecord, scope: scope, kind: @kind, record_key: id)

          if id && is_nil(current),
            do: Repo.rollback({:error, "This funding opportunity is no longer available."})

          if current && token(current) != expected_token,
            do:
              Repo.rollback(
                {:error, "This funding opportunity changed. Reopen it before saving."}
              )

          existing = Repo.all(from r in LocalRecord, where: r.scope == ^scope and r.kind == @kind)
          decoded = Enum.map(existing, &decode/1)

          if Enum.any?(decoded, &match?({:error, _}, &1)),
            do:
              Repo.rollback(
                {:error, "A saved funding opportunity is malformed. Resolve it before saving."}
              )

          identity = identity(attrs)

          duplicate =
            Enum.zip(existing, decoded)
            |> Enum.any?(fn {row, {:ok, item}} ->
              row.record_key != (current && current.record_key) and identity(item) == identity
            end)

          if duplicate, do: Repo.rollback({:error, "This funding opportunity already exists."})
          rid = (current && current.record_key) || Ecto.UUID.generate()
          data = Map.put(attrs, "id", rid)
          if current && current.data == data, do: Repo.rollback({:ok, elem(decode(current), 1)})
          if current, do: preserve_revision!(current)

          row_attrs = %{
            scope: scope,
            kind: @kind,
            record_key: rid,
            data: data,
            lock_version: (current && current.lock_version + 1) || 1
          }

          saved =
            if current,
              do: current |> LocalRecord.changeset(row_attrs) |> Repo.update!(),
              else: %LocalRecord{} |> LocalRecord.changeset(row_attrs) |> Repo.insert!()

          {:ok, item} = decode(saved)
          item
        end)
        |> transaction_result()
      end)
    end
  end

  def set_highlighted(location, %{id: id, token: token} = item, highlighted)
      when is_boolean(highlighted) do
    attrs = item |> Map.take(@atom_fields) |> Map.put(:highlighted, highlighted)
    save(location, attrs, id, token)
  end

  def export_json(location) do
    with {:ok, rows} <- list(location) do
      rows
      |> Enum.map(fn r ->
        r |> Map.take(@atom_fields) |> Map.reject(fn {_key, value} -> is_nil(value) end)
      end)
      |> Jason.encode()
    end
  end

  @doc false
  def insert_import!(scope, attrs) do
    {:ok, attrs} = validate(attrs)
    id = Ecto.UUID.generate()

    Repo.insert!(
      LocalRecord.changeset(%LocalRecord{}, %{
        scope: scope,
        kind: @kind,
        record_key: id,
        data: Map.put(attrs, "id", id),
        lock_version: 1
      })
    )
  end

  def validate(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    attrs =
      if attrs["highlighted"] in ["true", "false"],
        do: Map.update!(attrs, "highlighted", &(&1 == "true")),
        else: attrs

    unknown = Map.keys(attrs) -- @fields

    attrs =
      Enum.reduce(@fields, attrs, fn k, acc ->
        if Map.get(acc, k) in ["", nil], do: Map.delete(acc, k), else: acc
      end)

    cond do
      unknown != [] ->
        {:error, "Unsupported funding fields: #{Enum.join(unknown, ", ")}."}

      Enum.any?(attrs, fn {k, v} ->
        k != "highlighted" and
            (not is_binary(v) or not String.valid?(v) or :binary.match(v, <<0>>) != :nomatch)
      end) ->
        {:error, "Funding fields must be valid text strings."}

      Map.has_key?(attrs, "highlighted") and not is_boolean(attrs["highlighted"]) ->
        {:error, "highlighted must be true or false."}

      Enum.any?(attrs, fn {key, value} ->
        is_binary(value) and String.length(value) > Map.get(@item_limits, key, 5_000)
      end) ->
        {:error, "Funding text exceeds the allowed field length."}

      not nonempty(attrs["name"]) ->
        {:error, "name is required."}

      not nonempty(attrs["funder"]) ->
        {:error, "funder is required."}

      attrs["kind"] not in Enum.map(@kinds, &elem(&1, 1)) ->
        {:error, "kind must be grant, fellowship, residency, prize, scholarship, or other."}

      Enum.any?(
        ~w(opens_on deadline checked_on prepare_on),
        &(present?(attrs, &1) and not valid_date?(attrs[&1]))
      ) ->
        {:error, "Funding dates must use YYYY-MM-DD."}

      invalid_choice?(attrs["priority"], @priorities) or
        invalid_choice?(attrs["eligibility_status"], @eligibility_statuses) or
          invalid_choice?(attrs["benefit"], @benefits) ->
        {:error, "Choose a listed priority, eligibility status, or benefit."}

      present?(attrs, "prepare_on") and present?(attrs, "deadline") and
          attrs["prepare_on"] > attrs["deadline"] ->
        {:error, "Preparation must start on or before the deadline."}

      present?(attrs, "deadline_time") and not valid_time?(attrs["deadline_time"]) ->
        {:error, "deadline_time must use HH:MM in 24-hour time."}

      present?(attrs, "deadline_time") != present?(attrs, "timezone") ->
        {:error, "deadline_time and timezone must be provided together."}

      present?(attrs, "timezone") and not nonempty(attrs["timezone"]) ->
        {:error, "Use the time zone shown in the source."}

      present?(attrs, "deadline_time") and not present?(attrs, "deadline") ->
        {:error, "A deadline date is required with deadline_time or timezone."}

      present?(attrs, "deadline") and present?(attrs, "opens_on") and
          attrs["deadline"] < attrs["opens_on"] ->
        {:error, "deadline must be on or after opens_on."}

      Enum.any?(
        ~w(application_url source_url),
        &(present?(attrs, &1) and not safe_url?(attrs[&1]))
      ) ->
        {:error, "URLs must be complete HTTP or HTTPS addresses without credentials."}

      true ->
        values = Map.put_new(attrs, "highlighted", false)
        {:ok, Map.new(@fields, fn field -> {field, Map.get(values, field)} end)}
    end
  end

  def validate(_), do: {:error, "Each funding opportunity must be an object."}

  defp invalid_choice?(nil, _), do: false
  defp invalid_choice?(value, choices), do: !Enum.any?(choices, &(elem(&1, 1) == value))

  def decode(%LocalRecord{data: data, lock_version: ver, record_key: key}) when is_map(data) do
    id = data["id"]
    attrs = Map.take(data, @fields)

    with true <- is_binary(id),
         {:ok, _} <- Ecto.UUID.cast(id),
         true <- id == key,
         {:ok, attrs} <- validate(attrs) do
      atoms = atomize(attrs)

      {:ok,
       Map.merge(atoms, %{id: id, token: token(%LocalRecord{data: data, lock_version: ver})})}
    else
      _ -> {:error, "A saved funding opportunity is malformed."}
    end
  end

  def decode(_), do: {:error, "A saved funding opportunity is malformed."}

  def active_scope(location) do
    active = Storage.collection_location()
    scope = if is_map(location), do: location[:scope] || location["scope"], else: nil

    cond do
      not active.configured ->
        {:error, "Choose a collection folder before using Correspondence."}

      not active.available ->
        {:error, active.error || "The selected collection folder is unavailable."}

      scope != active.scope ->
        {:error, "The selected collection changed. Reopen Correspondence."}

      true ->
        {:ok, scope}
    end
  end

  def token(%LocalRecord{data: data, lock_version: ver}),
    do:
      :crypto.hash(:sha256, Jason.encode!(%{"data" => data, "lock_version" => ver}))
      |> Base.encode16(case: :lower)

  def preserve_revision!(row),
    do:
      Repo.insert!(
        LocalRecord.changeset(%LocalRecord{}, %{
          scope: row.scope,
          kind: "revision",
          record_key: "funding_opportunity:#{row.record_key}:#{row.lock_version}",
          data: row.data,
          bytes: row.bytes
        })
      )

  def identity(row),
    do: Enum.map([value(row, :name), value(row, :funder), value(row, :cycle)], &normalize/1)

  defp key(r), do: identity(r)
  defp normalize(nil), do: ""

  defp normalize(s),
    do: s |> String.normalize(:nfkc) |> String.downcase() |> String.split() |> Enum.join(" ")

  defp collect_decoded(rows) do
    case Enum.find(rows, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(rows, fn {:ok, r} -> r end)}
      {:error, m} -> {:error, m}
    end
  end

  defp ensure_scope!(scope, location) do
    case active_scope(location) do
      {:ok, ^scope} -> :ok
      {:error, message} -> Repo.rollback({:error, message})
      _ -> Repo.rollback({:error, "The selected collection changed. Reopen Correspondence."})
    end
  end

  defp transaction_result({:ok, v}), do: {:ok, v}
  defp transaction_result({:error, {:ok, v}}), do: {:ok, v}
  defp transaction_result({:error, {:error, m}}), do: {:error, m}
  defp transaction_result(_), do: {:error, "Could not save the funding opportunity."}
  defp nonempty(v), do: is_binary(v) and String.trim(v) != ""
  defp present?(a, k), do: Map.has_key?(a, k)
  defp value(row, atom), do: Map.get(row, atom, Map.get(row, Atom.to_string(atom)))

  defp valid_date?(v),
    do:
      is_binary(v) and Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, v) and
        match?({:ok, _}, Date.from_iso8601(v))

  defp valid_time?(v), do: is_binary(v) and Regex.match?(~r/\A([01]\d|2[0-3]):[0-5]\d\z/, v)

  defp safe_url?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} ->
        scheme in ["http", "https"] && is_binary(host) && host != ""

      _ ->
        false
    end
  end
end

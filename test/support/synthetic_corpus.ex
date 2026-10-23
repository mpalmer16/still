defmodule Still.SyntheticCorpus do
  @moduledoc false

  alias Still.Writing

  @current "Current Notebooks/2025 Oct - Dec"
  @notebook "Current Notebooks/2026/Notebook 1"
  @corner @notebook <> "/Jan - Mar"

  # 540 deliberately synthetic records. The first notebook has 137 ordered
  # records; the two Notebook 1 source sections remain independently ordered.
  def manifest do
    targeted = [
      entry("Cobalt:Zeppelin:Sprocket:", "cobalt zeppelin sprocket", 0, "cobalt-page"),
      entry("Saffron:Anvil:Prism:", "saffron anvil prism", 100, "saffron-page"),
      entry("Zircon:Caliper:Lattice:", "zircon caliper lattice", 200, "zircon-page"),
      entry("Amber:Turbine:Spindle:", "amber turbine spindle", 300, "amber-page"),
      entry("Indigo:Pulley:Socket:", "indigo pulley socket", 400, "indigo-page"),
      entry("Ochre:Piston:Flange:", "ochre piston flange", 500, "ochre-page"),
      entry(
        "Sprocket:Zephyr:",
        "sprocket by the fixture\nzephyr in another slot",
        600,
        "single-sprocket-page"
      )
    ]

    list1 =
      targeted ++
        for position <- 7..136 do
          # Between 6% and 12% of the whole collection shares each deliberate
          # item. Ordinary prose rejects these common terms; List intent admits
          # one faint item, then strengthens the record sharing both terms.
          shared =
            cond do
              position in 7..45 -> " sprocket"
              position in 46..84 -> " zephyr"
              true -> ""
            end

          entry(
            "Synthetic List One #{position}:",
            "vellichorium #{position}" <> shared,
            position * 100,
            "list-one-page-#{div(position, 2)}"
          )
        end

    rest =
      Enum.flat_map(2..8, fn number ->
        count = 49

        for position <- 0..(count - 1) do
          entry(
            "Synthetic List #{number} Item #{position}:",
            "vellichorium #{number}-#{position}",
            position * 100,
            "list-#{number}-page-#{div(position, 2)}",
            "Early Notebooks/Lists #{number}"
          )
        end
      end)

    current_entries =
      for position <- 0..19 do
        entry(
          "Synthetic Current Item #{position}:",
          "synthetic current words #{position}",
          position * 100,
          "current-page-#{position}",
          @current
        )
      end

    roots =
      for position <- 0..1 do
        entry(
          "Synthetic Notebook Root #{position}:",
          "root prism words #{position}",
          position * 100,
          "root-page-#{position}",
          @notebook
        )
      end

    corners =
      for position <- 0..37 do
        entry(
          "Synthetic Notebook Corner #{position}:",
          "corner prism words #{position}",
          position * 100,
          "corner-page-#{position}",
          @corner
        )
      end

    entries =
      Enum.concat([
        move_to_notebook(list1, "Early Notebooks/Lists 1"),
        rest,
        current_entries,
        roots,
        corners
      ])

    %{"format" => "still-lists-1", "entries" => entries}
  end

  def import! do
    path = Path.join(System.tmp_dir!(), "still-synthetic-#{Ecto.UUID.generate()}.json")
    File.write!(path, Jason.encode!(manifest()))
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    {:ok, %{inserted: 540, skipped: 0}} = Writing.import_lists(path)
  end

  defp move_to_notebook(entries, notebook),
    do: Enum.map(entries, &Map.put(&1, "notebook", notebook))

  defp entry(title, body, order, group, notebook \\ "Early Notebooks/Lists 1") do
    key =
      case group do
        "cobalt-page" -> source_key("cobalt", :left)
        "saffron-page" -> source_key("saffron", :right)
        _ -> "synthetic:" <> group <> ":" <> Integer.to_string(order)
      end

    %{
      "title" => title,
      "body" => body,
      "source_key" => key,
      "source_group" => "synthetic:" <> group,
      "source_order" => order,
      "notebook" => notebook,
      "source" => %{"provenance" => "synthetic fixture", "artifact_order" => order}
    }
  end

  defp source_key(prefix, side) do
    Enum.find(0..10_000, fn position ->
      key = "synthetic:#{prefix}:#{position}"

      actual =
        if rem(:erlang.phash2({:still_field, key}, 10_000), 2) == 0, do: :left, else: :right

      actual == side
    end)
    |> then(&"synthetic:#{prefix}:#{&1}")
  end
end

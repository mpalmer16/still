defmodule Mix.Tasks.Still.PilotTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "a prepared folder is inspected without adoption or any file changes", %{tmp_dir: root} do
    folder = Path.join(root, "Current Notebooks/2026/Notebook 1")
    File.mkdir_p!(folder)
    File.mkdir_p!(Path.join(root, "Current Notebooks/2026/Notebook 2"))
    bytes = "Opening\r\n\r\n\twords  \n"
    File.write!(Path.join(folder, "0001"), bytes)
    File.write!(Path.join(folder, "0003a.txt"), bytes)

    output = capture_io(fn -> Mix.Tasks.Still.Pilot.run([root]) end)
    assert output =~ "2 readable text files; 0 files require preparation or review"
    assert output =~ "Empty folder:"
    assert output =~ "Notebook 2"
    assert output =~ "no explicit title"
    assert File.read!(Path.join(folder, "0001")) == bytes
    assert File.ls!(folder) |> Enum.sort() == ["0001", "0003a.txt"]
    assert File.ls!(root) == ["Current Notebooks"]
  end

  @tag :tmp_dir
  test "a missing folder never becomes an empty collection", %{tmp_dir: root} do
    missing = Path.join(root, "missing")

    assert_raise Mix.Error, ~r/selected location is unavailable/, fn ->
      Mix.Tasks.Still.Pilot.run([missing])
    end

    refute File.exists?(missing)
  end

  @tag :tmp_dir
  test "an unsupported document is reported and left intact", %{tmp_dir: root} do
    file = Path.join(root, "not plain text")
    File.write!(file, <<255, 254, 0>>)

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/Files were left unchanged/, fn ->
          Mix.Tasks.Still.Pilot.run([root])
        end
      end)

    assert output =~ "Needs review:"
    assert output =~ "unsupported_encoding"
    assert File.read!(file) == <<255, 254, 0>>
  end

  test "synthetic pilot covers exact titles, numbering gaps, empty notebooks, and unsupported input" do
    output = capture_io(fn -> Mix.Tasks.Still.Pilot.run(["--synthetic"]) end)
    assert output =~ "7 readable text files; 2 files require preparation or review"
    assert output =~ "0003a"
    assert output =~ "0003b"
    assert output =~ "Notebook 2"
    assert output =~ "Copy text: exact"
    assert output =~ "All fixture files unchanged"
  end
end

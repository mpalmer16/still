defmodule Still.SourceReferenceTest do
  use ExUnit.Case, async: true
  alias Still.Writing

  test "source numbers come only from preserved filename prefixes" do
    source = %{
      "artifacts" => [
        %{"path" => "Early Notebooks/Lists 3/14. Synthetic.doc"},
        %{"path" => "Early Notebooks/Lists 3/14. Synthetic.odt"}
      ]
    }

    entry = %{origin: "before", source: source, source_order: 900, title: "Synthetic title"}
    assert Writing.source_number(entry) == "14"
    assert Writing.source_number(%{entry | source: %{}}) == nil
    assert Writing.source_number(%{entry | origin: "now"}) == nil
    assert Writing.source_number(nil) == nil
  end

  test "missing, unnumbered, malformed or conflicting provenance never invents a number" do
    for artifacts <- [
          nil,
          "invalid",
          [%{"path" => "Synthetic.doc"}],
          [nil],
          [%{"path" => "14. Synthetic.doc"}, %{"path" => "15. Other.doc"}]
        ] do
      assert Writing.source_number(%{origin: "before", source: %{"artifacts" => artifacts}}) ==
               nil
    end
  end
end

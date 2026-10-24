defmodule Still.ManuscriptTest do
  use ExUnit.Case, async: true
  alias Still.Manuscript

  test "DOCX preserves whitespace, stanzas, Unicode, ordering and escapes manuscript XML" do
    pieces = [%{title: "A < B & C", body: "  café\tA\r\n\r\n  二\n"}, %{title: "Second", body: ""}]
    assert {:ok, binary} = Manuscript.encode(pieces, "docx")
    assert {:ok, files} = :zip.extract(binary, [:memory])
    xml = Map.new(files)[~c"word/document.xml"]
    assert xml =~ "A &lt; B &amp; C"
    assert xml =~ "<w:t xml:space=\"preserve\">  café</w:t><w:tab/>"
    assert xml =~ "<w:br/><w:t xml:space=\"preserve\"></w:t><w:br/>"
    assert xml =~ "  二"
    assert xml =~ "<w:pageBreakBefore/>"
    assert {first, _} = :binary.match(xml, "A &lt;")
    assert {second, _} = :binary.match(xml, "Second")
    assert first < second
    refute xml =~ "http://localhost"
  end

  test "plain text retains original bytes, including line endings and final newline" do
    piece = %{title: "Title", body: "\t first\r\n\r\n  second\n"}
    assert {:ok, "Title\n\n" <> body} = Manuscript.encode([piece], "txt")
    assert body == piece.body
  end

  test "DOCX refuses unrepresentable controls rather than silently dropping writing" do
    assert {:error, message} = Manuscript.encode([%{title: "", body: "a\0b"}], "docx")
    assert message =~ "plain text"
    assert {:ok, "\n\na\0b"} = Manuscript.encode([%{title: "", body: "a\0b"}], "txt")
  end
end

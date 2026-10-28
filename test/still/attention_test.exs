defmodule Still.Writing.AttentionTest do
  use ExUnit.Case, async: true

  alias Still.Writing.Attention

  test "passage chunks preserve every authored byte and global line positions" do
    body = "\r\n  stanza one \t\r\nline two\r\n \t \r\n\r\nsecond\n\nlast\r"

    chunks = Attention.passages(body)

    assert Enum.map(chunks, &{&1.kind, &1.first_line, &1.last_line}) == [
             {:space, 1, 1},
             {:passage, 2, 3},
             {:space, 4, 5},
             {:passage, 6, 6},
             {:space, 7, 7},
             {:passage, 8, 8}
           ]

    assert IO.iodata_to_binary(Enum.map(chunks, & &1.text)) == body
    assert hd(chunks).text == "\r\n"
    assert Enum.at(chunks, 1).text == "  stanza one \t\r\nline two\r\n"
    assert Enum.at(chunks, 2).text == " \t \r\n\r\n"
  end

  test "empty body has no chunks and all-whitespace body remains a space chunk" do
    assert Attention.passages("") == []
    body = " \t\r\n\n"
    assert [%{kind: :space, text: ^body, first_line: 1, last_line: 2}] = Attention.passages(body)
    assert IO.iodata_to_binary(Enum.map(Attention.passages(body), & &1.text)) == body
  end

  test "UTF-16 selection locates emoji and combining accents without splitting codepoints" do
    body = "A😀é\n\nNext\n"

    assert {:ok, emoji} = Attention.locate(body, 1, 3)
    assert emoji == %{text: "😀", first_line: 1, last_line: 1, kind: :selection}

    assert {:ok, accent} = Attention.locate(body, 4, 5)
    assert accent.text == "́"
    assert accent.first_line == 1

    assert {:error, :invalid} = Attention.locate(body, 2, 3)
    assert {:error, :invalid} = Attention.locate(body, -1, 1)
    assert {:error, :invalid} = Attention.locate(body, 4, 3)
    assert {:error, :invalid} = Attention.locate(body, 99, 99)
  end

  test "a caret follows its exact stanza, stays silent in blank gaps, and returns at EOF" do
    body = "First stanza\ncontinues\n\nSecond stanza\n"
    assert {:ok, first} = Attention.locate(body, 2, 2)
    assert first.kind == :passage
    assert first.text == "First stanza\ncontinues\n"
    assert first.first_line == 1 and first.last_line == 2

    assert {:ok, gap} = Attention.locate(body, 23, 23)
    assert gap.kind == :space
    assert gap.text == ""

    terminal = "Last words\r\n"
    assert {:ok, last} = Attention.locate(terminal, 12, 12)
    assert last.kind == :passage
    assert last.text == terminal
    assert last.first_line == 1 and last.last_line == 1

    assert {:ok, trailing_gap} = Attention.locate("Last words\n\n", 12, 12)
    assert trailing_gap.kind == :space
    assert trailing_gap.text == ""
  end

  test "a nonempty selection is returned byte for byte across stanza boundaries" do
    body = "One\r\n\r\nTwo😀"
    # UTF-16: select from the first character through the end, including both authored breaks.
    assert {:ok, selection} = Attention.locate(body, 0, 12)
    assert selection.kind == :selection
    assert selection.text == body
    assert selection.first_line == 1
    assert selection.last_line == 3
  end

  test "locate rejects invalid UTF-8 and bodies beyond its bounded input size" do
    assert {:error, :invalid} = Attention.locate(<<255>>, 0, 0)
    assert {:error, :invalid} = Attention.locate(String.duplicate("a", 100_001), 0, 0)
    assert {:error, :invalid} = Attention.locate("short", 6, 6)
  end

  test "excerpt keeps neighboring line bytes inside the same stanza" do
    body = "first\r\n  focus \t\r\nlast\r\n\r\nother focus\r\n"
    gravity_line = "  focus \t\r"

    assert Attention.excerpt(body, gravity_line) == %{
             before: "first\r\n",
             after: "\nlast\r\n"
           }

    assert Attention.excerpt("one\ntarget\n\nother\n", "target") == %{
             before: "one\n",
             after: "\n"
           }

    assert Attention.excerpt(body, "missing") == %{before: "", after: ""}
  end

  test "excerpt omits oversized whole neighbors rather than cropping or crossing them" do
    huge = String.duplicate("x", 301)
    body = "first\n#{huge}\nfocus\nnext\n"

    assert Attention.excerpt(body, "focus") == %{before: "", after: "\nnext\n"}
  end
end

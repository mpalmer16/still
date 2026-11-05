defmodule Still.TextFileTest do
  use ExUnit.Case, async: true

  alias Still.Writing.TextFile

  @tag :tmp_dir
  test "ordinary names and every authored byte survive a read", %{tmp_dir: root} do
    for name <- ["0001.txt", "0003a", "0003b.md", "a piece with no number", "poem.other"] do
      bytes = "\n  Opening — café\r\n\tA line  \n\nLast\r"
      path = Path.join(root, name)
      File.write!(path, bytes)
      assert {:ok, document} = TextFile.read(path)
      assert TextFile.encode(document) == bytes
      assert TextFile.copy_text(document) == bytes
      assert File.read!(path) == bytes
      assert TextFile.title(document, nil) == :none
      assert {:ok, "Opening — café"} = TextFile.display_label(document)
    end
  end

  test "capitalization, blank lines, list shape, and a matching filename confer no title role" do
    for body <- ["THE TITLE\n\nwater: rain:\n", "A Title\n\nA poem\n", "plain words", ""] do
      assert {:ok, document} = TextFile.decode(body)
      assert TextFile.title(document, nil) == :none
      assert TextFile.copy_text(document) == body
      assert TextFile.encode(document) == body
    end
  end

  test "marking a line changes meaning without moving words or changing whitespace" do
    body = "\r\n  A title  \r\n\r\n\twater: waiting:\n\n"
    assert {:ok, document} = TextFile.decode(body)
    assert {:ok, role} = TextFile.mark_title(document, 2)
    assert {:ok, "  A title  "} = TextFile.title(document, role)
    assert {:ok, "A title"} = TextFile.display_label(document, role)

    assert {:ok, %{before: "\r\n", title: "  A title  ", after: after_title}} =
             TextFile.editor_parts(document, role)

    assert after_title == "\r\n\r\n\twater: waiting:\n\n"
    assert TextFile.encode(document) == body
    assert TextFile.copy_text(document) == body

    assert {:ok, edited, next_role} = TextFile.replace_title(document, role, "  A new title  ")
    assert edited.body == "\r\n  A new title  " <> after_title
    assert {:ok, "  A new title  "} = TextFile.title(edited, next_role)
    assert TextFile.copy_text(edited) == edited.body
    assert {:error, :title_needs_review} = TextFile.title(edited, role)
  end

  test "title role selects a line even when the same words occur again" do
    assert {:ok, document} = TextFile.decode("rain\n\nrain\n\train\n")
    assert {:ok, role} = TextFile.mark_title(document, 3)
    assert {:ok, edited, _} = TextFile.replace_title(document, role, "the rain")
    assert edited.body == "rain\n\nthe rain\n\train\n"
  end

  test "external changes invalidate the title anchor instead of guessing at its new position" do
    assert {:ok, document} = TextFile.decode("Title\n\nbody\n")
    assert {:ok, role} = TextFile.mark_title(document, 1)

    for body <- ["Other\n\nbody\n", "new opening\nTitle\n\nbody\n", "Title\n\nnew body\n"] do
      assert {:ok, changed} = TextFile.decode(body)
      assert {:error, :title_needs_review} = TextFile.title(changed, role)
      assert {:error, :title_needs_review} = TextFile.replace_title(changed, role, "overwrite")
      assert changed.body == body
    end
  end

  test "line offsets use bytes and retain LF, CRLF, CR, and an absent final separator" do
    assert {:ok, document} = TextFile.decode("é\r\n\t雪\n\rLast")

    assert TextFile.lines(document) == [
             %{offset: 0, text: "é", ending: "\r\n"},
             %{offset: 4, text: "\t雪", ending: "\n"},
             %{offset: 9, text: "", ending: "\r"},
             %{offset: 10, text: "Last", ending: ""}
           ]
  end

  test "an empty file and trailing separator have blank lines, but no phantom line follows text" do
    for {body, count} <- [{"", 1}, {"words", 1}, {"words\n", 2}, {"\n\n", 3}] do
      assert {:ok, document} = TextFile.decode(body)
      assert length(TextFile.lines(document)) == count
      assert {:error, :missing_title_line} = TextFile.mark_title(document, count + 1)
    end
  end

  test "UTF-8 byte-order mark round trips but is not an extra character in the editor or copy" do
    bytes = <<239, 187, 191>> <> "Title\r\n\r\n  Body\n"
    assert {:ok, document} = TextFile.decode(bytes)
    assert {:ok, role} = TextFile.mark_title(document, 1)
    assert {:ok, next, _} = TextFile.replace_title(document, role, "Changed")
    assert TextFile.encode(document) == bytes
    assert TextFile.encode(next) == <<239, 187, 191>> <> "Changed\r\n\r\n  Body\n"
    assert TextFile.copy_text(document) == "Title\r\n\r\n  Body\n"
  end

  @tag :tmp_dir
  test "unsupported input and cloud references are reported without conversion", %{tmp_dir: root} do
    cases = [
      {"utf16", <<255, 254, 84, 0>>, :unsupported_encoding},
      {"latin1", <<99, 97, 102, 233>>, :unsupported_encoding},
      {"null", "a\0b", :binary_content},
      {"document", "%PDF-1.7\n", :binary_document},
      {"rich-text", "{\\rtf1 words}", :binary_document},
      {"word", <<"PK", 3, 4, 0>>, :binary_document},
      {"unprepared.gdoc", ~s({"url":"https://example.invalid"}), :cloud_document_reference}
    ]

    for {name, bytes, reason} <- cases do
      path = Path.join(root, name)
      File.write!(path, bytes)
      assert {:error, ^reason} = TextFile.read(path)
      assert File.read!(path) == bytes
    end

    assert {:error, :enoent} = TextFile.read(Path.join(root, "missing"))
    assert {:error, :not_regular_file} = TextFile.read(root)
    linked = Path.join(root, "linked")
    File.ln_s!(Path.join(root, "document"), linked)
    assert {:error, :not_regular_file} = TextFile.read(linked)
  end

  test "blank, missing, multiline, and malformed title roles do not produce an edited document" do
    assert {:ok, document} = TextFile.decode("\n  \nwords")
    assert {:error, :missing_title_line} = TextFile.mark_title(document, 1)
    assert {:error, :blank_title} = TextFile.mark_title(document, 2)
    assert {:error, :missing_title_line} = TextFile.mark_title(document, 10)
    assert {:error, :missing_title_line} = TextFile.mark_title(document, 0)
    assert {:ok, role} = TextFile.mark_title(document, 3)
    assert {:error, :multiline_title} = TextFile.replace_title(document, role, "two\nlines")
    assert {:error, :blank_title} = TextFile.replace_title(document, role, "  ")
    assert {:error, :invalid_title_role} = TextFile.title(document, %{line: 1})
    assert {:error, :no_title_role} = TextFile.replace_title(document, nil, "title")
    assert TextFile.encode(document) == "\n  \nwords"
  end
end

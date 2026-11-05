defmodule Still.Manuscript do
  @moduledoc """
  Read-only manuscript downloads. Preparation exports use the reviewed current pieces;
  submitted exports use the validated frozen bundle, never the current writing files.
  No export changes a packet's status or writes into a collection.
  """
  alias Still.Correspondence

  def export(location, id, format) when format in ["txt", "docx"] do
    with {:ok, source} <- Correspondence.export_packet(location, id),
         {:ok, body} <- encode(source.pieces, format) do
      {:ok, %{body: body, filename: "still-manuscript-#{id}.#{format}", frozen?: source.frozen?}}
    end
  end

  def export(_, _, _), do: {:error, "Choose a manuscript in DOCX or plain text format."}

  @doc false
  def encode(pieces, "txt") do
    {:ok, Enum.map_join(pieces, "\n\n\f\n\n", &full_text/1)}
  end

  def encode(pieces, "docx") do
    if Enum.all?(pieces, &(xml_text?(&1.title) and xml_text?(&1.body))) do
      paragraphs =
        pieces
        |> Enum.with_index()
        |> Enum.map_join(fn {piece, index} ->
          page_break = if index > 0, do: "<w:pageBreakBefore/>", else: ""

          if piece[:title_in_body] do
            "<w:p><w:pPr>#{page_break}<w:spacing w:after=\"0\" w:line=\"300\" w:lineRule=\"auto\"/></w:pPr>#{run(piece.body)}</w:p>"
          else
            "<w:p><w:pPr><w:pStyle w:val=\"Title\"/>#{page_break}</w:pPr>#{run(piece.title)}</w:p>" <>
              "<w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"300\" w:lineRule=\"auto\"/></w:pPr>#{run(piece.body)}</w:p>"
          end
        end)

      document = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>#{paragraphs}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720"/></w:sectPr></w:body></w:document>
      """

      files = [
        {~c"[Content_Types].xml",
         """
         <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
         <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
         """},
        {~c"_rels/.rels",
         """
         <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
         <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="document" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
         """},
        {~c"word/_rels/document.xml.rels",
         """
         <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
         <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="styles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
         """},
        {~c"word/styles.xml",
         """
         <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
         <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia"/><w:sz w:val="24"/><w:color w:val="000000"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:after="480"/></w:pPr><w:rPr><w:sz w:val="32"/><w:color w:val="000000"/></w:rPr></w:style></w:styles>
         """},
        {~c"word/document.xml", document}
      ]

      case :zip.create(~c"manuscript.docx", files, [:memory]) do
        {:ok, {_, binary}} ->
          {:ok, binary}

        {:error, _} ->
          {:error, "The manuscript could not be prepared. Your writing is unchanged."}
      end
    else
      {:error,
       "This writing contains characters DOCX cannot represent. Download plain text to preserve them."}
    end
  end

  # Line endings are rendered as line breaks; the authoritative UTF-8 snapshot remains exact.
  defp full_text(%{title_in_body: true, body: body}), do: body
  defp full_text(piece), do: piece.title <> "\n\n" <> piece.body

  defp run(text) do
    contents =
      Regex.split(~r/(\r\n|\r|\n|\t)/, text, include_captures: true)
      |> Enum.map_join(fn
        "\t" -> "<w:tab/>"
        newline when newline in ["\n", "\r", "\r\n"] -> "<w:br/>"
        text -> "<w:t xml:space=\"preserve\">#{escape(text)}</w:t>"
      end)

    "<w:r>#{contents}</w:r>"
  end

  defp xml_text?(text) do
    String.valid?(text) and
      Enum.all?(String.to_charlist(text), fn c ->
        c in [9, 10, 13] or c in 0x20..0xD7FF or c in 0xE000..0xFFFD or
          c in 0x10000..0x10FFFF
      end)
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end

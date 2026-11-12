defmodule StillWeb.EchoesTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias StillWeb.Echoes

  test "reading retains authored blank lines and search targets while listening controls stay outside the text" do
    body = "\n  first <word>  \n\tsecond\n\nlast\n"

    html =
      render_component(&Echoes.reading/1, %{
        body: body,
        id_prefix: "passage",
        query: "second",
        target_line: 3,
        active_line: 2,
        document_id: 1
      })

    parsed = LazyHTML.from_fragment(html)
    lines = LazyHTML.query(parsed, "[data-authored-line]") |> Enum.map(&LazyHTML.text/1)
    assert Enum.join(lines, "\n") == body
    assert Enum.count(LazyHTML.query(parsed, "#passage-3[data-search-target=true]")) == 1

    assert Enum.count(
             LazyHTML.query(parsed, "[data-echo-line='2'].passage-focused[tabindex='0']")
           ) == 1

    assert Enum.count(LazyHTML.query(parsed, "[data-authored-line] button")) == 0
    assert Enum.count(LazyHTML.query(parsed, "word")) == 0
  end

  test "an echo unfolds literal neighboring lines from the same stanza and escapes authored markup" do
    entry = %{
      id: 12,
      title: "Earlier:",
      origin: "before",
      body: "Before <b>rain</b>\nThe matched line\nAfter & still\n\nAnother stanza",
      source: %{},
      notebook: "Synthetic"
    }

    fragment = %{
      entry: entry,
      line: "The matched line",
      side: :left,
      distance: :near,
      motion: :settling,
      departing: false,
      height: 40,
      strength: 0.6,
      delay: 0,
      place: %{label: "Synthetic"}
    }

    html = render_component(&Echoes.field/1, %{fragments: [fragment]})
    parsed = LazyHTML.from_fragment(html)
    assert LazyHTML.query(parsed, ".echo-unfolded") |> LazyHTML.text() =~ "Before <b>rain</b>"
    assert LazyHTML.query(parsed, ".echo-unfolded") |> LazyHTML.text() =~ "After & still"
    refute html =~ "Another stanza"
    assert Enum.count(LazyHTML.query(parsed, ".echo-unfolded b")) == 0

    assert Enum.count(LazyHTML.query(parsed, ".gravity-door[href='/w/12?read=1&approach=left']")) ==
             1
  end

  test "an echo never unfolds an adjacent machine poem reference" do
    marker = "[[poem: Current Notebooks/Source.txt | 00000000-0000-4000-8000-000000000001]]"

    entry = %{
      id: 13,
      title: "A host:",
      origin: "before",
      body:
        "A nearby authored thought\nThe matched line\n" <> marker <> "\nAnother authored thought",
      source: %{},
      notebook: "Synthetic"
    }

    fragment = %{
      entry: entry,
      line: "The matched line",
      side: :left,
      distance: :near,
      motion: :settling,
      departing: false,
      height: 40,
      strength: 0.6,
      delay: 0,
      place: %{label: "Synthetic"}
    }

    html = render_component(&Echoes.field/1, %{fragments: [fragment]})
    unfolded = LazyHTML.from_fragment(html) |> LazyHTML.query(".echo-unfolded") |> LazyHTML.text()
    assert unfolded =~ "A nearby authored thought"
    refute unfolded =~ "[[poem:"
  end
end

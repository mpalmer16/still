defmodule StillWeb.ThreadsLive do
  use StillWeb, :live_view

  alias Still.Storage
  alias Still.Writing.Threads

  @impl true
  def mount(_, _, socket) do
    collection = Threads.load(Storage.collection_location())
    {:ok, assign(socket, collection: collection, visible: 8, input_problem: nil)}
  end

  @impl true
  def handle_params(params, _, socket) do
    documents = socket.assigns.collection.documents
    from = Enum.find(documents, &(&1.key == params["from"]))
    words = Threads.words(documents, if(from, do: [from: from.key], else: []))
    requested = params["word"]
    word = if requested, do: Threads.normalize_word(requested), else: List.first(words) || ""
    passages = Threads.passages(documents, word)
    step = parse_step(params["crossing"])
    pair = Threads.pair(passages, step)
    whole = params["view"] == "whole"

    {:noreply,
     assign(socket,
       page_title: if(word == "", do: "Threads", else: "#{word} · Threads"),
       word: word,
       words: words,
       passages: passages,
       pair: pair,
       crossings: Threads.crossing_count(passages),
       step: step,
       whole: whole,
       from: from,
       missing_source: params["from"] != nil && from == nil,
       form: to_form(%{"word" => word}, as: :thread),
       input_problem: if(requested && word == "", do: "Choose one word, up to 64 letters."),
       visible: 8
     )}
  end

  @impl true
  def handle_event("follow_word", %{"thread" => %{"word" => input}}, socket) do
    case Threads.normalize_word(input) do
      "" ->
        {:noreply, assign(socket, :input_problem, "Choose one word, up to 64 letters.")}

      word ->
        {:noreply, push_patch(socket, to: thread_path(word, socket.assigns.from))}
    end
  end

  def handle_event("another_word", _, socket) do
    words = socket.assigns.words
    index = Enum.find_index(words, &(&1 == socket.assigns.word))
    next = Enum.at(words, if(index, do: rem(index + 1, max(length(words), 1)), else: 0))
    {:noreply, push_patch(socket, to: thread_path(next || "", socket.assigns.from))}
  end

  def handle_event("more_passages", _, socket),
    do: {:noreply, update(socket, :visible, &(&1 + 8))}

  defp thread_path(word, from, opts \\ []) do
    params = [word: word] ++ if(from, do: [from: from.key], else: [])
    ~p"/threads?#{params ++ opts}"
  end

  defp parse_step(value) when is_binary(value) do
    case Integer.parse(value) do
      {step, ""} when step >= 0 and step <= 1_000_000 -> step
      _ -> 0
    end
  end

  defp parse_step(_), do: 0

  defp source_path(%{kind: :before, id: id}), do: ~p"/w/#{id}?read=1"
  defp source_path(%{kind: :file, id: id}), do: ~p"/writing/#{id}"
  defp source_kind(%{kind: :before}), do: "From before"
  defp source_kind(_), do: "Kept here"

  defp other_passages(passages, nil), do: passages

  defp other_passages(passages, {left, right}),
    do: Enum.reject(passages, &(&1.document.key in [left.document.key, right.document.key]))

  attr :text, :string, required: true
  attr :word, :string, required: true

  defp literal_words(assigns) do
    parts =
      Regex.split(~r/([\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*)/u, assigns.text,
        include_captures: true
      )

    assigns =
      assign(
        assigns,
        :parts,
        Enum.map(
          parts,
          &%{text: &1, match: assigns.word != "" && Threads.normalize_word(&1) == assigns.word}
        )
      )

    ~H"""
    <span phx-no-format><%= for part <- @parts do %><mark :if={part.match}>{part.text}</mark><%= if !part.match do %>{part.text}<% end %><% end %></span>
    """
  end

  attr :passage, :map, required: true
  attr :word, :string, required: true
  attr :whole, :boolean, default: false
  attr :side, :string, required: true

  defp page(assigns) do
    ~H"""
    <article id={"thread-#{@side}"} class="thread-page">
      <header class="thread-source">
        <span class="thread-eyebrow">{source_kind(@passage.document)}</span>
        <span class="thread-provenance">{@passage.document.label}</span>
      </header>
      <h2 class="thread-page-title">
        <.link navigate={source_path(@passage.document)}>{@passage.document.title}</.link>
      </h2>
      <div class={"thread-body #{if @whole, do: "thread-whole"}"} phx-no-format><.literal_words text={if @whole, do: @passage.document.body, else: @passage.text} word={@word} /></div>
      <.link navigate={source_path(@passage.document)} class="thread-read quiet-link">Open this page
      <span aria-hidden="true">↗</span></.link>
    </article>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active="threads"
      room_light={@room_light}
      light_open={@light_open}
      room_letters={@room_letters}
      letters_open={@letters_open}
      landscape_open={@landscape_open}
      places={@places}
      place={@place}
    >
      <div class="threads-room">
        <header class="threads-heading">
          <p class="thread-eyebrow">Threads through your writing</p>
          <h1>A word travels<span>.</span></h1>
          <p class="threads-intro">Older notebooks. Newer pages. A little language between them.</p>
        </header>

        <p :if={@collection.problem} id="threads-problem" class="recovery-note" role="alert">
          {@collection.problem} Historical notebooks are still available here.
          <.link navigate={~p"/storage"}>Storage &amp; Backups</.link>
        </p>
        <p :if={@missing_source} id="threads-source-missing" class="file-note" role="status">
          That page isn't in the available collection. You can still follow a word below.
        </p>
        <p :if={@from} class="threads-from">
          A thread from
          <.link navigate={source_path(@from)}>{@from.title}</.link><.link
            id="threads-all"
            patch={~p"/threads"}
            class="quiet-link"
          >All writing</.link>
        </p>

        <nav :if={@words != []} class="thread-words" aria-label="Words found across your writing">
          <.link
            :for={word <- @words}
            patch={thread_path(word, @from)}
            class={if word == @word, do: "thread-word current", else: "thread-word"}
            aria-current={if word == @word, do: "true"}
          >{word}</.link>
        </nav>

        <div :if={@word != ""} id="thread-word-heading" class="thread-focus">
          <span class="thread-rule" aria-hidden="true"></span>
          <h2>{@word}</h2>
          <span class="thread-rule" aria-hidden="true"></span>
        </div>

        <section :if={@pair} id="thread-crossing" aria-label={"Two pages carrying “#{@word}”"}>
          <div class="thread-reading-controls">
            <span class="thread-eyebrow">A word in two places</span>
            <div class="thread-view-controls" aria-label="Reading length">
              <.link
                id="thread-passages"
                patch={thread_path(@word, @from, crossing: @step)}
                aria-current={if !@whole, do: "true"}
                class="quiet-link"
              >Passages</.link>
              <.link
                id="thread-whole-pages"
                patch={thread_path(@word, @from, crossing: @step, view: "whole")}
                aria-current={if @whole, do: "true"}
                class="quiet-link"
              >Whole pages</.link>
            </div>
          </div>
          <div id={"thread-pair-#{@step}-#{@word}"} class="thread-pair">
            <.page passage={elem(@pair, 0)} word={@word} whole={@whole} side="left" />
            <.page passage={elem(@pair, 1)} word={@word} whole={@whole} side="right" />
          </div>
          <div class="thread-crossing-foot">
            <span>Read across. Let the distance stay.</span>
            <.link
              :if={@crossings > 1}
              id="another-crossing"
              patch={
                thread_path(@word, @from,
                  crossing: @step + 1,
                  view: if(@whole, do: "whole", else: "passages")
                )
              }
              class="quiet-link"
            >Another crossing <span aria-hidden="true">↗</span></.link>
          </div>
        </section>

        <section
          :if={other_passages(@passages, @pair) != []}
          id="thread-elsewhere"
          class="thread-elsewhere"
          aria-label="More places carrying this word"
        >
          <h2 class="thread-eyebrow">
            {if @pair, do: "The word continues", else: "Where the word lives"}
          </h2>
          <div class="thread-passages">
            <article
              :for={passage <- Enum.take(other_passages(@passages, @pair), @visible)}
              id={"thread-passage-#{passage.document.key}"}
              class="thread-passage"
            >
              <.link navigate={source_path(passage.document)}>
                <span class="thread-passage-source">{source_kind(passage.document)}
                <span aria-hidden="true">/</span> {passage.document.label}</span>
                <div class="thread-body" phx-no-format><.literal_words text={passage.text} word={@word} /></div>
                <span class="thread-passage-title">{passage.document.title}
                <span aria-hidden="true">↗</span></span>
              </.link>
            </article>
          </div>
          <button
            :if={length(other_passages(@passages, @pair)) > @visible}
            id="more-thread-passages"
            phx-click="more_passages"
            class="quiet-link"
          >Keep following</button>
        </section>

        <div :if={@passages == []} id="threads-empty" class="threads-empty">
          <p>
            {if @word == "", do: "Some words find their way back.", else: "That word is quiet here."}
          </p>
          <span>{if @collection.documents == [],
            do: "As you keep pages or bring notebooks into Still, their words can meet here.",
            else: "Follow another word, or bring one of your own."}</span>
          <.link :if={@collection.documents == []} navigate={~p"/"} class="quiet-link">Return to Write</.link>
        </div>

        <footer class="threads-footer">
          <button
            :if={length(@words) > 1}
            id="another-thread"
            phx-click="another_word"
            class="quiet-link"
          >Let another word find me <span aria-hidden="true">↗</span></button>
          <details class="thread-own-word" open={@input_problem != nil}>
            <summary class="quiet-link">A word of your own</summary>
            <.form for={@form} id="thread-word-form" phx-submit="follow_word">
              <label for="thread-word-input" class="sr-only">A word to follow</label>
              <input
                id="thread-word-input"
                name="thread[word]"
                value={@form[:word].value}
                maxlength="64"
                autocomplete="off"
                placeholder="A word to follow"
                aria-describedby={if @input_problem, do: "thread-input-problem"}
              />
              <button type="submit" class="quiet-link">Follow <span aria-hidden="true">↗</span></button>
            </.form>
            <p :if={@input_problem} id="thread-input-problem" role="status">{@input_problem}</p>
          </details>
        </footer>
        <p class="threads-colophon">
          Only your words, in their own places. Nothing rearranged or rewritten.
        </p>
      </div>
    </Layouts.app>
    """
  end
end

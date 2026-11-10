// Textareas remain the writing controls. The single canonical field owns saving
// and recovery; these helpers join its editable stretches around HEEx passages.
export function linkedParts(body) {
  const parts = [], pattern = /^\[\[poem: ([^\]\r\n]+?)\]\](?=\r?$)/gm
  let previous = 0
  for (const match of body.matchAll(pattern)) {
    const fields = match[1].split(" | ")
    if (fields.length > 2 || (fields.length === 2 && !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(fields[1]))) continue
    let path
    try { path = decodeURIComponent(fields[0]) } catch { continue }
    if (!path || path.startsWith("/") || path.split("/").some(part => ["", ".", ".."].includes(part)) || /[\x00-\x1f\x7f]/.test(path)) continue
    parts.push({kind: "text", raw: body.slice(previous, match.index)})
    parts.push({kind: "reference", raw: match[0]})
    previous = match.index + match[0].length
  }
  parts.push({kind: "text", raw: body.slice(previous)})
  return parts
}

export function insertReference(body, position, marker) {
  // Inserting never replaces selected words. Make a new paragraph at the caret.
  const at = Math.max(0, Math.min(body.length, position))
  const before = body.slice(0, at), after = body.slice(at)
  const prefix = before === "" || before.endsWith("\n\n") ? "" : before.endsWith("\n") ? "\n" : "\n\n"
  const suffix = after.startsWith("\n\n") ? "" : after.startsWith("\n") ? "\n" : "\n\n"
  const inserted = prefix + marker + suffix
  return {body: before + inserted + after, caret: at + inserted.length}
}

export function expandedCopy(body, sources) {
  return linkedParts(body).map(part => part.kind === "reference" && Object.hasOwn(sources, part.raw)
    ? sources[part.raw] : part.raw).join("")
}

export function editableStretch(raw, followsReference, precedesReference) {
  let before = '', after = '', value = raw
  if (followsReference) {
    before = value.match(/^(\r\n|\r|\n)/)?.[0] || ''
    value = value.slice(before.length)
  }
  if (precedesReference) {
    after = value.match(/(\r\n|\r|\n)$/)?.[0] || ''
    value = value.slice(0, value.length - after.length)
  }
  return {before, value, after}
}

export const LinkedWriting = {
  mounted() {
    this.canonical = this.el.querySelector('#file-writing-body')
    this.projected = this.el.querySelector('[data-linked-passages]')
    this.form = this.canonical.form
    this.canonical.linkedEditor = this
    this.position = this.canonical.selectionEnd
    this.generation = null
    this.owns = field => field?.matches?.('[data-writing-segment]') && this.el.contains(field)
    this.parts = () => [...this.projected.querySelectorAll('[data-writing-part]')]
    this.selection = field => {
      let offset = 0
      for (const node of this.parts()) {
        const textarea = node.querySelector('textarea')
        const before = node.dataset.before || '', after = node.dataset.after || ''
        if (textarea === field) return {start: offset + before.length + field.selectionStart, end: offset + before.length + field.selectionEnd, direction: field.selectionDirection}
        offset += textarea ? before.length + textarea.value.length + after.length : node.dataset.referenceRaw.length
      }
      return null
    }
    this.remember = field => {
      const position = this.selection(field)
      if (position) {
        this.canonical.setSelectionRange(position.start, position.end, position.direction)
        this.position = position.end
      }
    }
    this.capture = () => {
      if (!this.ready) return
      const focused = document.activeElement
      const parts = this.parts()
      const body = parts.map((node, index) => {
        const field = node.querySelector('textarea')
        if (!field) return node.dataset.referenceRaw
        if (field.value !== '') {
          if (index > 0 && !node.dataset.before) node.dataset.before = '\n'
          if (index < parts.length - 1 && !node.dataset.after) node.dataset.after = '\n'
        }
        return (node.dataset.before || '') + field.value + (node.dataset.after || '')
      }).join('')
      if (this.canonical.value !== body) this.canonical.value = body
      if (this.owns(focused)) this.remember(focused)
    }
    this.focus = () => {
      if (!this.ready) { this.canonical.focus({preventScroll: true}); return }
      let offset = 0, fallback
      const start = this.canonical.selectionStart, end = this.canonical.selectionEnd
      for (const node of this.parts()) {
        const field = node.querySelector('textarea'), before = node.dataset.before || '', after = node.dataset.after || ''
        const length = field ? before.length + field.value.length + after.length : node.dataset.referenceRaw.length
        if (field) {
          fallback = field
          if (start <= offset + length) {
            field.focus({preventScroll: true})
            field.setSelectionRange(Math.max(0, start - offset - before.length), Math.min(field.value.length, Math.max(0, end - offset - before.length)), this.canonical.selectionDirection)
            this.remember(field)
            return
          }
        }
        offset += length
      }
      fallback?.focus({preventScroll: true})
    }
    this.fit = () => {
      const scroll = window.scrollY
      for (const field of this.projected.querySelectorAll('textarea')) {
        field.style.height = 'auto'
        field.style.height = `${Math.max(field.scrollHeight, Number.parseFloat(getComputedStyle(field).lineHeight) || 40)}px`
      }
      if (window.scrollY !== scroll) window.scrollTo({top: scroll, behavior: 'instant'})
    }
    this.sync = () => {
      const parts = linkedParts(this.canonical.value)
      const markers = parts.filter(part => part.kind === 'reference').map(part => part.raw)
      const rendered = JSON.parse(this.projected.dataset.markers)
      const ready = markers.length > 0 && JSON.stringify(markers) === JSON.stringify(rendered)
      const changed = this.generation !== this.projected.dataset.generation
      const wasEditor = document.activeElement === this.canonical || this.owns(document.activeElement)
      this.ready = ready
      this.el.dataset.linkedReady = String(ready)
      this.projected.hidden = !ready
      if (ready && (changed || this.renderedBody !== this.canonical.value)) {
        const fields = [...this.projected.querySelectorAll('textarea')]
        parts.filter(part => part.kind === 'text').forEach((part, index, stretches) => {
          const field = fields[index]
          if (!field) return
          const editable = editableStretch(part.raw, index > 0, index < stretches.length - 1)
          field.parentElement.dataset.before = editable.before
          field.parentElement.dataset.after = editable.after
          if (field.value !== editable.value) field.value = editable.value
        })
        this.fit()
      }
      this.generation = this.projected.dataset.generation
      this.renderedBody = this.canonical.value
      if ((wasEditor || this.pendingFocus) && changed) { this.pendingFocus = false; this.focus() }
    }
    this.onInput = event => {
      if (event.target === this.canonical) {
        this.position = this.canonical.selectionEnd
        const markers = linkedParts(this.canonical.value).filter(part => part.kind === 'reference').map(part => part.raw)
        if (JSON.stringify(markers) !== this.projected.dataset.markers && this.lastRequestedBody !== this.canonical.value) {
          this.lastRequestedBody = this.canonical.value
          this.pushEvent('poem_structure_changed', {body: this.canonical.value})
        }
        return
      }
      if (!this.owns(event.target)) return
      this.capture()
      this.canonical.dispatchEvent(new Event('input', {bubbles: true}))
      this.fit()
    }
    this.onSelection = event => {
      if (this.owns(event.target)) {
        this.capture(); this.remember(event.target)
        this.canonical.dispatchEvent(new Event('select'))
      } else if (event.target === this.canonical) this.position = this.canonical.selectionEnd
    }
    this.onComposition = event => {
      if (this.owns(event.target)) this.canonical.dispatchEvent(new Event(event.type))
    }
    this.onDisplay = () => this.sync()
    this.onInsert = () => {
      this.capture()
      if (document.activeElement === this.canonical) this.position = this.canonical.selectionEnd
      else if (this.owns(document.activeElement)) this.remember(document.activeElement)
      this.pushEvent('open_poem_picker', {})
    }
    this.onClick = event => {
      const insert = event.target.closest('[data-insert-poem]')
      const remove = event.target.closest('[data-remove-poem]')
      if (insert) { event.preventDefault(); this.onInsert() }
      if (remove) {
        event.preventDefault(); this.capture()
        let offset = 0
        for (const node of this.parts()) {
          const field = node.querySelector('textarea'), raw = field ? (node.dataset.before || '') + field.value + (node.dataset.after || '') : node.dataset.referenceRaw
          if (node.contains(remove)) {
            this.pendingFocus = true
            this.canonical.value = this.canonical.value.slice(0, offset) + this.canonical.value.slice(offset + raw.length)
            this.canonical.setSelectionRange(offset, offset)
            this.canonical.dispatchEvent(new Event('input', {bubbles: true}))
            break
          }
          offset += raw.length
        }
      }
    }
    this.onKey = event => {
      if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === 'i') {
        event.preventDefault(); this.onInsert()
      }
      const field = event.target
      if (this.owns(field) && !event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey && field.selectionStart === field.selectionEnd) {
        const fields = [...this.projected.querySelectorAll('textarea')], index = fields.indexOf(field)
        const next = event.key === 'ArrowDown' && field.selectionEnd === field.value.length ? fields[index + 1] :
          event.key === 'ArrowUp' && field.selectionStart === 0 ? fields[index - 1] : null
        if (next) {
          event.preventDefault(); next.focus()
          const position = event.key === 'ArrowDown' ? 0 : next.value.length
          next.setSelectionRange(position, position); this.remember(next)
        }
      }
    }
    this.el.addEventListener('input', this.onInput, true)
    this.el.addEventListener('compositionstart', this.onComposition)
    this.el.addEventListener('compositionend', this.onComposition)
    for (const name of ['focusin', 'select', 'keyup', 'pointerup']) this.el.addEventListener(name, this.onSelection)
    this.form.addEventListener('still:writing-display-changed', this.onDisplay)
    document.addEventListener('click', this.onClick)
    document.addEventListener('keydown', this.onKey)
    window.addEventListener('still:insert-poem', this.onInsert)
    this.handleEvent('insert-poem-reference', ({marker}) => {
      this.capture()
      this.pendingFocus = true
      const inserted = insertReference(this.canonical.value, this.position, marker)
      this.canonical.value = inserted.body
      this.canonical.setSelectionRange(inserted.caret, inserted.caret)
      this.position = inserted.caret
      this.canonical.dispatchEvent(new Event('input', {bubbles: true}))
      this.focus()
    })
    this.sync()
  },
  updated() { this.sync() },
  destroyed() {
    this.el.removeEventListener('input', this.onInput, true)
    this.el.removeEventListener('compositionstart', this.onComposition)
    this.el.removeEventListener('compositionend', this.onComposition)
    for (const name of ['focusin', 'select', 'keyup', 'pointerup']) this.el.removeEventListener(name, this.onSelection)
    this.form.removeEventListener('still:writing-display-changed', this.onDisplay)
    document.removeEventListener('click', this.onClick)
    document.removeEventListener('keydown', this.onKey)
    window.removeEventListener('still:insert-poem', this.onInsert)
    delete this.canonical.linkedEditor
  },
}

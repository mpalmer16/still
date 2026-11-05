// Caret and selection are only a listening position. This helper never edits,
// saves, focuses, scrolls, or stores the writing surface.
export function echoAttention(el, send, {documentId, doc = document, clock = window} = {}) {
  let timer = null, last = null, connected = true, composing = false, destroyed = false
  const cancel = () => { if (timer !== null) clock.clearTimeout(timer); timer = null }
  const schedule = () => {
    cancel()
    if (!connected || composing || destroyed) return
    timer = clock.setTimeout(() => {
      timer = null
      if (!connected || composing || destroyed || !el.isConnected || doc.activeElement !== el) return
      const id = String(documentId()), body = el.value, start = el.selectionStart, end = el.selectionEnd
      if (!Number.isInteger(start) || !Number.isInteger(end)) return
      if (last && last.id === id && last.body === body && last.start === start && last.end === end) return
      last = {id, body, start, end}
      send(last)
    }, 250)
  }
  const compositionStart = () => { composing = true; cancel() }
  const compositionEnd = () => { composing = false; schedule() }
  const events = ['input', 'keyup', 'pointerup', 'select', 'focus']
  events.forEach(event => el.addEventListener(event, schedule))
  el.addEventListener('compositionstart', compositionStart)
  el.addEventListener('compositionend', compositionEnd)
  schedule()
  return {
    schedule,
    disconnect() { connected = false; last = null; cancel() },
    reconnect() { connected = true; last = null; schedule() },
    destroy() {
      destroyed = true; cancel()
      events.forEach(event => el.removeEventListener(event, schedule))
      el.removeEventListener('compositionstart', compositionStart)
      el.removeEventListener('compositionend', compositionEnd)
    },
  }
}

// Reading attention is a passage identifier, sent only after the pointer settles
// or a reader focuses or selects text. Leaving a passage keeps its echoes reachable.
export function passageAttention(el, send, {doc = document, clock = window} = {}) {
  let timer = null, last = null, connected = true, pressing = false, hovering = false
  const passage = node => {
    const found = (node?.nodeType === 3 ? node.parentElement : node)?.closest?.("[data-echo-line]")
    return found && el.contains(found) ? found : null
  }
  const selection = () => {
    const range = doc.getSelection()
    return range && !range.isCollapsed && el.contains(range.anchorNode)
      ? (passage(range.focusNode) || passage(range.anchorNode)) : null
  }
  const cancel = () => {
    if (timer !== null) clock.clearTimeout(timer)
    timer = null
    hovering = false
  }
  const schedule = (target, delay, hover = false) => {
    cancel()
    if (!connected || !target) return
    hovering = hover
    timer = clock.setTimeout(() => {
      timer = null
      hovering = false
      const line = target.dataset.echoLine
      if (pressing || !el.contains(target) || line === last) return
      last = line
      send({id: el.dataset.echoDocument, line})
    }, delay)
  }
  const events = {
    pointerover(event) {
      if (event.pointerType !== "mouse" || pressing || selection()) return
      const target = passage(event.target)
      if (target && target !== passage(event.relatedTarget)) schedule(target, 450, true)
    },
    pointerout(event) {
      if (hovering && passage(event.target) !== passage(event.relatedTarget)) cancel()
    },
    pointerdown() { pressing = true; cancel() },
    pointerup(event) { pressing = false; schedule(selection() || passage(event.target), 80) },
    pointercancel() { pressing = false; cancel() },
    focusin(event) { if (!pressing) schedule(passage(event.target), 120) },
    keyup() { const target = selection(); if (target) schedule(target, 120) },
    click(event) {
      if (event.target.closest?.("[data-clear-passage-focus]")) { last = null; cancel() }
    },
  }
  for (const [name, listener] of Object.entries(events)) el.addEventListener(name, listener)
  // A drag can end outside the reader.
  const release = event => {
    if (!el.contains(event.target)) {
      pressing = false
      schedule(selection(), 80)
    }
  }
  doc.addEventListener("pointerup", release)
  return {
    disconnect() { connected = false; pressing = false; last = null; cancel() },
    reconnect() { connected = true },
    destroy() {
      cancel()
      for (const [name, listener] of Object.entries(events)) el.removeEventListener(name, listener)
      doc.removeEventListener("pointerup", release)
    },
  }
}

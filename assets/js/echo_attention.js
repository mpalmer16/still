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

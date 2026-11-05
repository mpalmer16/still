// Presentation only: never changes words, selection, recovery, or save behavior.
export function writingFocus(page, doc = document, clock = window) {
  const body = page.querySelector("#file-writing-body")
  let timer, connected = true
  const reveal = () => {
    clock.clearTimeout(timer)
    doc.documentElement.removeAttribute("data-still-writing-focus")
  }
  const typing = event => {
    if (event.target !== body || doc.activeElement !== body || !connected) return
    clock.clearTimeout(timer)
    timer = clock.setTimeout(() => {
      if (connected && doc.activeElement === body) doc.documentElement.setAttribute("data-still-writing-focus", "")
    }, 400)
  }
  const focus = event => { if (event.target !== body) reveal() }
  const key = event => {
    if (["Escape", "Tab"].includes(event.key) || event.metaKey || event.ctrlKey || event.altKey) reveal()
  }
  const listeners = [
    [page, "input", typing], [doc, "pointermove", reveal], [doc, "pointerdown", reveal],
    [doc, "focusin", focus], [doc, "keydown", key], [clock, "blur", reveal],
    [clock, "phx:page-loading-start", reveal], [clock, "still:file-saved", reveal],
  ]
  for (const [target, event, listener] of listeners) target.addEventListener(event, listener)
  return {
    disconnect() { connected = false; reveal() },
    reconnect() { connected = true; reveal() },
    destroy() {
      reveal()
      for (const [target, event, listener] of listeners) target.removeEventListener(event, listener)
    },
  }
}

export const WritingFocus = {
  mounted() { this.focusRoom = writingFocus(this.el) },
  disconnected() { this.focusRoom.disconnect() },
  reconnected() { this.focusRoom.reconnect() },
  destroyed() { this.focusRoom.destroy() },
}

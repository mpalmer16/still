// Presentation only: never changes words, selection, recovery, or save behavior.
export function writingFocus(page, doc = document, clock = window) {
  const body = page.querySelector("#file-writing-body")
  let timer, connected = true, lastPointer = null
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
  const rememberPointer = event => {
    if (Number.isFinite(event.clientX) && Number.isFinite(event.clientY)) {
      lastPointer = {x: event.clientX, y: event.clientY}
    }
  }
  const pointermove = event => {
    const hasCoordinates = Number.isFinite(event.clientX) && Number.isFinite(event.clientY)
    const moved = (Number.isFinite(event.movementX) && event.movementX !== 0) ||
      (Number.isFinite(event.movementY) && event.movementY !== 0) ||
      (hasCoordinates && lastPointer && (event.clientX !== lastPointer.x || event.clientY !== lastPointer.y))
    rememberPointer(event)
    if (moved) reveal()
  }
  const key = event => {
    if (event.key === "Tab" && event.target === body && !event.isComposing &&
        !event.metaKey && !event.ctrlKey && !event.altKey) return
    if (["Escape", "Tab"].includes(event.key) || event.metaKey || event.ctrlKey || event.altKey) reveal()
  }
  const listeners = [
    [page, "input", typing], [doc, "pointermove", pointermove], [doc, "pointerdown", event => { rememberPointer(event); reveal() }],
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

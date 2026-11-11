export function openPieceFind(root = document) {
  const query = root.querySelector("#piece-find-query")
  if (query && !query.closest?.("[inert]")) { query.focus(); return true }
  const button = root.querySelector("#open-piece-find")
  if (!button || button.disabled || button.closest?.("[inert]")) return false
  button.click()
  return true
}

export function handleReadingShortcut(event, root = document) {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
    if (!openPieceFind(root)) return false
    event.preventDefault()
    return true
  }
  if (event.key === "Escape") {
    const close = root.querySelector("#close-piece-find")
    if (!close || close.closest?.("[inert]")) return false
    event.preventDefault()
    close.click()
    return true
  }
  if (event.key === "Backspace" && !event.isComposing && !event.target?.isComposing) {
    const target = event.target
    const editable = target?.closest?.("input, textarea, [contenteditable=''], [contenteditable='true']") ||
      target?.isContentEditable
    const reader = root.querySelector?.(".reading-room, #notebook-content")
    if (!editable && reader) {
      event.preventDefault()
      return true
    }
  }
  return false
}

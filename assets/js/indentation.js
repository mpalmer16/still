const leadingIndent = line => line.match(/^[\t ]*/)?.[0] ?? ""
const indentedNonblank = line => /^[\t ]+\S/.test(line)

export function indentationForEnter(value, start, end = start, shiftKey = false) {
  const lineStart = value.lastIndexOf("\n", start - 1) + 1
  const lineEnd = value.indexOf("\n", end)
  const currentLine = value.slice(lineStart, lineEnd < 0 ? value.length : lineEnd)
  const indent = leadingIndent(currentLine)

  // Carry only whitespace before the caret: any remaining indentation already
  // follows the break. This also continues a freshly indented empty line.
  if (start <= lineStart + indent.length) return value.slice(lineStart, start)
  if (shiftKey || !indentedNonblank(currentLine)) return indent

  const previousEnd = lineStart - 1
  if (previousEnd < 0) return indent
  const previousStart = value.lastIndexOf("\n", lineStart - 2) + 1
  const previousLine = value.slice(previousStart, previousEnd)
  const trailing = value.slice(end, lineEnd < 0 ? value.length : lineEnd)

  return indentedNonblank(previousLine) && trailing.trim() === "" ? "" : indent
}

// Prefer WebKit's native editing command so Enter participates in the editor's
// undo stack. setRangeText is a fallback for engines that reject insertText.
export function replaceSelection(textarea, text, start, end, mode = "end", exec) {
  const doc = globalThis.document
  exec ??= typeof doc?.execCommand === "function" ? doc.execCommand.bind(doc) : null
  textarea.setSelectionRange(start, end)
  if (exec?.("insertText", false, text)) {
    if (mode === "select") textarea.setSelectionRange(start, start + text.length)
    return true
  }

  textarea.setRangeText(text, start, end, mode)
  textarea.dispatchEvent(new Event("input", {bubbles: true}))
  return true
}

export function insertEnter(textarea, event, {composing = false, exec} = {}) {
  if (event.key !== "Enter" || event.isComposing || composing || event.metaKey || event.ctrlKey || event.altKey) {
    return false
  }

  const start = textarea.selectionStart
  const end = textarea.selectionEnd
  const text = `\n${indentationForEnter(textarea.value, start, end, event.shiftKey)}`
  event.preventDefault()
  replaceSelection(textarea, text, start, end, "end", exec)
  return true
}

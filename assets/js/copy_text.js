import {expandedCopy} from "./linked_writing"

export function copyPayload({body, title, title_source, title_in_body = false}, currentBody = body, currentTitle = title) {
  // Textareas normalize saved CRLF and CR to LF. Keep persisted bytes when
  // that normalization is the only apparent body change, independent of title edits.
  const normalizedBody = String(body ?? "").replace(/\r\n?/g, "\n")
  const bodyUnchanged = String(currentBody ?? "") === normalizedBody
  const exactBody = bodyUnchanged ? String(body ?? "") : String(currentBody ?? "")
  // In ordinary-file storage, even an explicit title is a role assigned to
  // lines already present in the document. Never prepend it a second time.
  if (title_in_body === true) return exactBody
  const normalizeTitle = value => typeof value === "string" && value.trim() !== "" ? value : null
  const titleChanged = normalizeTitle(currentTitle) !== normalizeTitle(title)
  const chosenTitle = titleChanged ? currentTitle : (title_source === "first_line" ? null : title)
  const explicitTitle = typeof chosenTitle === "string" && chosenTitle.trim() !== ""
  return explicitTitle ? `${chosenTitle}\n\n${exactBody}` : exactBody
}

export const CopyText = {
  mounted() {
    this.status = this.el.querySelector("[data-copy-status]")
    this.button = this.el.querySelector(".copy-text-button")
    this.onClick = async () => {
      try {
        const persisted = JSON.parse(this.el.dataset.persisted)
        const bodyField = this.el.dataset.bodySelector && document.querySelector(this.el.dataset.bodySelector)
        const titleField = this.el.dataset.titleSelector && document.querySelector(this.el.dataset.titleSelector)
        const body = bodyField ? bodyField.value : persisted.body
        const title = titleField ? titleField.value : persisted.title
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard access is unavailable")
        const text = copyPayload(persisted, body, title)
        await navigator.clipboard.writeText(expandedCopy(text, JSON.parse(this.el.dataset.referenceSources || "{}")))
        this.status.textContent = "Copied"
      } catch {
        this.status.textContent = "Could not copy. Check clipboard access and try again."
      }
      clearTimeout(this.statusTimer)
      this.statusTimer = setTimeout(() => { this.status.textContent = "" }, 3000)
    }
    this.button.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.button.removeEventListener("click", this.onClick)
    clearTimeout(this.statusTimer)
    this.statusTimer = null
  },
}

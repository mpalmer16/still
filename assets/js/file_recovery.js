import {insertEnter, replaceSelection} from "./indentation"

const fields = ["title_line", "relative_path", "notebook_id", "list_label", "source_order", "unplaced"]
const equal = (a, b) => a?.body === b?.body && String(a?.title ?? "") === String(b?.title ?? "") &&
  fields.every(field => String(a?.[field] ?? "") === String(b?.[field] ?? ""))
const valid = value => value && typeof value.body === "string" && typeof (value.title ?? "") === "string"
const unique = copies => [...new Map(copies.map(copy => [JSON.stringify([copy.body, copy.title ?? "", ...fields.map(field => copy[field] ?? "")]), copy])).values()]

const currentWords = value => {
  const words = {...value, title: ""}
  for (const field of fields) words[field] = words[field] == null ? "" : String(words[field])
  return words
}

export function readCopies(storage, key) {
  const raw = storage.getItem(key)
  if (raw === null) return {active: null, held: []}
  const bucket = JSON.parse(raw)
  if (!bucket || !(bucket.active === null || valid(bucket.active)) ||
      !Array.isArray(bucket.held) || !bucket.held.every(valid)) throw new Error("Unreadable writing recovery copy")
  return {active: bucket.active ? currentWords(bucket.active) : null, held: bucket.held.map(currentWords)}
}

function writeCopies(storage, key, bucket) {
  if (!bucket.active && bucket.held.length === 0) storage.removeItem(key)
  else storage.setItem(key, JSON.stringify(bucket))
}

export function holdArrival(storage, key, baseline) {
  const bucket = readCopies(storage, key)
  const held = unique([...bucket.held, ...(bucket.active ? [bucket.active] : [])]).filter(copy => !equal(copy, baseline))
  writeCopies(storage, key, {active: null, held})
  return held
}

export function captureCopy(storage, key, current, baseline) {
  const bucket = readCopies(storage, key)
  writeCopies(storage, key, {
    active: equal(current, baseline) ? null : {...current, at: Date.now()},
    held: bucket.held.filter(copy => !equal(copy, baseline)),
  })
}

export function captureAfterArrival(storage, key, current, baseline, arrivalPending) {
  // Never replace an arriving copy until it has been safely retained.
  if (arrivalPending) holdArrival(storage, key, baseline)
  captureCopy(storage, key, current, baseline)
}

export function restoreCopy(storage, key, copy, current, baseline) {
  const bucket = readCopies(storage, key)
  const held = unique([...bucket.held, ...[bucket.active, current].filter(Boolean)])
    .filter(item => !equal(item, copy) && !equal(item, baseline))
  writeCopies(storage, key, {active: {...copy, at: Date.now()}, held})
}

export function acknowledgeCopies(storage, source, target, saved) {
  const from = readCopies(storage, source)
  const to = source === target ? from : readCopies(storage, target)
  const copies = unique([...to.held, ...from.held, ...[to.active, from.active].filter(Boolean)])
    .filter(copy => !equal(copy, saved)).sort((a, b) => (b.at || 0) - (a.at || 0))
  // Publish the surviving copies before removing their former key.
  writeCopies(storage, target, {active: copies[0] || null, held: copies.slice(1)})
  if (target !== source) storage.removeItem(source)
}

export const positionKey = key => key.replace("still:poem-draft:", "still:file-position:")

export function resumableCopy(storage, key, token, resume) {
  const active = readCopies(storage, key).active
  return resume && active && (active.baseToken ?? null) === token ? active : null
}

export function migratePosition(storage, source, target) {
  if (source === target) return
  const position = storage.getItem(positionKey(source))
  if (position !== null) {
    storage.setItem(positionKey(target), position)
    storage.removeItem(positionKey(source))
  }
}

if (typeof window !== "undefined") {
  window.addEventListener("phx:file-saved", ({detail}) => {
    let recoveryKey = detail.target_key
    try { acknowledgeCopies(localStorage, detail.source_key, detail.target_key, detail) }
    catch { recoveryKey = detail.source_key }
    try { migratePosition(localStorage, detail.source_key, recoveryKey) } catch { /* Keep original position on failure. */ }
    window.dispatchEvent(new CustomEvent("still:file-saved", {detail: {...detail, recovery_key: recoveryKey}}))
  })

}

export const shouldBlockNavigation = (current, baseline, recoverySafe) => !recoverySafe && !equal(current, baseline)

export const FileRecovery = {
  mounted() {
    this.form = this.el.form
    this.field = name => this.form.elements.namedItem(`writing[${name}]`)
    this.title = this.field("title")
    if (this.title) this.title.value = ""
    this.key = this.el.dataset.draftKey
    this.baseline = currentWords(JSON.parse(this.el.dataset.persisted))
    this.baseToken = this.el.dataset.baseToken || null
    this.failed = false
    this.arrivalPending = true
    this.composing = false
    this.words = () => {
      const body = this.el.value
      if (this.title) this.title.value = ""
      const value = field => this.field(field)?.value ?? ""
      return {
        body: body === this.baseline.body.replace(/\r\n?/g, "\n") ? this.baseline.body : body,
        title: "",
        title_line: value("title_line"),
        relative_path: value("relative_path"),
        notebook_id: value("notebook_id"),
        list_label: value("list_label"),
        source_order: value("source_order"),
        unplaced: value("unplaced"),
      }
    }
    this.flags = () => {
      const dirty = !equal(this.words(), this.baseline)
      this.form.dataset.unsaved = String(dirty)
      this.form.dataset.recoverySafe = String(!this.failed)
      this.form.dataset.fileDraftKey = this.key
    }
    this.problem = () => {
      this.failed = true
      this.flags()
      this.pushEvent("file_recovery_unavailable", {})
    }
    this.pending = () => {
      const bucket = readCopies(localStorage, this.key)
      return unique([bucket.active, ...bucket.held].filter(Boolean)).filter(copy => !equal(copy, this.baseline))
        .sort((a, b) => (b.at || 0) - (a.at || 0))
    }
    this.offer = () => {
      try {
        this.offered = this.pending().find(copy => !equal(copy, this.words()))
        this.pushEvent("file_recovery_status", {waiting: Boolean(this.offered)})
      } catch { this.problem() }
    }
    this.fit = () => {
      const scroll = window.scrollY
      this.el.style.height = "auto"
      this.el.style.height = `${Math.max(this.el.scrollHeight, Number.parseFloat(getComputedStyle(this.el).minHeight) || 320)}px`
      if (window.scrollY !== scroll) window.scrollTo({top: scroll, behavior: "instant"})
      this.el.linkedEditor?.fit()
    }
    this.capture = (resize = true) => {
      const wasFailed = this.failed
      try {
        captureAfterArrival(localStorage, this.key, {...this.words(), baseToken: this.baseToken}, this.baseline, this.arrivalPending)
        this.arrivalPending = false
        this.failed = false
        if (wasFailed) this.pushEvent("file_recovery_available", {})
      }
      catch { this.problem() }
      this.flags()
      if (resize) this.fit()
      this.form.dispatchEvent(new Event("still:writing-display-changed"))
    }
    this.submitWriting = (read, scratch = false, unplaced = false) => {
      this.capture(); this.keepPosition()
      this.pushEvent("save_file", {writing: this.words(), draft_key: this.key, read, scratch, unplaced})
    }
    this.save = () => this.submitWriting(false)
    this.onFileAction = ({detail}) => {
      this.capture(); this.keepPosition()
      const placement = detail.action === "place" ? {
        section: document.getElementById("placement-section")?.value || "unplaced",
        list_label: document.getElementById("placement-list-label")?.value || "",
        allow_duplicate: document.getElementById("placement-allow-duplicate")?.checked || false,
      } : undefined
      this.pushEvent("save_file", {
        writing: this.words(), draft_key: this.key,
        file_action: detail.action,
        name: detail.action === "rename" ? document.getElementById("rename-menu-name")?.value : undefined,
        placement,
      })
    }
    this.newButton = [...document.querySelectorAll("#new-file")].find(button => button.form === this.form)
    this.saveButton = [...document.querySelectorAll("#save-file")].find(button => button.form === this.form)
    this.onNew = () => { this.capture(); this.keepPosition(); this.pushEvent("new_file", {writing: this.words()}) }
    this.newButton?.addEventListener("click", this.onNew)
    this.onSubmit = event => { event.preventDefault(); event.stopPropagation(); this.submitWriting(event.submitter?.id === "read-file", event.submitter?.id === "save-scratch", event.submitter?.id === "save-unplaced") }
    this.onKey = event => {
      if (event.target !== this.el && event.target?.form !== this.form) return
      const editor = event.target === this.el || this.el.linkedEditor?.owns(event.target) ? event.target : null
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault(); this.save()
      }
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault(); this.submitWriting(true)
      }
      if (editor && event.key === "Escape" && !document.querySelector("#room-close")) {
        event.preventDefault()
        const menuToggle = document.querySelector("#writing-menu-toggle")
        const focusTarget = menuToggle || this.saveButton
        focusTarget?.focus()
      }
      if (event.key === "Tab" && editor) {
        if (event.isComposing || this.composing || event.metaKey || event.ctrlKey || event.altKey) return
        event.preventDefault()
        const start = editor.selectionStart, end = editor.selectionEnd
        if (event.shiftKey) {
          const lineStart = editor.value.lastIndexOf("\n", start - 1) + 1
          const selected = editor.value.slice(lineStart, end)
          const changed = selected.split("\n").map(line => line.replace(/^(\t| {1,4})/, "")).join("\n")
          replaceSelection(editor, changed, lineStart, end, "select")
        } else replaceSelection(editor, "\t", start, end, "end")
      }
      if (editor && event.key === "Enter") {
        insertEnter(editor, event, {composing: this.composing})
      }
    }
    this.onCompositionStart = () => { this.composing = true }
    this.onCompositionEnd = () => { this.composing = false }
    this.onSaved = ({detail}) => {
      if (![detail.source_key, detail.target_key].includes(this.key)) return
      this.baseline = currentWords(detail)
      this.baseToken = detail.token
      this.key = detail.recovery_key
      this.failed = this.key !== detail.target_key
      this.capture()
      this.offer()
    }
    this.keepPosition = () => {
      if (this.leaving || !this.el.isConnected) return
      try { localStorage.setItem(positionKey(this.key), JSON.stringify({start: this.el.selectionStart,
        end: this.el.selectionEnd, direction: this.el.selectionDirection, scroll: window.scrollY})) }
      catch { /* Position is optional; words have their own verified recovery copy. */ }
    }
    this.onInput = event => {
      if (event.target !== this.el && event.target?.form !== this.form) return
      this.capture(event.target === this.el); this.keepPosition()
    }
    this.onPrepare = () => { this.capture(); this.keepPosition() }
    this.onNavigation = ({detail}) => {
      if (detail.kind === "redirect") { this.capture(); this.keepPosition(); this.leaving = true }
    }
    this.onLeavingClick = event => {
      const link = event.target.closest?.("a[href]")
      if (!link || link.target === "_blank" || link.getAttribute("href")?.startsWith("#")) return
      this.capture()
      this.keepPosition()
      if (shouldBlockNavigation(this.words(), this.baseline, !this.failed)) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.pushEvent("file_recovery_unavailable", {})
      }
    }
    this.onUnload = event => {
      this.capture()
      this.keepPosition()
      if (shouldBlockNavigation(this.words(), this.baseline, !this.failed)) {
        event.preventDefault()
        event.returnValue = ""
      }
    }
    window.addEventListener("click", this.onLeavingClick, true)
    window.addEventListener("beforeunload", this.onUnload)
    this.form.addEventListener("submit", this.onSubmit)
    document.addEventListener("input", this.onInput)
    document.addEventListener("keydown", this.onKey)
    this.form.addEventListener("compositionstart", this.onCompositionStart)
    this.form.addEventListener("compositionend", this.onCompositionEnd)
    window.addEventListener("still:save", this.save)
    this.el.addEventListener("still:file-action", this.onFileAction)
    window.addEventListener("still:prepare-to-leave", this.onPrepare)
    window.addEventListener("pagehide", this.onPrepare)
    window.addEventListener("resize", this.fit)
    window.addEventListener("still:file-saved", this.onSaved)
    this.el.addEventListener("select", this.keepPosition)
    this.el.addEventListener("keyup", this.keepPosition)
    window.addEventListener("scroll", this.keepPosition, {passive: true})
    window.addEventListener("phx:page-loading-start", this.onNavigation)
    this.handleEvent("letters-changed", () => requestAnimationFrame(() => { this.fit(); this.keepPosition() }))
    this.handleEvent("writing-width-changed", () => requestAnimationFrame(() => {
      const {selectionStart, selectionEnd, selectionDirection} = this.el
      this.capture(false)
      this.fit()
      this.el.setSelectionRange(selectionStart, selectionEnd, selectionDirection)
      this.keepPosition()
    }))
    this.handleEvent("file-restore-local", () => {
      if (!this.offered) return
      try {
        restoreCopy(localStorage, this.key, this.offered, this.words(), this.baseline)
        this.arrivalPending = false
        this.el.value = this.offered.body
        this.title.value = ""
        for (const field of fields) {
          const input = this.field(field)
          if (input) input.value = this.offered[field] ?? ""
        }
        this.capture()
        this.keepPosition()
        this.pushEvent("writing_changed", {writing: this.words()})
        this.offer()
        if (this.el.linkedEditor) this.el.linkedEditor.focus()
        else this.el.focus({preventScroll: true})
      } catch { this.problem() }
    })
    this.handleEvent("file-keep-saved", () => {
      if (!this.offered) return
      try {
        const bucket = readCopies(localStorage, this.key)
        writeCopies(localStorage, this.key, {
          active: equal(bucket.active, this.offered) ? null : bucket.active,
          held: bucket.held.filter(copy => !equal(copy, this.offered)),
        })
        this.offer()
      } catch { this.problem() }
    })
    try {
      const active = resumableCopy(localStorage, this.key, this.baseToken, this.el.dataset.resumeActive === "true")
      if (active) {
        this.el.value = active.body
        this.title.value = ""
        for (const field of fields) {
          const input = this.field(field)
          if (input) input.value = active[field] ?? ""
        }
        this.arrivalPending = false
        this.pushEvent("writing_changed", {writing: this.words()})
      }
    } catch { this.problem() }
    this.capture()
    this.offer()
    this.fit()
    if (this.el.autofocus) {
      this.el.focus({preventScroll: true})
      const end = this.el.value.length
      this.el.setSelectionRange(end, end)
      if (this.el.dataset.resumeActive === "true") {
        try {
          const position = JSON.parse(localStorage.getItem(positionKey(this.key)))
          if (position && Number.isInteger(position.start) && Number.isInteger(position.end)) {
            this.el.setSelectionRange(Math.min(end, Math.max(0, position.start)), Math.min(end, Math.max(0, position.end)), position.direction || "none")
            if (Number.isFinite(position.scroll)) requestAnimationFrame(() => window.scrollTo({top: position.scroll, behavior: "instant"}))
          }
        } catch { /* A missing position never replaces words. */ }
      }
      this.el.linkedEditor?.focus()
    }
  },
  updated() { this.fit() },
  destroyed() {
    window.removeEventListener("click", this.onLeavingClick, true)
    window.removeEventListener("beforeunload", this.onUnload)
    this.newButton?.removeEventListener("click", this.onNew)
    this.form.removeEventListener("submit", this.onSubmit)
    document.removeEventListener("input", this.onInput)
    document.removeEventListener("keydown", this.onKey)
    this.form.removeEventListener("compositionstart", this.onCompositionStart)
    this.form.removeEventListener("compositionend", this.onCompositionEnd)
    window.removeEventListener("still:save", this.save)
    this.el.removeEventListener("still:file-action", this.onFileAction)
    window.removeEventListener("still:prepare-to-leave", this.onPrepare)
    window.removeEventListener("pagehide", this.onPrepare)
    window.removeEventListener("resize", this.fit)
    window.removeEventListener("still:file-saved", this.onSaved)
    this.el.removeEventListener("select", this.keepPosition)
    this.el.removeEventListener("keyup", this.keepPosition)
    window.removeEventListener("scroll", this.keepPosition)
    window.removeEventListener("phx:page-loading-start", this.onNavigation)
  },
}

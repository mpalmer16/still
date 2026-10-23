import {FileRecovery} from "./file_recovery"
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/still"

const hasTitle = draft => Object.prototype.hasOwnProperty.call(draft, "title")
const normalizedTitle = title => typeof title === "string" && title.trim() !== "" ? title : null
// Old browser drafts contain only a body. An unspecified title must not erase a List's title.
const same = (draft, words) => Boolean(draft && typeof draft.body === "string" && draft.body === words?.body &&
  (!hasTitle(draft) || normalizedTitle(draft.title) === normalizedTitle(words.title)))
const identity = draft => JSON.stringify([draft.body, hasTitle(draft) ? normalizedTitle(draft.title) : {unspecified: true}])
const validDraft = draft => draft && typeof draft.body === "string"
const readJSON = key => {
  try { return JSON.parse(localStorage.getItem(key)) } catch { return null }
}
const putJSON = (key, value) => {
  try { localStorage.setItem(key, JSON.stringify(value)); return true } catch { return false }
}
const removeKey = key => {
  try { localStorage.removeItem(key) } catch { /* Saving continues without browser storage. */ }
}
const readDraft = key => {
  const draft = readJSON(key)
  return validDraft(draft) ? draft : null
}
const readHeld = key => {
  const drafts = readJSON(`${key}:held`)
  return Array.isArray(drafts) ? drafts.filter(validDraft) : []
}
const uniqueDrafts = drafts => [...new Map(drafts.map(draft => [identity(draft), draft])).values()]
const putHeld = (key, drafts) => {
  const copies = uniqueDrafts(drafts)
  if (copies.length === 0) { removeKey(`${key}:held`); return true }
  return putJSON(`${key}:held`, copies)
}
const holdDraft = (key, draft) => putHeld(key, [...readHeld(key), draft])
const pendingCopies = (key, persisted) => uniqueDrafts([readDraft(key), ...readHeld(key)].filter(validDraft))
  .filter(draft => !same(draft, persisted))
  .sort((a, b) => (b.at ?? 0) - (a.at ?? 0))
const discardCopy = (key, draft) => {
  const active = readDraft(key)
  if (active && identity(active) === identity(draft)) removeKey(key)
  putHeld(key, readHeld(key).filter(copy => identity(copy) !== identity(draft)))
}
const clearPersistedCopies = (key, persisted) => {
  if (same(readDraft(key), persisted)) removeKey(key)
  putHeld(key, readHeld(key).filter(copy => !same(copy, persisted)))
}

// A finish patch can destroy the editor before its acknowledgement arrives.
// Keep the acknowledgement outside the editor so new-page drafts still acquire their saved ID.
const draftAliases = new Map()
const storageKey = key => draftAliases.get(key) ?? key
window.addEventListener("phx:writing-saved", ({detail}) => {
  const target = `still:draft:${detail.id}`
  const source = storageKey(detail.draft_key ?? (detail.first ? "still:draft:new" : target))
  const persisted = {body: detail.body, title: detail.title}
  const active = uniqueDrafts([readDraft(source), ...(source === target ? [] : [readDraft(target)])].filter(validDraft))
    .filter(draft => !same(draft, persisted))
    .sort((a, b) => (b.at ?? 0) - (a.at ?? 0))
  const held = uniqueDrafts([...readHeld(source), ...(source === target ? [] : readHeld(target)), ...active.slice(1)])
    .filter(draft => !same(draft, persisted))
  const heldSaved = putHeld(target, held)
  const activeSaved = active.length ? putJSON(target, active[0]) : (removeKey(target), true)
  const migrated = heldSaved && activeSaved
  if (source !== target && migrated) {
    removeKey(source)
    removeKey(`${source}:held`)
  }
  if (migrated) draftAliases.delete(target)
  else if (source !== target) draftAliases.set(target, source)
  const positionSource = (detail.draft_key ?? source).replace("still:draft:", "still:position:")
  const positionTarget = `still:position:${detail.id}`
  const position = readJSON(positionSource)
  if (positionSource !== positionTarget && position && putJSON(positionTarget, position)) removeKey(positionSource)
  window.dispatchEvent(new CustomEvent("still:draft-acknowledged", {
    detail: {...detail, storage_key: storageKey(target)},
  }))
})

const scheduleRecoveryCheck = hook => {
  if (hook.checkScheduled) return
  hook.checkScheduled = true
  queueMicrotask(() => {
    hook.checkScheduled = false
    if (!hook.recoveryDestroyed) hook.checkRecovery()
  })
}

const DraftRecovery = {
  mounted() {
    this.form = this.el.form
    this.key = storageKey(this.el.dataset.entryId === "new"
      ? `still:draft:new${this.el.dataset.draftScope ? `:${this.el.dataset.draftScope}` : ""}`
      : `still:draft:${this.el.dataset.entryId}`)
    this.titleField = () => this.form?.querySelector("#writing-title")
    this.words = () => ({body: this.el.value, title: normalizedTitle(this.titleField()?.value)})
    this.persisted = this.words()
    this.showPending = () => { this.form.dataset.unsaved = String(!same(this.words(), this.persisted)) }
    this.showPending()
    this.positionKey = () => `still:position:${this.el.dataset.entryId}${this.el.dataset.entryId === "new" && this.el.dataset.draftScope ? `:${this.el.dataset.draftScope}` : ""}`
    this.keepPosition = () => {
      if (this.leavingPage || !this.el.isConnected) return
      putJSON(this.positionKey(), {
        start: this.el.selectionStart, end: this.el.selectionEnd,
        direction: this.el.selectionDirection, scroll: window.scrollY,
      })
    }
    this.onNavigation = ({detail}) => {
      if (detail.kind === "redirect") { this.keepPosition(); this.leavingPage = true }
    }
    clearPersistedCopies(this.key, this.persisted)
    const initial = readDraft(this.key)
    this.unresolved = initial && !same(initial, this.persisted) ? initial : null
    this.fit = () => {
      const scroll = window.scrollY
      this.el.style.height = "auto"
      const minimum = Number.parseFloat(getComputedStyle(this.el).minHeight) || 0
      this.el.style.height = `${Math.max(this.el.scrollHeight, minimum)}px`
      // Measuring a long page briefly shortens the document. Keep that
      // intermediate height from moving the writer during a save or resize.
      if (window.scrollY !== scroll) window.scrollTo({top: scroll, behavior: "instant"})
    }
    this.fit()
    if (this.el.autofocus) {
      this.el.focus({preventScroll: true})
      const end = this.el.value.length
      const position = readJSON(this.positionKey())
      if (position && Number.isInteger(position.start) && Number.isInteger(position.end)) {
        this.el.setSelectionRange(Math.min(end, Math.max(0, position.start)),
          Math.min(end, Math.max(0, position.end)), position.direction ?? "none")
        if (Number.isFinite(position.scroll)) requestAnimationFrame(() => window.scrollTo({top: position.scroll, behavior: "instant"}))
      } else this.el.setSelectionRange(end, end)
    }
    this.checkRecovery = () => {
      const waiting = this.unresolved || readHeld(this.key).find(draft => !same(draft, this.persisted))
      if (waiting && !this.notified) {
        this.notified = true
        this.pushEvent("recovery_found", {})
      } else if (!waiting) this.notified = false
    }
    scheduleRecoveryCheck(this)

    this.write = () => {
      const words = this.words()
      // Retain an unresolved arrival once; ordinary keystrokes do not create a history of drafts.
      if (this.unresolved && !same(this.unresolved, words)) {
        if (!holdDraft(this.key, this.unresolved)) return
        this.unresolved = null
      }
      putJSON(this.key, {...words, at: Date.now()})
    }
    const send = event => this.pushEvent(event, {entry: this.words()})
    this.onInput = () => { this.showPending(); this.write(); this.fit(); this.keepPosition() }
    this.onResize = () => this.fit()
    this.onLeaving = () => { this.keepPosition(); this.write(); send("save") }
    this.onSave = () => { this.keepPosition(); this.write(); send("save") }
    this.onKeydown = event => {
      if (event.key === "Escape" && !document.querySelector("#room-close")) {
        event.preventDefault()
        event.stopPropagation()
        ;(this.form.querySelector(".footer-actions button") ?? document.querySelector("#return-to-writing"))?.focus()
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault()
        this.keepPosition()
        this.write()
        send("save")
      }
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault()
        this.keepPosition()
        this.write()
        send("finish")
      }
      if (event.key === "Tab" && event.target === this.el) {
        event.preventDefault()
        const start = this.el.selectionStart
        const end = this.el.selectionEnd
        if (!event.shiftKey && start === end) this.el.setRangeText("\t", start, end, "end")
        else {
          const lineStart = this.el.value.lastIndexOf("\n", start - 1) + 1
          const selected = this.el.value.slice(lineStart, end)
          const changed = selected.split("\n").map(line => event.shiftKey
            ? line.replace(/^(\t| {1,4})/, "") : `\t${line}`).join("\n")
          this.el.setRangeText(changed, lineStart, end, "select")
        }
        this.el.dispatchEvent(new Event("input", {bubbles: true}))
      }
    }
    // The title may be removed or restored by a patch; delegate to the stable form.
    this.form.addEventListener("input", this.onInput)
    this.form.addEventListener("keydown", this.onKeydown)
    window.addEventListener("resize", this.onResize)
    window.addEventListener("still:prepare-to-leave", this.onLeaving)
    window.addEventListener("still:save", this.onSave)
    this.el.addEventListener("select", this.keepPosition)
    this.el.addEventListener("keyup", this.keepPosition)
    window.addEventListener("scroll", this.keepPosition, {passive: true})
    window.addEventListener("phx:page-loading-start", this.onNavigation)
    this.onAcknowledged = ({detail}) => {
      if (String(detail.id) !== this.el.dataset.entryId && detail.draft_key !== this.key) return
      const oldPositionKey = this.positionKey()
      const position = readJSON(oldPositionKey)
      this.key = detail.storage_key
      this.el.dataset.entryId = detail.id
      if (oldPositionKey !== this.positionKey() && position && putJSON(this.positionKey(), position)) removeKey(oldPositionKey)
      this.persisted = {body: detail.body, title: detail.title}
      this.showPending()
      if (this.unresolved && same(this.unresolved, this.persisted)) this.unresolved = null
      const pending = readDraft(this.key)
      if (pending && !same(pending, this.persisted) && !same(pending, this.words())) {
        this.unresolved = pending
      }
      this.notified = false
      scheduleRecoveryCheck(this)
    }
    window.addEventListener("still:draft-acknowledged", this.onAcknowledged)
    this.handleEvent("letters-changed", () => requestAnimationFrame(() => { this.fit(); this.keepPosition() }))

    this.handleEvent("restore-local", () => {
      const pending = pendingCopies(this.key, this.persisted)[0]
      if (!pending) return
      const current = readDraft(this.key)
      if (current && !same(current, this.persisted) && identity(current) !== identity(pending)) {
        if (!holdDraft(this.key, current)) return
      }
      putJSON(this.key, pending)
      this.el.value = pending.body
      const title = this.titleField()
      if (title && hasTitle(pending)) title.value = pending.title ?? ""
      this.showPending()
      this.unresolved = null
      this.fit()
      this.el.focus()
      send("save")
    })

    this.handleEvent("discard-recovery", () => {
      const pending = pendingCopies(this.key, this.persisted)[0]
      if (pending) discardCopy(this.key, pending)
      this.unresolved = null
      this.notified = false
      scheduleRecoveryCheck(this)
    })

    this.handleEvent("replace-writing", detail => {
      if (detail.id && String(detail.id) !== this.el.dataset.entryId) return
      const previous = {body: detail.previous_body, title: detail.previous_title}
      // A title interpretation must not replace keystrokes made while its
      // response was travelling back. Their browser copy remains recoverable.
      if (detail.only_if_current && !same(this.words(), previous)) {
        this.persisted = {body: detail.body, title: detail.title}
        this.unresolved = this.words()
        this.notified = false
        scheduleRecoveryCheck(this)
        return
      }
      clearPersistedCopies(this.key, previous)
      this.persisted = {body: detail.body, title: detail.title}
      clearPersistedCopies(this.key, this.persisted)
      const start = this.el.selectionStart
      const end = this.el.selectionEnd
      const offset = detail.only_if_current ? detail.previous_body.length - detail.body.length : 0
      this.el.value = detail.body
      const title = this.titleField()
      if (title) title.value = detail.title ?? ""
      this.showPending()
      const pending = readDraft(this.key)
      this.unresolved = pending && !same(pending, this.persisted) ? pending : null
      this.notified = false
      this.fit()
      if (detail.only_if_current) {
        this.el.setSelectionRange(Math.max(0, start - offset), Math.max(0, end - offset))
        this.el.focus({preventScroll: true})
        this.keepPosition()
      }
      scheduleRecoveryCheck(this)
    })
  },
  updated() { this.fit() },
  destroyed() {
    this.recoveryDestroyed = true
    this.form.removeEventListener("input", this.onInput)
    this.form.removeEventListener("keydown", this.onKeydown)
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("still:prepare-to-leave", this.onLeaving)
    window.removeEventListener("still:save", this.onSave)
    this.el.removeEventListener("select", this.keepPosition)
    this.el.removeEventListener("keyup", this.keepPosition)
    window.removeEventListener("scroll", this.keepPosition)
    window.removeEventListener("phx:page-loading-start", this.onNavigation)
    window.removeEventListener("still:draft-acknowledged", this.onAcknowledged)
  },
}

const ReadRecovery = {
  mounted() {
    this.key = storageKey(`still:draft:${this.el.dataset.entryId}`)
    this.words = () => {
      const body = this.el.querySelector("#list-body")
      const lines = body?.querySelectorAll("[data-authored-line]")
      return {
        body: lines?.length ? [...lines].map(line => line.textContent).join("\n") : body?.textContent ?? "",
        title: normalizedTitle(this.el.dataset.entryTitle),
      }
    }
    this.checkRecovery = () => {
      const persisted = this.words()
      clearPersistedCopies(this.key, persisted)
      const waiting = pendingCopies(this.key, persisted).length > 0
      if (waiting && !this.notified) {
        this.notified = true
        this.pushEvent("recovery_found", {})
      } else if (!waiting) this.notified = false
    }
    this.onAcknowledged = ({detail}) => {
      if (String(detail.id) !== this.el.dataset.entryId) return
      this.key = detail.storage_key
      this.notified = false
      scheduleRecoveryCheck(this)
    }
    window.addEventListener("still:draft-acknowledged", this.onAcknowledged)
    this.handleEvent("discard-recovery", () => {
      const pending = pendingCopies(this.key, this.words())[0]
      if (pending) discardCopy(this.key, pending)
      this.notified = false
      scheduleRecoveryCheck(this)
    })
    this.handleEvent("replace-writing", detail => {
      if (detail.id && String(detail.id) !== this.el.dataset.entryId) return
      clearPersistedCopies(this.key, {body: detail.previous_body, title: detail.previous_title})
      clearPersistedCopies(this.key, {body: detail.body, title: detail.title})
      this.notified = false
      scheduleRecoveryCheck(this)
    })
    scheduleRecoveryCheck(this)
  },
  updated() { scheduleRecoveryCheck(this) },
  destroyed() {
    this.recoveryDestroyed = true
    window.removeEventListener("still:draft-acknowledged", this.onAcknowledged)
  },
}

// Navigation shortcuts belong to the keyboard; the room itself is rendered by LiveView.
let roomFocusReturn = null
window.addEventListener("phx:room-focus", ({detail}) => {
  if (detail.id) {
    if (!roomFocusReturn?.isConnected) roomFocusReturn = document.activeElement
    requestAnimationFrame(() => document.getElementById(detail.id)?.focus({preventScroll: true}))
  } else if (roomFocusReturn?.isConnected) {
    const returning = roomFocusReturn
    requestAnimationFrame(() => returning.focus({preventScroll: true}))
    roomFocusReturn = null
  }
})
document.addEventListener("keydown", event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault()
    document.querySelector(".site-nav a[href='/pages']")?.click()
  }
  const field = event.target.closest?.("input, textarea, [contenteditable='true']")
  const roomIsOpen = document.querySelector("#room-close")
  const dialog = document.querySelector("#room-landscape")
  if (event.key === "Tab" && dialog) {
    const controls = [...dialog.querySelectorAll("a[href], button:not([disabled])")]
    const first = controls[0], last = controls.at(-1)
    if (event.shiftKey && (document.activeElement === first || !dialog.contains(document.activeElement))) {
      event.preventDefault(); last?.focus()
    } else if (!event.shiftKey && (document.activeElement === last || !dialog.contains(document.activeElement))) {
      event.preventDefault(); first?.focus()
    }
  }
  if (event.key === "Escape" && roomIsOpen) {
    event.preventDefault()
    roomIsOpen.click()
  } else if (event.key === "Escape" && !field && document.querySelector(".reading-room")) {
    event.preventDefault()
    document.querySelector("#return-to-writing")?.click()
  }
  if ((event.metaKey || event.ctrlKey) && event.shiftKey && event.key.toLowerCase() === "l") {
    event.preventDefault()
    document.querySelector("#light-toggle")?.click()
  }
  if (!field && event.altKey && ["ArrowLeft", "ArrowRight"].includes(event.key)) {
    if (roomIsOpen) { event.preventDefault(); return }
    const door = document.querySelector(event.shiftKey
      ? (event.key === "ArrowLeft" ? "#notebook-previous" : "#notebook-next")
      : (event.key === "ArrowLeft" ? "#move-near" : "#move-far"))
    if (door) { event.preventDefault(); door.click() }
  }
  if (!field && event.altKey && !event.metaKey && !event.ctrlKey && event.key === "ArrowUp") {
    const back = document.querySelector("#reading-back")
    if (back && !roomIsOpen) { event.preventDefault(); back.click() }
  }
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, DraftRecovery, ReadRecovery, FileRecovery},
})

liveSocket.connect()

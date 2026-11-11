const validCopy = copy => copy && typeof copy.body === "string"
const uniqueCopies = copies => [...new Map(copies.filter(validCopy).map(copy => [copy.body, copy])).values()]

export function readPacketNotesCopies(storage, key) {
  const raw = storage.getItem(key)
  if (raw === null) return {active: null, held: []}
  const bucket = JSON.parse(raw)
  if (!bucket || !(bucket.active === null || validCopy(bucket.active)) ||
      !Array.isArray(bucket.held) || !bucket.held.every(validCopy)) {
    throw new Error("Unreadable packet notes recovery copy")
  }
  return {active: bucket.active, held: bucket.held}
}

function writeCopies(storage, key, bucket) {
  if (!bucket.active && bucket.held.length === 0) {
    storage.removeItem(key)
    if (storage.getItem(key) !== null) throw new Error("Packet notes recovery removal was not confirmed")
  } else {
    const raw = JSON.stringify(bucket)
    storage.setItem(key, raw)
    if (storage.getItem(key) !== raw) throw new Error("Packet notes recovery write was not confirmed")
  }
}

export function capturePacketNotes(storage, key, body, persisted, ownedBody = null, token = null) {
  const bucket = readPacketNotesCopies(storage, key)
  const held = uniqueCopies([
    ...bucket.held,
    ...(bucket.active && bucket.active.body !== body && bucket.active.body !== persisted &&
      bucket.active.body !== ownedBody ? [bucket.active] : []),
  ]).filter(copy => copy.body !== persisted && copy.body !== body)
  const active = body === persisted ? null : {body, token, at: Date.now()}
  writeCopies(storage, key, {active, held})
  return active
}

export function acknowledgePacketNotes(storage, key, persisted, current, token) {
  const bucket = readPacketNotesCopies(storage, key)
  const held = uniqueCopies([
    ...bucket.held,
    ...(bucket.active ? [bucket.active] : []),
  ]).filter(copy => copy.body !== persisted && copy.body !== current)
  const active = current === persisted ? null : {body: current, token, at: Date.now()}
  writeCopies(storage, key, {active, held})
  return {active, held}
}

export const PacketNotes = {
  mounted() {
    this.wrapper = this.el.closest("[data-packet-notes]") || this.el.parentElement
    this.key = `still:packet-notes:${this.el.dataset.scope}:${this.el.dataset.packetId}`
    this.persisted = this.el.dataset.persisted ?? ""
    this.token = this.el.dataset.token || null
    this.ownedBody = null
    this.storageAvailable = true
    this.saving = false
    this.lastRestoredBody = null
    this.status = this.wrapper?.querySelector("[data-notes-status]")
    this.saveButton = this.wrapper?.querySelector("[data-notes-save]")
    this.restoreButton = this.wrapper?.querySelector("[data-notes-restore]")

    this.setStatus = message => { if (this.status) this.status.textContent = message }
    this.bucket = () => readPacketNotesCopies(localStorage, this.key)
    this.refreshRestore = () => {
      try {
        const bucket = this.bucket()
        const copies = [bucket.active, ...bucket.held].filter(copy => copy && copy.body !== this.persisted)
        if (this.restoreButton) {
          this.restoreButton.hidden = copies.length === 0
          this.restoreButton.disabled = copies.length === 0
          this.restoreButton.textContent = copies.length > 1 ? `Restore local notes (${copies.length})` : "Restore local notes"
        }
      } catch {
        this.markStorageUnavailable()
      }
    }
    this.markStorageUnavailable = () => {
      this.storageAvailable = false
      this.el.dataset.recoverySafe = "false"
      this.el.dataset.unsaved = String(this.el.value !== this.persisted)
      this.setStatus("Local recovery is unavailable. Save your notes before leaving.")
    }
    this.updateFlags = () => {
      this.el.dataset.unsaved = String(this.el.value !== this.persisted)
      this.el.dataset.recoverySafe = String(this.storageAvailable)
    }
    this.capture = () => {
      try {
        this.ownedBody = capturePacketNotes(
          localStorage, this.key, this.el.value, this.persisted, this.ownedBody, this.token,
        )?.body ?? null
        this.storageAvailable = true
        this.refreshRestore()
        this.updateFlags()
        return true
      } catch {
        this.markStorageUnavailable()
        return false
      }
    }
    this.save = () => {
      if (this.saving) return
      this.capture()
      const body = this.el.value
      const token = this.token
      this.saving = true
      if (this.saveButton) this.saveButton.disabled = true
      this.setStatus("Saving notes…")
      this.pushEvent("save_packet_notes", {id: this.el.dataset.packetId, body, token}, reply => {
        this.saving = false
        if (this.saveButton) this.saveButton.disabled = false
        if (!reply || reply.ok !== true) {
          this.setStatus(reply?.error || "Could not save these notes. Your local copy is retained.")
          this.capture()
          return
        }

        this.persisted = typeof reply.body === "string" ? reply.body : body
        this.token = reply.token ?? null
        this.el.dataset.persisted = this.persisted
        this.el.dataset.token = this.token || ""
        try {
          acknowledgePacketNotes(localStorage, this.key, this.persisted, this.el.value, this.token)
          this.ownedBody = this.el.value === this.persisted ? null : this.el.value
          this.storageAvailable = true
          this.updateFlags()
          this.setStatus(this.el.value === this.persisted ? "Notes saved." : "Saved. Newer typing is still unsaved.")
        } catch {
          this.markStorageUnavailable()
        }
        this.refreshRestore()
      })
    }
    this.restore = () => {
      try {
        const bucket = this.bucket()
        const copies = uniqueCopies([bucket.active, ...bucket.held])
          .filter(item => item && item.body !== this.persisted)
        const copy = copies.find(item => item.body !== this.lastRestoredBody) || copies[0]
        if (!copy) return
        const current = this.el.value
        const held = uniqueCopies([
          ...bucket.held,
          ...(current !== this.persisted && current !== copy.body ? [{body: current, token: this.token, at: Date.now()}] : []),
          ...(bucket.active && bucket.active.body !== copy.body ? [bucket.active] : []),
        ]).filter(item => item.body !== this.persisted && item.body !== copy.body)
        writeCopies(localStorage, this.key, {active: copy, held})
        this.el.value = copy.body
        this.ownedBody = copy.body
        this.lastRestoredBody = copy.body
        this.refreshRestore()
        this.setStatus("Local notes restored. Save to keep them in the collection.")
        this.el.dispatchEvent(new Event("input", {bubbles: true}))
      } catch {
        this.markStorageUnavailable()
      }
    }
    this.onInput = () => {
      const recoverable = this.capture()
      if (!recoverable) return
      if (this.el.value !== this.persisted) this.setStatus("Unsaved notes. They are stored locally.")
      else this.setStatus("")
    }
    this.onKey = event => {
      if (event.target !== this.el) return
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault()
        event.stopPropagation()
        this.save()
      }
    }
    this.onUnload = event => {
      const recoverable = this.capture()
      if (this.el.value !== this.persisted && (!recoverable || !this.storageAvailable)) {
        event.preventDefault()
        event.returnValue = ""
      }
    }
    this.onPrepare = () => this.capture()
    this.onNativeSave = () => {
      this.save()
    }
    this.onLeavingClick = event => {
      const link = event.target.closest?.("a[href]")
      if (!link || link.target === "_blank" || link.getAttribute("href")?.startsWith("#")) return
      const recoverable = this.capture()
      if (this.el.value !== this.persisted && !recoverable) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }
    this.onSaveClick = () => this.save()
    this.onRestoreClick = () => this.restore()

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKey)
    window.addEventListener("beforeunload", this.onUnload)
    window.addEventListener("click", this.onLeavingClick, true)
    window.addEventListener("pagehide", this.onPrepare)
    window.addEventListener("still:prepare-to-leave", this.onPrepare)
    window.addEventListener("still:save", this.onNativeSave)
    this.saveButton?.addEventListener("click", this.onSaveClick)
    this.restoreButton?.addEventListener("click", this.onRestoreClick)
    this.capture()
    this.refreshRestore()
  },

  destroyed() {
    this.onPrepare?.()
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKey)
    window.removeEventListener("beforeunload", this.onUnload)
    window.removeEventListener("click", this.onLeavingClick, true)
    window.removeEventListener("pagehide", this.onPrepare)
    window.removeEventListener("still:prepare-to-leave", this.onPrepare)
    window.removeEventListener("still:save", this.onNativeSave)
    this.saveButton?.removeEventListener("click", this.onSaveClick)
    this.restoreButton?.removeEventListener("click", this.onRestoreClick)
  },
}

const equal = (a, b) => a?.body === b?.body && a?.title === b?.title
const valid = value => value && typeof value.body === "string" && typeof value.title === "string"
const unique = copies => [...new Map(copies.map(copy => [JSON.stringify([copy.body, copy.title]), copy])).values()]

export function readCopies(storage, key) {
  const raw = storage.getItem(key)
  if (raw === null) return {active: null, held: []}
  const bucket = JSON.parse(raw)
  if (!bucket || !(bucket.active === null || valid(bucket.active)) ||
      !Array.isArray(bucket.held) || !bucket.held.every(valid)) throw new Error("Unreadable poem recovery copy")
  return bucket
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

if (typeof window !== "undefined") {
  window.addEventListener("phx:poem-saved", ({detail}) => {
    let recoveryKey = detail.target_key
    try { acknowledgeCopies(localStorage, detail.source_key, detail.target_key, detail) }
    catch { recoveryKey = detail.source_key }
    window.dispatchEvent(new CustomEvent("still:poem-saved", {detail: {...detail, recovery_key: recoveryKey}}))
  })
}

export const shouldBlockNavigation = (current, baseline, recoverySafe) => !recoverySafe && !equal(current, baseline)

export const PoemRecovery = {
  mounted() {
    this.form = this.el.form
    this.title = this.form.querySelector("#poem-title")
    this.key = this.el.dataset.draftKey
    this.baseline = JSON.parse(this.el.dataset.persisted)
    this.baseline.title ??= ""
    this.failed = false
    this.arrivalPending = true
    this.words = () => {
      const body = this.el.value
      // A textarea normalizes CRLF on display; a title-only edit must retain the original bytes.
      return {body: body === this.baseline.body.replace(/\r\n?/g, "\n") ? this.baseline.body : body, title: this.title.value}
    }
    this.flags = () => {
      const dirty = !equal(this.words(), this.baseline)
      this.form.dataset.unsaved = String(dirty)
      this.form.dataset.recoverySafe = String(!this.failed)
      this.form.dataset.poemDraftKey = this.key
    }
    this.problem = () => {
      this.failed = true
      this.flags()
      this.pushEvent("poem_recovery_unavailable", {})
    }
    this.pending = () => {
      const bucket = readCopies(localStorage, this.key)
      return unique([bucket.active, ...bucket.held].filter(Boolean)).filter(copy => !equal(copy, this.baseline))
        .sort((a, b) => (b.at || 0) - (a.at || 0))
    }
    this.offer = () => {
      try {
        this.offered = this.pending().find(copy => !equal(copy, this.words()))
        this.pushEvent("poem_recovery_status", {waiting: Boolean(this.offered)})
      } catch { this.problem() }
    }
    this.fit = () => {
      const scroll = window.scrollY
      this.el.style.height = "auto"
      this.el.style.height = `${Math.max(this.el.scrollHeight, 320)}px`
      if (window.scrollY !== scroll) window.scrollTo({top: scroll, behavior: "instant"})
    }
    this.capture = () => {
      const wasFailed = this.failed
      try {
        captureAfterArrival(localStorage, this.key, this.words(), this.baseline, this.arrivalPending)
        this.arrivalPending = false
        this.failed = false
        if (wasFailed) this.pushEvent("poem_recovery_available", {})
      }
      catch { this.problem() }
      this.flags()
      this.fit()
    }
    this.save = () => {
      this.capture()
      this.pushEvent("save_poem", {poem: this.words(), draft_key: this.key})
    }
    this.onSubmit = event => { event.preventDefault(); event.stopPropagation(); this.save() }
    this.onKey = event => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault(); this.save()
      }
      if (event.key === "Escape") { event.preventDefault(); this.form.querySelector("#save-poem")?.focus() }
      if (event.key === "Tab" && event.target === this.el) {
        event.preventDefault()
        const start = this.el.selectionStart, end = this.el.selectionEnd
        if (event.shiftKey) {
          const lineStart = this.el.value.lastIndexOf("\n", start - 1) + 1
          const selected = this.el.value.slice(lineStart, end)
          this.el.setRangeText(selected.split("\n").map(line => line.replace(/^(\t| {1,4})/, "")).join("\n"), lineStart, end, "select")
        } else this.el.setRangeText("\t", start, end, "end")
        this.el.dispatchEvent(new Event("input", {bubbles: true}))
      }
    }
    this.onSaved = ({detail}) => {
      if (![detail.source_key, detail.target_key].includes(this.key)) return
      this.baseline = {body: detail.body, title: detail.title ?? ""}
      this.key = detail.recovery_key
      this.failed = this.key !== detail.target_key
      this.capture()
      this.offer()
    }
    this.onLeavingClick = event => {
      const link = event.target.closest?.("a[href]")
      if (!link || link.target === "_blank" || link.getAttribute("href")?.startsWith("#")) return
      this.capture()
      if (shouldBlockNavigation(this.words(), this.baseline, !this.failed)) {
        event.preventDefault()
        event.stopImmediatePropagation()
        this.pushEvent("poem_recovery_unavailable", {})
      }
    }
    this.onUnload = event => {
      this.capture()
      if (shouldBlockNavigation(this.words(), this.baseline, !this.failed)) {
        event.preventDefault()
        event.returnValue = ""
      }
    }
    window.addEventListener("click", this.onLeavingClick, true)
    window.addEventListener("beforeunload", this.onUnload)
    this.form.addEventListener("input", this.capture)
    this.form.addEventListener("submit", this.onSubmit)
    this.form.addEventListener("keydown", this.onKey)
    window.addEventListener("still:save", this.save)
    window.addEventListener("still:prepare-to-leave", this.capture)
    window.addEventListener("pagehide", this.capture)
    window.addEventListener("resize", this.fit)
    window.addEventListener("still:poem-saved", this.onSaved)
    this.handleEvent("poem-restore-local", () => {
      if (!this.offered) return
      try {
        restoreCopy(localStorage, this.key, this.offered, this.words(), this.baseline)
        this.arrivalPending = false
        this.el.value = this.offered.body
        this.title.value = this.offered.title
        this.capture()
        this.pushEvent("poem_changed", {poem: this.words()})
        this.offer()
        this.el.focus({preventScroll: true})
      } catch { this.problem() }
    })
    this.handleEvent("poem-keep-saved", () => {
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
    this.capture()
    this.offer()
    this.fit()
    if (this.el.autofocus) this.el.focus({preventScroll: true})
  },
  updated() { this.fit() },
  destroyed() {
    window.removeEventListener("click", this.onLeavingClick, true)
    window.removeEventListener("beforeunload", this.onUnload)
    this.form.removeEventListener("input", this.capture)
    this.form.removeEventListener("submit", this.onSubmit)
    this.form.removeEventListener("keydown", this.onKey)
    window.removeEventListener("still:save", this.save)
    window.removeEventListener("still:prepare-to-leave", this.capture)
    window.removeEventListener("pagehide", this.capture)
    window.removeEventListener("resize", this.fit)
    window.removeEventListener("still:poem-saved", this.onSaved)
  },
}

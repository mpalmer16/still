import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'

const source = await readFile(new URL('../assets/js/packet_notes.js', import.meta.url), 'utf8')
const {PacketNotes, readPacketNotesCopies, capturePacketNotes} = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`,
)

const memory = () => {
  const values = new Map()
  return {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: key => values.delete(key),
  }
}

class Target extends EventTarget {
  constructor() { super(); this.hidden = false; this.disabled = false; this.textContent = ''; this.value = '' }
  click() { this.dispatchEvent(new Event('click')) }
}

const setup = ({body = 'Saved notes', store = memory(), persist = true} = {}) => {
  const oldStorage = globalThis.localStorage
  const oldWindow = globalThis.window
  const win = new EventTarget()
  globalThis.localStorage = store
  globalThis.window = win
  const textarea = new Target()
  textarea.value = body
  textarea.dataset = {scope: 'collection-a', packetId: 'packet-1', persisted: 'Saved notes', token: 'token-1'}
  const status = new Target()
  const save = new Target()
  const restore = new Target()
  const wrapper = {querySelector: selector => ({'[data-notes-status]': status, '[data-notes-save]': save, '[data-notes-restore]': restore}[selector])}
  textarea.closest = () => wrapper
  const sent = []
  const context = {
    el: textarea,
    pushEvent: (name, payload, callback) => sent.push({name, payload, callback}),
  }
  PacketNotes.mounted.call(context)
  return {
    context, textarea, status, save, restore, sent, store, win,
    cleanup() {
      PacketNotes.destroyed.call(context)
      if (oldStorage === undefined) delete globalThis.localStorage
      else globalThis.localStorage = oldStorage
      if (oldWindow === undefined) delete globalThis.window
      else globalThis.window = oldWindow
    },
  }
}

const input = textarea => textarea.dispatchEvent(new Event('input', {bubbles: true}))

test('each keystroke stores exact whitespace under the packet and collection key', () => {
  const app = setup()
  try {
    app.textarea.value = '\tDraft\r\n\r\n  last line  '
    input(app.textarea)
    const copy = readPacketNotesCopies(app.store, 'still:packet-notes:collection-a:packet-1').active
    assert.equal(copy.body, '\tDraft\r\n\r\n  last line  ')
    assert.equal(app.status.textContent, 'Unsaved notes. They are stored locally.')
  } finally { app.cleanup() }
})

test('an acknowledgment keeps newer typing in the editor and in local recovery', () => {
  const app = setup()
  try {
    app.textarea.value = 'Submitted version'
    input(app.textarea)
    app.save.click()
    assert.equal(app.sent[0].name, 'save_packet_notes')
    assert.deepEqual(app.sent[0].payload, {id: 'packet-1', body: 'Submitted version', token: 'token-1'})

    app.textarea.value = 'Submitted version\nnewer typing'
    input(app.textarea)
    app.sent[0].callback({ok: true, body: 'Submitted version', token: 'token-2'})

    assert.equal(app.textarea.value, 'Submitted version\nnewer typing')
    assert.equal(app.context.persisted, 'Submitted version')
    assert.equal(app.context.token, 'token-2')
    assert.equal(readPacketNotesCopies(app.store, 'still:packet-notes:collection-a:packet-1').active.body,
      'Submitted version\nnewer typing')
    assert.equal(app.status.textContent, 'Saved. Newer typing is still unsaved.')
  } finally { app.cleanup() }
})

test('stale save responses keep the recovery copy and display the server error', () => {
  const app = setup()
  try {
    app.textarea.value = 'Local draft'
    input(app.textarea)
    app.save.click()
    app.sent[0].callback({error: 'These notes changed on disk. Reopen them before continuing.'})
    assert.equal(app.textarea.value, 'Local draft')
    assert.equal(readPacketNotesCopies(app.store, 'still:packet-notes:collection-a:packet-1').active.body, 'Local draft')
    assert.match(app.status.textContent, /changed on disk/)
  } finally { app.cleanup() }
})

test('restoration is explicit and keeps copies that arrive while the writer types', () => {
  const store = memory()
  const key = 'still:packet-notes:collection-a:packet-1'
  capturePacketNotes(store, key, 'Recovered older notes', 'Saved notes')
  const app = setup({store})
  try {
    assert.equal(app.textarea.value, 'Saved notes')
    assert.equal(app.restore.hidden, false)
    app.textarea.value = 'New notes typed after arrival'
    input(app.textarea)
    let bucket = readPacketNotesCopies(store, key)
    assert.equal(bucket.active.body, 'New notes typed after arrival')
    assert.ok(bucket.held.some(copy => copy.body === 'Recovered older notes'))

    app.restore.click()
    app.restore.click()
    assert.equal(app.textarea.value, 'Recovered older notes')
    bucket = readPacketNotesCopies(store, key)
    assert.ok(bucket.held.some(copy => copy.body === 'New notes typed after arrival'))
  } finally { app.cleanup() }
})

test('restore accepts a bucket with held copies and no active copy', () => {
  const store = memory()
  store.setItem('still:packet-notes:collection-a:packet-1', JSON.stringify({
    active: null, held: [{body: 'Held local notes', token: 'token-old'}],
  }))
  const app = setup({store})
  try {
    app.restore.click()
    assert.equal(app.textarea.value, 'Held local notes')
  } finally { app.cleanup() }
})

test('a dropped localStorage write stays visibly unsafe instead of claiming local recovery', () => {
  const store = memory()
  const app = setup({store})
  try {
    store.setItem = () => {}
    app.textarea.value = 'Unsaved notes'
    input(app.textarea)
    assert.equal(app.textarea.dataset.unsaved, 'true')
    assert.equal(app.textarea.dataset.recoverySafe, 'false')
    assert.match(app.status.textContent, /recovery is unavailable/)

    const unsafe = new Event('beforeunload', {cancelable: true})
    app.win.dispatchEvent(unsafe)
    assert.equal(unsafe.defaultPrevented, true)
  } finally { app.cleanup() }
})

test('native Save saves notes and prepare-to-leave refreshes native leave flags', () => {
  const app = setup()
  try {
    app.textarea.value = 'Current notes'
    input(app.textarea)
    assert.equal(app.textarea.dataset.unsaved, 'true')
    assert.equal(app.textarea.dataset.recoverySafe, 'true')
    app.win.dispatchEvent(new Event('still:save'))
    assert.equal(app.sent.length, 1)
    assert.equal(app.sent[0].name, 'save_packet_notes')
    app.sent[0].callback({ok: true, body: 'Current notes', token: 'token-2'})
    assert.equal(app.textarea.dataset.unsaved, 'false')
    app.win.dispatchEvent(new Event('still:prepare-to-leave'))
    assert.equal(app.textarea.dataset.recoverySafe, 'true')
  } finally { app.cleanup() }
})

test('beforeunload warns only when changed notes cannot be recovered locally', () => {
  const app = setup()
  try {
    app.textarea.value = 'Unsaved but recovered'
    input(app.textarea)
    const safelyRecovered = new Event('beforeunload', {cancelable: true})
    app.win.dispatchEvent(safelyRecovered)
    assert.equal(safelyRecovered.defaultPrevented, false)

    app.store.setItem = () => { throw new Error('storage unavailable') }
    const unsafe = new Event('beforeunload', {cancelable: true})
    app.win.dispatchEvent(unsafe)
    assert.equal(unsafe.defaultPrevented, true)
  } finally { app.cleanup() }
})

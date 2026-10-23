import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'
const source = await readFile(new URL('../assets/js/writing_focus.js', import.meta.url), 'utf8')
const {writingFocus, automaticWritingTitle} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
class Surface {
  handlers = new Map()
  addEventListener(name, fn) { this.handlers.set(name, fn) }
  removeEventListener(name, fn) { if (this.handlers.get(name) === fn) this.handlers.delete(name) }
  fire(name, event = {}) { this.handlers.get(name)?.(event) }
}
function room() {
  const page = new Surface(), doc = new Surface(), clock = new Surface(), body = {value: '  words\n\n', selectionStart: 4}
  let quiet = false, pending
  const title = {value: ""}
  page.querySelector = selector => selector === "#file-writing-body" ? body : title
  doc.activeElement = body
  doc.documentElement = {setAttribute() { quiet = true }, removeAttribute() { quiet = false }}
  clock.setTimeout = fn => { pending = fn; return 1 }
  clock.clearTimeout = () => { pending = null }
  const focus = writingFocus(page, doc, clock)
  return {page, doc, clock, body, title, focus, quiet: () => quiet, tick: () => { const fn = pending; pending = null; fn?.() }, type() {page.fire('input', {target: body})}}
}
test('only body typing fades controls; words and caret are untouched', () => {
  const r = room()
  r.page.fire('input', {target: {}}); r.tick(); assert.equal(r.quiet(), false)
  r.type(); assert.equal(r.quiet(), false); r.tick(); assert.equal(r.quiet(), true)
  assert.equal(r.body.value, '  words\n\n'); assert.equal(r.body.selectionStart, 4)
  r.focus.destroy()
})
test('pointer movement, keyboard navigation, control focus and save reveal controls', () => {
  const r = room()
  for (const [surface, event, detail] of [[r.doc,'pointermove',{}], [r.doc,'keydown',{key:'Escape'}], [r.doc,'keydown',{key:'Tab'}], [r.doc,'focusin',{target:{}}], [r.clock,'still:file-saved',{}]]) {
    r.type(); r.tick(); assert.equal(r.quiet(), true)
    surface.fire(event, detail); assert.equal(r.quiet(), false)
    r.tick(); assert.equal(r.quiet(), false)
  }
  r.focus.destroy()
})
test('disconnect and navigation cancel pending fades; destroy removes all listeners', () => {
  const r = room()
  r.type(); r.focus.disconnect(); r.tick(); assert.equal(r.quiet(), false)
  r.type(); r.tick(); assert.equal(r.quiet(), false)
  r.focus.reconnect(); r.type(); r.clock.fire('phx:page-loading-start'); r.tick(); assert.equal(r.quiet(), false)
  r.type(); r.focus.destroy(); r.tick(); assert.equal(r.quiet(), false)
  for (const surface of [r.page,r.doc,r.clock]) assert.equal(surface.handlers.size, 0)
})

test('automatic title hint follows the first line without filling in an explicit title or changing text', () => {
  const r = room()
  assert.equal(r.title.placeholder, 'words')
  r.body.value = '\n  A different opening  \r\nrest'
  r.page.fire('still:writing-display-changed')
  assert.equal(r.title.placeholder, 'A different opening')
  assert.equal(r.title.value, '')
  assert.equal(r.body.value, '\n  A different opening  \r\nrest')
  assert.equal(automaticWritingTitle('é'.repeat(61)), 'é'.repeat(59)+'…')
  r.body.value = ''; r.type()
  assert.equal(r.title.placeholder, 'A title, if you like.')
  r.focus.destroy()
})

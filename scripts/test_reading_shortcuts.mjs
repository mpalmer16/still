import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'
const source = await readFile(new URL('../assets/js/reading_shortcuts.js', import.meta.url), 'utf8')
const {handleReadingShortcut, openPieceFind} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
const key = (value, options = {}) => ({key: value, ...options, prevented: false, preventDefault() { this.prevented = true }})
const control = () => ({clicks: 0, click() { this.clicks++ }, closest() { return null }})
test('Command-F and Control-F open only the local piece search', () => {
  for (const modifier of ['metaKey', 'ctrlKey']) {
    const open = control(), home = control()
    const root = {querySelector: selector => selector === '#open-piece-find' ? open : null}
    const event = key('f', {[modifier]: true})
    assert.equal(handleReadingShortcut(event, root), true)
    assert.equal(event.prevented, true)
    assert.equal(open.clicks, 1)
    assert.equal(home.clicks, 0)
  }
})
test('Escape closes local search once and repeated Escape never leaves reading', () => {
  const close = control(), home = control()
  let opened = true
  const root = {querySelector: selector => selector === '#close-piece-find' ? (opened ? close : null) : home}
  assert.equal(handleReadingShortcut(key('Escape'), root), true)
  opened = false
  for (let i = 0; i < 5; i++) assert.equal(handleReadingShortcut(key('Escape'), root), false)
  assert.equal(close.clicks, 1)
  assert.equal(home.clicks, 0)
})
test('hidden room controls and other pages are left alone', () => {
  const button = control()
  button.closest = () => ({inert: true})
  assert.equal(openPieceFind({querySelector: () => button}), false)
  const event = key('f', {metaKey: true})
  assert.equal(handleReadingShortcut(event, {querySelector: () => null}), false)
  assert.equal(event.prevented, false)
})

test('Command-F returns focus to an already open piece search', () => {
  const query = control()
  query.focus = () => { query.focused = true }
  const event = key('f', {metaKey: true})
  assert.equal(handleReadingShortcut(event, {querySelector: selector => selector === '#piece-find-query' ? query : null}), true)
  assert.equal(query.focused, true)
  assert.equal(event.prevented, true)
})

test('Backspace cannot navigate away from a reader, but remains available while editing', () => {
  const reader = {}
  const root = {querySelector: selector => selector.includes(".reading-room") || selector.includes("#notebook-content") ? reader : null}
  const plain = key('Backspace', {target: {closest: () => null}})
  assert.equal(handleReadingShortcut(plain, root), true)
  assert.equal(plain.prevented, true)

  for (const selector of ['input', 'textarea', "[contenteditable='']", "[contenteditable='true']"]) {
    const field = key('Backspace', {target: {closest: value => value.includes(selector) ? {} : null}})
    assert.equal(handleReadingShortcut(field, root), false)
    assert.equal(field.prevented, false)
  }
  const composing = key('Backspace', {isComposing: true, target: {closest: () => null}})
  assert.equal(handleReadingShortcut(composing, root), false)
  assert.equal(composing.prevented, false)
  const outside = key('Backspace', {target: {closest: () => null}})
  assert.equal(handleReadingShortcut(outside, {querySelector: () => null}), false)
  assert.equal(outside.prevented, false)
})

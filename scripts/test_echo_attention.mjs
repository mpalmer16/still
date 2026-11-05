import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'
const source = await readFile(new URL('../assets/js/echo_attention.js', import.meta.url), 'utf8')
const {echoAttention, passageAttention} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

function surface() {
  const listeners = new Map(), sent = []
  let next = 0, id = 'one'
  const timers = new Map()
  const el = {value: '🌒 first\n\n  second  \n', selectionStart: 3, selectionEnd: 3, isConnected: true,
    addEventListener(name, fn) { listeners.set(name, fn) },
    removeEventListener(name, fn) { if (listeners.get(name) === fn) listeners.delete(name) }}
  const doc = {activeElement: el}
  const clock = {setTimeout(fn) {timers.set(++next, fn); return next}, clearTimeout(key) {timers.delete(key)}}
  const attention = echoAttention(el, payload => sent.push(payload), {documentId: () => id, doc, clock})
  return {el, doc, attention, sent, listeners, timers,
    fire(name) { listeners.get(name)?.() },
    tick() { const ready = [...timers.values()]; timers.clear(); ready.forEach(fn => fn()) },
    setId(value) {id = value},
  }
}

test('reports exact UTF-16 caret positions after a pause without changing words or position', () => {
  const r = surface(), body = r.el.value
  r.tick()
  assert.deepEqual(r.sent, [{id: 'one', body, start: 3, end: 3}])
  r.el.selectionStart = 12; r.el.selectionEnd = 18
  r.fire('select'); r.fire('keyup'); r.tick()
  assert.deepEqual(r.sent[1], {id: 'one', body, start: 12, end: 18})
  assert.equal(r.el.value, body)
  assert.equal(r.el.selectionStart, 12)
  assert.equal(r.el.selectionEnd, 18)
  r.attention.destroy()
})

test('deduplicates patches and follows changing text and the current document identity', () => {
  const r = surface(); r.tick()
  r.fire('select'); r.attention.schedule(); r.tick()
  assert.equal(r.sent.length, 1)
  r.el.value += 'a new line'; r.fire('input'); r.tick()
  assert.equal(r.sent.length, 2)
  r.setId('saved-one'); r.attention.schedule(); r.tick()
  assert.equal(r.sent[2].id, 'saved-one')
  r.attention.destroy()
})

test('waits for composition and cancels disconnected, unfocused, and destroyed callbacks', () => {
  const r = surface()
  r.fire('compositionstart'); r.fire('input'); r.tick(); assert.equal(r.sent.length, 0)
  r.fire('compositionend'); r.tick(); assert.equal(r.sent.length, 1)
  r.el.selectionStart = 5; r.fire('keyup'); r.attention.disconnect(); r.tick()
  assert.equal(r.sent.length, 1)
  r.attention.reconnect(); r.tick(); assert.equal(r.sent.length, 2)
  r.doc.activeElement = {}; r.el.selectionEnd = 9; r.fire('select'); r.tick()
  assert.equal(r.sent.length, 2)
  r.doc.activeElement = r.el; r.fire('focus'); r.attention.destroy(); r.tick()
  assert.equal(r.sent.length, 2)
  assert.equal(r.listeners.size, 0)
  assert.equal(r.timers.size, 0)
})

function readingSurface() {
  const sent = [], listeners = new Map(), timers = new Map()
  let selected = null, next = 0
  const stanza = line => {
    const node = {dataset: {echoLine: line}, closest: () => node}
    return node
  }
  const first = stanza('1'), second = stanza('3')
  const child = {closest: () => first}
  const el = {
    dataset: {echoDocument: 'page'},
    contains: node => [first, second, child].includes(node),
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name),
  }
  const doc = {getSelection: () => selected, addEventListener() {}, removeEventListener() {}}
  const clock = {
    setTimeout(fn, delay) { timers.set(++next, {fn, delay}); return next },
    clearTimeout: key => timers.delete(key),
  }
  const attention = passageAttention(el, payload => sent.push(payload), {doc, clock})
  return {first, second, child, sent, timers, attention,
    fire(name, target, relatedTarget = null) {
      listeners.get(name)?.({target, relatedTarget, pointerType: 'mouse'})
    },
    select(anchorNode, focusNode) { selected = {isCollapsed: false, anchorNode, focusNode} },
    tick() { const ready = [...timers.values()]; timers.clear(); ready.forEach(({fn}) => fn()) },
  }
}

test('reading sends one passage after a settled hover and ignores movement within it', () => {
  const r = readingSurface()
  r.fire('pointerover', r.first)
  assert.deepEqual([...r.timers.values()].map(timer => timer.delay), [450])
  r.fire('pointerout', r.first, r.second)
  r.fire('pointerover', r.second, r.first)
  r.fire('pointerout', r.second)
  r.tick()
  assert.deepEqual(r.sent, [])

  r.fire('pointerover', r.first)
  r.fire('pointerover', r.child, r.first)
  assert.equal(r.timers.size, 1)
  r.tick()
  r.fire('pointerover', r.first)
  r.tick()
  assert.deepEqual(r.sent, [{id: 'page', line: '1'}])
  r.attention.destroy()
})

test('reading selection takes precedence and disconnect cancels pending attention', () => {
  const r = readingSurface()
  r.fire('pointerdown', r.first)
  r.select(r.first, r.second)
  r.fire('pointerup', r.first)
  r.fire('pointerout', r.first)
  r.tick()
  r.fire('pointerover', r.first)
  r.tick()
  assert.deepEqual(r.sent, [{id: 'page', line: '3'}])
  r.fire('focusin', r.first)
  r.attention.disconnect()
  r.tick()
  assert.equal(r.sent.length, 1)
  r.attention.destroy()
})

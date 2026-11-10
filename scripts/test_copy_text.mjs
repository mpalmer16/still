import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'

const source = await readFile(new URL('../assets/js/copy_text.js', import.meta.url), 'utf8')
const linked = await readFile(new URL('../assets/js/linked_writing.js', import.meta.url), 'utf8')
const combined = source.replace('import {expandedCopy} from "./linked_writing"', '') + '\n' + linked.replace(/^export /gm, '')
const {copyPayload, CopyText} = await import(`data:text/javascript;base64,${Buffer.from(combined).toString('base64')}`)

test('copies an explicit title followed by a blank line and the exact body', () => {
  assert.equal(copyPayload({body:'  line\n\nlast\n', title:'A title', title_source:'explicit'}), 'A title\n\n  line\n\nlast\n')
})

test('does not copy a title derived from the first line', () => {
  assert.equal(copyPayload({body:'First line\nsecond', title:'First line', title_source:'first_line'}), 'First line\nsecond')
})

test('uses recorded title meaning even when a separate explicit title matches the first body line', () => {
  assert.equal(copyPayload({body:'Rain\nmore', title:'Rain', title_source:'explicit'}), 'Rain\n\nRain\nmore')
})

test('uses live fields while editing and preserves unchanged persisted CRLF', () => {
  const persisted = {body:'one\r\ntwo\r\n', title:'Saved', title_source:'explicit'}
  assert.equal(copyPayload(persisted, 'one\ntwo\n', 'Saved'), 'Saved\n\none\r\ntwo\r\n')
  assert.equal(copyPayload(persisted, 'one\nchanged', 'Live title'), 'Live title\n\none\nchanged')
})

test('copies a document with an explicit title role in its body exactly once', () => {
  const document = {body:'My title\n\nThe writing', title:'My title', title_source:'explicit', title_in_body:true}
  assert.equal(copyPayload(document), 'My title\n\nThe writing')
  assert.equal(copyPayload(document, 'My title\n\nRevised writing', 'My title'), 'My title\n\nRevised writing')
})

test('copies a newly typed explicit title on an otherwise first-line-titled page', () => {
  assert.equal(copyPayload({body:'Opening line\nrest', title:null, title_source:'first_line'}, 'Opening line\nrest', 'New explicit title'), 'New explicit title\n\nOpening line\nrest')
})

test('preserves saved CRLF when only the title changes', () => {
  const saved = {body:'one\r\ntwo\r\n', title:'Old title', title_source:'explicit'}
  assert.equal(copyPayload(saved, 'one\ntwo\n', 'New title'), 'New title\n\none\r\ntwo\r\n')
})

test('preserves lone carriage returns when textarea normalization is otherwise unchanged', () => {
  const saved = {body:'one\rtwo\r', title:null, title_source:'first_line'}
  assert.equal(copyPayload(saved, 'one\ntwo\n', ''), 'one\rtwo\r')
})

test('button copies live editor values, reports clipboard failure, and cleans up', async () => {
  const fields = {
    '#writing-body': {value:'live body before debounce'},
    '#writing-title': {value:'Live title'},
  }
  const previousDocument = Object.getOwnPropertyDescriptor(globalThis, 'document')
  const previousNavigator = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
  const writes = []
  Object.defineProperty(globalThis, 'document', {configurable:true, value:{querySelector: selector => fields[selector]}})
  Object.defineProperty(globalThis, 'navigator', {configurable:true, value:{clipboard: {writeText: async value => writes.push(value)}}})
  const listeners = new Map()
  const button = {
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => { if (listeners.get(name) === callback) listeners.delete(name) },
  }
  const status = {textContent:''}
  const element = {
    dataset: {
      persisted: JSON.stringify({body:'saved body', title:null, title_source:'first_line'}),
      bodySelector:'#writing-body', titleSelector:'#writing-title',
    },
    querySelector: selector => selector === '.copy-text-button' ? button : status,
  }
  const hook = {el:element}
  try {
    CopyText.mounted.call(hook)
    assert.equal(listeners.has('click'), true)
    await listeners.get('click')()
    assert.deepEqual(writes, ['Live title\n\nlive body before debounce'])
    assert.equal(status.textContent, 'Copied')

    // The payload is read at click time, not cached when the hook mounts.
    element.dataset.persisted = JSON.stringify({body:'new saved body', title:'Saved title', title_source:'explicit'})
    fields['#writing-body'].value = 'new saved body'
    fields['#writing-title'].value = 'Saved title'
    globalThis.navigator.clipboard.writeText = async () => { throw new Error('denied') }
    await listeners.get('click')()
    assert.equal(status.textContent, 'Could not copy. Check clipboard access and try again.')
    CopyText.destroyed.call(hook)
    assert.equal(listeners.has('click'), false)
    assert.equal(hook.statusTimer, null)
  } finally {
    if (previousDocument) Object.defineProperty(globalThis, 'document', previousDocument)
    else delete globalThis.document
    if (previousNavigator) Object.defineProperty(globalThis, 'navigator', previousNavigator)
    else delete globalThis.navigator
    clearTimeout(hook.statusTimer)
  }
})

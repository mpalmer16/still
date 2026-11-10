import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'
const source = await readFile(new URL('../assets/js/writing_exports.js', import.meta.url), 'utf8')
const {WritingExports} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

test('PDF requests reach the native renderer and completion survives changing editing controls', () => {
  const previous = globalThis.window
  const listeners = new Map(), events = new Map(), sent = [], native = []
  globalThis.window = {
    addEventListener: (name, handler) => listeners.set(name, handler),
    removeEventListener: (name, handler) => { if (listeners.get(name) === handler) listeners.delete(name) },
    webkit: {messageHandlers: {stillPDFExport: {postMessage: payload => native.push(payload)}}},
  }
  const hook = {handleEvent: (name, handler) => events.set(name, handler), pushEvent: (name, payload) => sent.push([name, payload])}
  try {
    WritingExports.mounted.call(hook)
    const request = {ticket:'source-bound-ticket', request_id:'request-1'}
    events.get('writing-pdf-request')(request)
    assert.deepEqual(native, [request])
    listeners.get('still:pdf-export-result')({detail:{path:'/synthetic Exports/Essay.pdf', request_id:'request-1'}})
    assert.deepEqual(sent.at(-1), ['pdf_export_finished', {path:'/synthetic Exports/Essay.pdf', request_id:'request-1'}])
    listeners.get('still:pdf-export-result')({detail:{error:'Source changed', request_id:'request-1'}})
    assert.deepEqual(sent.at(-1), ['pdf_export_failed', {message:'Source changed', request_id:'request-1'}])
    delete window.webkit
    events.get('writing-pdf-request')(request)
    assert.equal(sent.at(-1)[0], 'pdf_export_failed')
    assert.match(sent.at(-1)[1].message, /Mac app/)
    WritingExports.destroyed.call(hook)
    assert.equal(listeners.size, 0)
  } finally { globalThis.window = previous }
})

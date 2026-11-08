import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'

const source = await readFile(new URL('../assets/js/indentation.js', import.meta.url), 'utf8')
const {indentationForEnter, insertEnter, replaceSelection} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

test('Enter continues the exact leading tabs and spaces', () => {
  assert.equal(indentationForEnter('\t  words', 8), '\t  ')
  assert.equal(indentationForEnter('first\n\tsecond', 13), '\t')
  assert.equal(indentationForEnter('  first\nsecond', 14), '')
})

test('the next Enter after two consecutive indented nonblank lines returns to the margin', () => {
  assert.equal(indentationForEnter('  first\n\tsecond', 15), '')
  assert.equal(indentationForEnter('  first\n\n\tthird', 15), '\t')
  assert.equal(indentationForEnter('first\n  second', 14), '  ')
})

test('Shift Enter always continues the current indentation', () => {
  assert.equal(indentationForEnter('  first\n\tsecond', 15, 15, true), '\t')
})

test('line cutoff applies only at the end of text, and Enter inside indentation does not duplicate it', () => {
  assert.equal(indentationForEnter('  first\n  second tail', 16), '  ')
  assert.equal(indentationForEnter('  first\n  second', 16), '')
  assert.equal(indentationForEnter('\twords', 0), '')
  assert.equal(indentationForEnter('  \twords', 1), ' ')
  assert.equal(indentationForEnter('\n\twords', 0), '')
  assert.equal(indentationForEnter('\t', 1), '\t')
  assert.equal(indentationForEnter('  ', 2, 2, true), '  ')
})

test('Enter replaces a selection and preserves all text after it', () => {
  const textarea = {
    value: '  before selected after', selectionStart: 9, selectionEnd: 17,
    setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end },
    setRangeText(text, start, end, mode) {
      this.value = this.value.slice(0, start) + text + this.value.slice(end)
      this.selectionStart = this.selectionEnd = mode === 'end' ? start + text.length : start
    },
    dispatchEvent() {},
  }
  const event = {key: 'Enter', shiftKey: false, preventDefault() { this.prevented = true }}
  assert.equal(insertEnter(textarea, event, {exec: () => false}), true)
  assert.equal(event.prevented, true)
  assert.equal(textarea.value, '  before \n   after')
  assert.equal(textarea.selectionStart, 12)
})

test('Enter uses native insertText when available', () => {
  const textarea = {value: '\twords', selectionStart: 6, selectionEnd: 6, setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end }}
  let command
  const event = {key: 'Enter', shiftKey: false, preventDefault() { this.prevented = true }}
  assert.equal(insertEnter(textarea, event, {exec: (...args) => { command = args; return true }}), true)
  assert.deepEqual(command, ['insertText', false, '\n\t'])
  assert.equal(event.prevented, true)
})

test('manual Tab insertion also uses native insertText for undo', () => {
  const textarea = {value: 'word', selectionStart: 2, selectionEnd: 2, setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end }}
  let command
  assert.equal(replaceSelection(textarea, '\t', 2, 2, 'end', (...args) => { command = args; return true }), true)
  assert.deepEqual(command, ['insertText', false, '\t'])
})

test('composition and modifier commands keep their native behavior', () => {
  for (const options of [
    {composing: true},
    {event: {isComposing: true}},
  ]) {
    const event = {key: 'Enter', preventDefault() { this.prevented = true }, ...options.event}
    assert.equal(insertEnter({value: '  words', selectionStart: 7, selectionEnd: 7}, event, {
      composing: options.composing ?? false,
      exec: () => { throw new Error('should not execute') },
    }), false)
    assert.equal(event.prevented, undefined)
  }

  for (const modifiers of [{metaKey: true}, {ctrlKey: true}, {altKey: true}]) {
    const event = {key: 'Enter', preventDefault() { this.prevented = true }, ...modifiers}
    assert.equal(insertEnter({value: 'words', selectionStart: 5, selectionEnd: 5}, event, {
      exec: () => { throw new Error('should not execute') },
    }), false)
    assert.equal(event.prevented, undefined)
  }
})

import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'

const source = await readFile(new URL('../assets/js/linked_writing.js', import.meta.url), 'utf8')
const {linkedParts, insertReference, expandedCopy, editableStretch} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
const marker = '[[poem: Poems/rain.txt | 00000000-0000-4000-8000-000000000001]]'

test('linked stretches reassemble exact words, blank lines, Unicode and repeated markers', () => {
  const body = `🙂 Before\r\n\r\n${marker}\r\n\tAfter\r\n${marker}`
  const parts = linkedParts(body)
  assert.equal(parts.map(part => part.raw).join(''), body)
  assert.equal(parts.filter(part => part.kind === 'reference').length, 2)
  assert.equal(parts.at(-1).kind, 'text')
  assert.equal(parts.at(-1).raw, '')
  assert.equal(linkedParts(marker)[0].raw, '')
})

test('unsafe paths, malformed identities and inline markers remain ordinary authored words', () => {
  for (const body of ['[[poem: ../other]]', '[[poem: /other]]', '[[poem: a%00b]]', '[[poem: a | bad-id]]', `Before ${marker}`, '[[poem: a%0Ab]]']) {
    assert.deepEqual(linkedParts(body), [{kind: 'text', raw: body}])
  }
})

test('copy expands own-line references in CR-only files without rewriting surrounding separators', () => {
  const body = `Before\r${marker}\rAfter`
  assert.equal(linkedParts(body).filter(part => part.kind === 'reference').length, 1)
  assert.equal(expandedCopy(body, {[marker]: 'Rain\rRiver'}), 'Before\rRain\rRiver\rAfter')
})

test('inserting at a caret preserves all existing words and leaves a place to continue', () => {
  const body = 'Before🙂After'
  const inserted = insertReference(body, 'Before🙂'.length, marker)
  assert.equal(inserted.body, `Before🙂\n\n${marker}\n\nAfter`)
  assert.equal(inserted.body.slice(inserted.caret), 'After')
  assert.equal(insertReference('', 0, marker).body, `${marker}\n\n`)
  assert.equal(insertReference('before\n\nafter', 8, marker).body, `before\n\n${marker}\n\nafter`)
})

test('copy includes the displayed poem once, preserving unavailable links and source spacing', () => {
  const missing = '[[poem: missing.txt]]'
  const nested = '[[poem: another.txt]]'
  const body = `Before\r\n${marker}\r\nAfter\r\n${missing}`
  assert.equal(expandedCopy(body, {[marker]: `  Rain\n\tRiver\n${nested}`}), `Before\r\n  Rain\n\tRiver\n${nested}\r\nAfter\r\n${missing}`)
})

test('editing stretches keep their reference boundaries outside the editable words', () => {
  const before = editableStretch('Before\n\n', false, true)
  assert.deepEqual(before, {before:'', value:'Before\n', after:'\n'})
  assert.equal(before.before + before.value + 'More words' + before.after + marker, `Before\nMore words\n${marker}`)
  for (const raw of ['\r\n\tWords  \r\n', '\n', '\n\n', '']) {
    const part = editableStretch(raw, true, true)
    assert.equal(part.before + part.value + part.after, raw)
  }
})

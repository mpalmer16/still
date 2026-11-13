import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'
const source = await readFile(new URL('../assets/js/file_recovery.js', import.meta.url), 'utf8')
const indentation = await readFile(new URL('../assets/js/indentation.js', import.meta.url), 'utf8')
const combined = source.replace('import {insertEnter, replaceSelection} from "./indentation"\n', '') + '\n' + indentation.replace(/^export /gm, '')
const {readCopies, holdArrival, captureCopy, acknowledgeCopies, shouldBlockNavigation, restoreCopy, captureAfterArrival, resumableCopy, migratePosition, positionKey, freezeForm, pushStartNext, writingShortcut} = await import(`data:text/javascript;base64,${Buffer.from(combined).toString('base64')}`)
const memory = () => {const map = new Map(); return {getItem: k => map.get(k) ?? null, setItem: (k,v) => map.set(k,v), removeItem: k => map.delete(k)}}
const blank = {body: '', title: ''}

test('an arriving recovery copy survives new typing and a saved acknowledgment', () => {
  const store = memory(), old = {body: '\told\n\nwords  \n', title: ''}, current = {body: 'Synthetic\nnew words', title: ''}
  captureCopy(store, 'new', old, blank)
  holdArrival(store, 'new', blank)
  captureCopy(store, 'new', current, blank)
  acknowledgeCopies(store, 'new', 'saved-id', current)
  assert.deepEqual(readCopies(store, 'new'), {active:null, held:[]})
  assert.equal(readCopies(store, 'saved-id').active.body, old.body)
})
test('keystrokes made while save travels remain recoverable at the saved identity', () => {
  const store = memory(), saved = {body:'first', title:''}, newer = {body:'first\nsecond\n', title:''}
  captureCopy(store, 'new', newer, blank)
  acknowledgeCopies(store, 'new', 'saved-id', saved)
  assert.equal(readCopies(store, 'saved-id').active.body, newer.body)
})
test('failed recovery migration leaves the original copy intact', () => {
  const store = memory(), copy = {body:'retained', title:'', destination_folder:'notebook/section'}
  captureCopy(store, 'new', copy, blank)
  const original = store.getItem('new'), set = store.setItem
  store.setItem = (key,value) => {if(key === 'saved-id') throw Error('quota');set(key,value)}
  assert.throws(() => acknowledgeCopies(store,'new','saved-id',{body:'previous',title:''}))
  assert.equal(store.getItem('new'),original)
  assert.equal(readCopies(store,'new').active.destination_folder, 'notebook/section')
})
test('unreadable recovery storage is never silently replaced', () => {
  const store = memory(); store.setItem('poem','unreadable')
  assert.throws(() => captureCopy(store,'poem',{body:'new',title:''},blank))
  assert.equal(store.getItem('poem'),'unreadable')
})
test('acknowledgment removes only exact text matches', () => {
  const store = memory(), saved = {body:'Synthetic\nx\n\n',title:''}
  captureCopy(store,'poem',saved,blank);holdArrival(store,'poem',blank)
  captureCopy(store,'poem',{body:'Synthetic\nx\n',title:''},blank)
  acknowledgeCopies(store,'poem','poem',saved)
  assert.equal(readCopies(store,'poem').active.body,'Synthetic\nx\n')
})

test('metadata acknowledgment matches numeric wire fields and preserves newer edits', () => {
  const store = memory()
  const exact = {body:'Heading\nwords', title:'', title_line:'1', relative_path:'note.txt', notebook_id:'7', list_label:'07b', source_order:'7'}
  const newer = {...exact, body:'Heading\nwords\nnewer'}
  captureCopy(store, 'piece', exact, blank)
  holdArrival(store, 'piece', blank)
  captureCopy(store, 'piece', newer, blank)

  acknowledgeCopies(store, 'piece', 'piece', {...exact, title_line:1, notebook_id:7, source_order:7})

  const copies = readCopies(store, 'piece')
  assert.equal(copies.active.body, newer.body)
  assert.equal(copies.held.some(copy => copy.body === exact.body), false)
})

test('acknowledgment retains same-text edits to title meaning and placement metadata', () => {
  const store = memory(), saved = {body:'Next page words\n', title:'', title_line:'1', notebook_id:'12', list_label:'4', destination_folder:'section-a'}
  const later = {...saved, title_line:'2', list_label:'5', destination_folder:'section-b'}
  captureCopy(store, 'draft', later, blank)
  holdArrival(store, 'draft', blank)
  captureCopy(store, 'draft', later, blank)
  acknowledgeCopies(store, 'draft', 'saved-file', saved)
  const copies = readCopies(store, 'saved-file')
  assert.equal(copies.active.body, saved.body)
  assert.equal(copies.active.title_line, '2')
  assert.equal(copies.active.list_label, '5')
  assert.equal(copies.active.destination_folder, 'section-b')
})

test('navigation is blocked only for changed words lacking safe recovery', () => {
  assert.equal(shouldBlockNavigation({body:'words\n',title:''},{body:'words',title:''},false),true)
  assert.equal(shouldBlockNavigation({body:'words\n',title:''},{body:'words',title:''},true),false)
  assert.equal(shouldBlockNavigation({body:'words',title:''},{body:'words',title:''},false),false)
  assert.equal(shouldBlockNavigation({body:'New title\n',title:''},{body:'',title:''},false),true)
  assert.equal(shouldBlockNavigation({body:'words',title:'',title_line:'2'},{body:'words',title:'',title_line:'1'},false),true)
})

test('restoring a copy consumes that offer and protects words replaced in the editor', () => {
  const store = memory(), offered = {body:'Old title\nrecovered',title:''}, current = {body:'another draft',title:''}
  captureCopy(store,'poem',offered,blank);holdArrival(store,'poem',blank)
  restoreCopy(store,'poem',offered,current,blank)
  const revised = {body:'Old title\nrecovered\nNew words',title:''}
  captureCopy(store,'poem',revised,blank);acknowledgeCopies(store,'poem','poem',revised)
  const survivors = readCopies(store,'poem')
  assert.equal(survivors.active.body,current.body)
  assert.equal(survivors.held.length,0)
})


test('failed arrival protection preserves the original copy through initial and later captures', () => {
  const store = memory(), originalCopy = {body:'Synthetic\nlast recoverable words',title:''}
  captureCopy(store,'poem',originalCopy,blank)
  const original = store.getItem('poem'), set = store.setItem
  store.setItem = () => {throw Error('quota')}
  assert.throws(() => captureAfterArrival(store,'poem',blank,blank,true))
  assert.equal(store.getItem('poem'),original)
  assert.throws(() => captureAfterArrival(store,'poem',{body:'new typing',title:''},blank,true))
  assert.equal(store.getItem('poem'),original)
  store.setItem = set
  captureAfterArrival(store,'poem',{body:'new typing',title:''},blank,true)
  assert.equal(readCopies(store,'poem').active.body,'new typing')
  assert.equal(readCopies(store,'poem').held[0].body,originalCopy.body)
})

test('Now resumes only a confirmed active draft based on the same file token', () => {
  const store=memory(), copy={body:'draft after echo',title:'',baseToken:'file-v1'}
  captureCopy(store,'still:poem-draft:fixture:id',copy,blank)
  assert.equal(resumableCopy(store,'still:poem-draft:fixture:id','file-v1',true).body,copy.body)
  assert.equal(resumableCopy(store,'still:poem-draft:fixture:id','outside-v2',true),null)
  assert.equal(resumableCopy(store,'still:poem-draft:fixture:id','file-v1',false),null)
})
test('caret and scroll migrate only after the destination position is stored', () => {
  const store=memory(), source='still:poem-draft:fixture:new',target='still:poem-draft:fixture:uuid'
  const position=JSON.stringify({start:4,end:9,scroll:480})
  store.setItem(positionKey(source),position)
  const set=store.setItem
  store.setItem=(k,v)=>{if(k===positionKey(target))throw Error('quota');set(k,v)}
  assert.throws(()=>migratePosition(store,source,target))
  assert.equal(store.getItem(positionKey(source)),position)
  store.setItem=set;migratePosition(store,source,target)
  assert.equal(store.getItem(positionKey(target)),position)
  assert.equal(store.getItem(positionKey(source)),null)
})


test('purging saved files from another tab cannot erase an active unsaved recovery copy', async () => {
  const store=memory(), key='still:poem-draft:collection:uuid'
  captureCopy(store,key,{body:'newer words in another tab',title:'',baseToken:'before'},blank)
  const original=store.getItem(key), listeners=new Map()
  globalThis.window={addEventListener:(type,listener)=>listeners.set(type,listener)}
  globalThis.localStorage=store
  try {
    await import(`data:text/javascript;base64,${Buffer.from(combined+'\n// separate tab event registration').toString('base64')}`)
    listeners.get('phx:file-purged')?.({detail:{key}})
    assert.equal(store.getItem(key),original)
  } finally { delete globalThis.window; delete globalThis.localStorage }
})

test('Unplaced draft recovery retains the chosen notebook and unnumbered destination', () => {
  const store = memory()
  const draft = {body: 'Transcribed words', title: '', notebook_id: '12', unplaced: 'true', baseToken: null}
  captureCopy(store, 'new', draft, blank)
  const resumed = resumableCopy(store, 'new', null, true)
  assert.equal(resumed.notebook_id, '12')
  assert.equal(resumed.unplaced, 'true')
  assert.equal(resumed.body, draft.body)
})

test('destination folder survives capture, restore, and acknowledgment comparisons', () => {
  const store = memory(), draft = {body:'Continuation', title:'', notebook_id:'12', destination_folder:'12/section-a'}
  captureCopy(store, 'new', draft, blank)
  assert.equal(readCopies(store, 'new').active.destination_folder, '12/section-a')
  restoreCopy(store, 'new', draft, {body:'Other words', title:''}, blank)
  assert.equal(readCopies(store, 'new').active.destination_folder, '12/section-a')
  acknowledgeCopies(store, 'new', 'saved-id', {...draft, destination_folder:'12/section-a'})
  const remaining = readCopies(store, 'saved-id')
  assert.equal(remaining.active.body, 'Other words')
  assert.equal(remaining.active.destination_folder, '')
  assert.equal([remaining.active, ...remaining.held].some(copy => copy.body === draft.body), false)
})

test('Save & start next freezing restores the form and prior disabled states', () => {
  const alreadyDisabled = {disabled:true, isConnected:true}
  const enabled = {disabled:false, isConnected:true}
  const externalSubmit = {disabled:false, isConnected:true}
  const form = {inert:true, elements:[alreadyDisabled, externalSubmit], querySelectorAll:() => [alreadyDisabled, enabled]}
  const release = freezeForm(form)
  assert.equal(form.inert, true)
  assert.equal(alreadyDisabled.disabled, true)
  assert.equal(enabled.disabled, true)
  assert.equal(externalSubmit.disabled, true)
  release()
  release()
  assert.equal(form.inert, true)
  assert.equal(alreadyDisabled.disabled, true)
  assert.equal(enabled.disabled, false)
  assert.equal(externalSubmit.disabled, false)
})

test('Save & start next snapshots one payload, suppresses duplicates, and releases after failure', () => {
  const external = {disabled:false, isConnected:true}
  const menu = {disabled:false, isConnected:true}
  const form = {inert:false, elements:[external], querySelectorAll:() => []}
  const state = {startNextControls:[menu]}, words = {body:'exact submitted words\n', destination_folder:'chosen section'}
  const payload = {writing:words, draft_key:'draft', start_next:true}
  const sent = []
  let reply
  const push = (...args) => { sent.push(args); reply = args[2] }
  assert.equal(pushStartNext(state, form, push, payload), true)
  assert.equal(pushStartNext(state, form, push, {writing:{body:'changed'}}), false)
  assert.equal(sent.length, 1)
  assert.equal(sent[0][0], 'save_file')
  assert.deepEqual(sent[0][1], payload)
  assert.equal(external.disabled, true)
  assert.equal(menu.disabled, true)
  reply({starting_next:false, error:'save rejected'})
  assert.equal(state.startNextPending, false)
  assert.equal(external.disabled, false)
  assert.equal(menu.disabled, false)
  assert.equal(words.body, 'exact submitted words\n')
  assert.equal(words.destination_folder, 'chosen section')
})

test('successful Save & start next stays frozen until the old hook is destroyed', () => {
  const field = {disabled:false, isConnected:true}
  const form = {inert:false, elements:[field], querySelectorAll:() => []}
  const state = {}
  let reply
  pushStartNext(state, form, (_event, _payload, callback) => { reply = callback }, {writing:{body:'saved'}})
  reply({starting_next:true})
  assert.equal(state.startNextPending, true)
  assert.equal(form.inert, true)
  assert.equal(field.disabled, true)
  state.startNextPending = false
  state.releaseStartNext()
  state.releaseStartNext = null
  assert.equal(form.inert, false)
  assert.equal(field.disabled, false)
})

test('Cmd or Control plus Shift plus Enter starts next only outside composition', () => {
  const key = {key:'Enter', metaKey:true, ctrlKey:false}
  assert.equal(writingShortcut({...key, shiftKey:true}, false), 'start_next')
  assert.equal(writingShortcut({...key, shiftKey:true, isComposing:true}, false), null)
  assert.equal(writingShortcut({...key, shiftKey:true}, true), null)
  assert.equal(writingShortcut({...key, shiftKey:false}, false), 'read')
  assert.equal(writingShortcut({...key, shiftKey:false, ctrlKey:true, metaKey:false}, false), 'read')
  assert.equal(writingShortcut({...key, shiftKey:true, key:'x'}, false), null)
})

import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {test} from 'node:test'
const source = await readFile(new URL('../assets/js/file_recovery.js', import.meta.url), 'utf8')
const indentation = await readFile(new URL('../assets/js/indentation.js', import.meta.url), 'utf8')
const combined = source.replace('import {insertEnter, replaceSelection} from "./indentation"\n', '') + '\n' + indentation.replace(/^export /gm, '')
const {readCopies, holdArrival, captureCopy, acknowledgeCopies, shouldBlockNavigation, restoreCopy, captureAfterArrival, resumableCopy, migratePosition, positionKey} = await import(`data:text/javascript;base64,${Buffer.from(combined).toString('base64')}`)
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
  const store = memory(), copy = {body:'retained', title:''}
  captureCopy(store, 'new', copy, blank)
  const original = store.getItem('new'), set = store.setItem
  store.setItem = (key,value) => {if(key === 'saved-id') throw Error('quota');set(key,value)}
  assert.throws(() => acknowledgeCopies(store,'new','saved-id',{body:'previous',title:''}))
  assert.equal(store.getItem('new'),original)
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

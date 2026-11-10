// Registration lifetime regression through real bridge HTTP/WebSocket routes; fake Loader only.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {NativeCore} from '../bridge/dsh-go-bridge/lib/native/core.js';
import {createNativeRoutes} from '../bridge/dsh-go-bridge/lib/native/routes.js';
import {effectiveLimits} from '../bridge/dsh-go-bridge/lib/native/limits.js';
import {normalizeScope} from '../bridge/dsh-go-bridge/lib/native/util.js';
const hold=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}};
const panel=(generation,save=()=>({patch:{generation:'done'}}))=>({view:{type:'text',text:generation},data(scope,emit){emit({generation});return()=>{}},actions:{save}});
async function fixture(t){
 const dir=mkdtempSync(join(tmpdir(),'native-generation-'));
 writeFileSync(join(dir,'package.json'),JSON.stringify({name:'generation-test',version:'1.0.0',dshGo:{v:1,contributes:{panels:[{id:'panel',title:'Panel'},{id:'other',title:'Other'}],'composer.actions':[{id:'go',label:'Go'}]}}}));writeFileSync(join(dir,'index.js'),'');
 const entry={options:{name:pathToFileURL(join(dir,'index.js')).href},parent:{tree:{ctx:{baseUrl:pathToFileURL(dir+'/').href}}},fiber:{uid:7}};
 const entries=[entry],disposers=[],warnings=[];
 const core=new NativeCore({get:n=>n==='loader'?{entries:()=>entries}:undefined,logger:{warn(...x){warnings.push(x)}}},effectiveLimits({}),'test');
 const routes=createNativeRoutes(core);
 const service=Object.assign(Object.create(core.service),{ctx:{fiber:{entry},effect(fn){const d=fn();disposers.push(d);return d}}});
 const server=createServer((req,res)=>routes.handle(req,res,new URL(req.url,'http://local').pathname,new URL(req.url,'http://local')));
 server.on('upgrade',(req,socket,head)=>routes.upgrade(req,socket,head));server.listen(0,'127.0.0.1');await once(server,'listening');
 const port=server.address().port,sockets=[];
 async function stream(){
  const ws=new WebSocket(`ws://127.0.0.1:${port}/dsh-go/v1/stream`);sockets.push(ws);
  const messages=[],waiters=[];
  ws.addEventListener('message',e=>{const m=JSON.parse(e.data),i=waiters.findIndex(w=>w.p(m));if(i<0)messages.push(m);else{const [w]=waiters.splice(i,1);clearTimeout(w.timer);w.resolve(m)}});
  await once(ws,'open');
  const next=p=>{const i=messages.findIndex(p);if(i>=0)return Promise.resolve(messages.splice(i,1)[0]);return new Promise((resolve,reject)=>{const w={p,resolve,timer:setTimeout(()=>reject(new Error('stream message timeout')),1500)};waiters.push(w)})};
  ws.send(JSON.stringify({t:'hello',v:[1]}));const welcome=await next(m=>m.t==='welcome');
  return {welcome,next,send:m=>ws.send(JSON.stringify(m))};
 }
 async function invoke(w,composer=false){
  const response=await fetch(`http://127.0.0.1:${port}/dsh-go/v1/invoke`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({v:1,pkg:'generation-test',id:composer?'go':'panel',surface:composer?'composer.actions':'panel',...(composer?{}:{action:'save'}),scope:{sessionId:'s'},stream:w?.welcome.conn})});return {status:response.status,...await response.json()};
 }
 async function feed(id='panel'){const f=core.feed('generation-test',id,'panel',normalizeScope({sessionId:'s'}),'');f.pin();await f.waitFirst(1000);return f}
 t.after(async()=>{for(const w of sockets)w.close();routes.dispose();core.dispose();while(disposers.length)disposers.pop()();server.closeAllConnections();await new Promise(r=>server.close(r));rmSync(dir,{recursive:true,force:true})});
 return {core,service,invoke,feed,stream,entry,warnings,routes};
}
const value=f=>(f.pending?.value??f.data).generation;
for(const change of ['replace','dispose-register','dispose-only','fiber-replace'])test(`direct late patch isolated after ${change}`,async t=>{
 const f=await fixture(t),begun=hold(),held=hold();let signal;
 const off=f.service.panel('panel',panel('OLD',async(s,e)=>{signal=e.signal;begun.resolve();return held.promise}));
 const work=f.invoke();await begun.promise;
 if(change.startsWith('dispose'))off();
 if(change!=='dispose-only')f.service.panel('panel',panel('NEW'));
 if(change==='fiber-replace'){f.entry.fiber={uid:8};f.core.markDirty()}
 const fresh=change==='dispose-only'?undefined:await f.feed();held.resolve({patch:{generation:'STALE'}});const r=await work;
 assert.equal(r.status,200);assert.deepEqual(r.effects,[]);assert.match(r.issues[0].message,/registration/);assert.ok(signal.aborted);if(fresh)assert.equal(value(fresh),'NEW');
 assert.equal(f.core.health.get('generation-test')?.consecutive??0,0);
});
test('normal direct result and unrelated panel replacement preserve the action',async t=>{
 const f=await fixture(t),begun=hold(),held=hold();f.service.panel('panel',panel('OLD',()=>{begun.resolve();return held.promise}));f.service.panel('other',panel('OTHER'));
 const feed=await f.feed();const work=f.invoke();await begun.promise;f.service.panel('other',panel('OTHER_NEW'));held.resolve({patch:{generation:'DONE'}});
 assert.equal((await work).status,200);assert.equal(value(feed),'DONE');
});
test('explicit patch to a replaced different panel is dropped, other effects survive',async t=>{
 const f=await fixture(t),begun=hold(),held=hold();f.service.panel('panel',panel('OLD',()=>{begun.resolve();return held.promise}));f.service.panel('other',panel('OTHER'));
 const work=f.invoke();await begun.promise;f.service.panel('other',panel('OTHER_NEW'));const feed=await f.feed('other');held.resolve([{type:'patch',id:'other',data:{generation:'STALE'}},{toast:'finished'}]);
 const r=await work;assert.equal(r.status,200);assert.deepEqual(r.effects.map(x=>x.type),['toast']);assert.equal(value(feed),'OTHER_NEW');assert.equal(r.issues[0].code,'bad-effect');
});
test('old rejected handler does not penalize replacement health',async t=>{
 const f=await fixture(t),begun=hold(),held=hold();f.service.panel('panel',panel('OLD',()=>{begun.resolve();return held.promise}));
 const work=f.invoke();await begun.promise;f.service.panel('panel',panel('NEW'));const fresh=await f.feed();held.reject(new Error('old failure'));
 assert.deepEqual((await work).effects,[]);assert.equal(value(fresh),'NEW');assert.equal(f.core.health.get('generation-test')?.consecutive??0,0);
});
test('current handler rejection keeps existing plugin-error contract',async t=>{
 const f=await fixture(t);f.service.panel('panel',panel('OLD',()=>{throw new Error('current failure')}));const r=await f.invoke();assert.equal(r.status,500);assert.equal(r.error.code,'plugin-error');
});
test('composer handler token is checked too',async t=>{
 const f=await fixture(t),begun=hold(),held=hold();f.service.on('go',()=>{begun.resolve();return held.promise});const work=f.invoke(undefined,true);await begun.promise;f.service.on('go',()=>({toast:'new'}));held.resolve({toast:'old'});assert.deepEqual((await work).effects,[]);
});
for(const change of ['replace','dispose-register','cancel','normal'])test(`deferred ${change} uses original registration and one settlement`,async t=>{
 const f=await fixture(t),held=hold();let signal;const off=f.service.panel('panel',panel('OLD',()=>({pending:true,result:s=>{signal=s;return held.promise}})));const w=await f.stream();const initial=await f.invoke(w);assert.equal(initial.status,200);assert.ok(initial.pending);
 if(change==='dispose-register')off();
 if(change==='replace'||change==='dispose-register')f.service.panel('panel',panel('NEW'));
 const feed=await f.feed();
 if(change==='cancel')w.send({t:'cancel',pending:initial.pending.id});
 // Replacement is proactively cancelled by changed; explicit cancel uses the same existing wire result.
 if(change!=='normal'){const m=await w.next(m=>m.t==='void'&&m.pending===initial.pending.id);assert.equal(m.reason,'cancelled');assert.ok(signal.aborted)}
 held.resolve({patch:{generation:'RESULT'}});
 if(change==='normal'){const m=await w.next(m=>m.t==='done'&&m.pending===initial.pending.id);assert.equal(m.effects[0].type,'patch');assert.equal(value(feed),'RESULT')}
 else{await new Promise(r=>setTimeout(r,20));assert.equal(value(feed),change==='cancel'?'OLD':'NEW')}
});
test('deferred replaced before completion is guarded without waiting for changed event',async t=>{
 const f=await fixture(t),held=hold();f.service.panel('panel',panel('OLD',()=>({pending:true,result:held.promise})));const w=await f.stream(),r=await f.invoke(w);f.service.panel('panel',panel('NEW'));const feed=await f.feed();held.resolve({patch:{generation:'STALE'}});assert.equal((await w.next(m=>m.pending===r.pending.id&&m.t==='void')).reason,'cancelled');assert.equal(value(feed),'NEW');
});

test('stale direct deferred promise is observed and never started as pending',async t=>{
 const f=await fixture(t),begun=hold(),held=hold();
 f.service.panel('panel',panel('OLD',async()=>{begun.resolve();await held.promise;return {pending:true,result:Promise.reject(new Error('discarded work'))}}));
 const work=f.invoke();await begun.promise;f.service.panel('panel',panel('NEW'));held.resolve();const r=await work;
 assert.equal(r.status,200);assert.deepEqual(r.effects,[]);assert.equal(r.pending,undefined);await new Promise(r=>setImmediate(r));
});
test('old deferred rejection cancels without recording a new plugin failure',async t=>{
 const f=await fixture(t),held=hold();f.service.panel('panel',panel('OLD',()=>({pending:true,result:held.promise})));const w=await f.stream(),r=await f.invoke(w);
 f.service.panel('panel',panel('NEW'));const fresh=await f.feed();held.reject(new Error('old deferred failure'));
 assert.equal((await w.next(m=>m.pending===r.pending.id&&m.t==='void')).reason,'cancelled');assert.equal(f.warnings.length,0);assert.equal(value(fresh),'NEW');assert.equal(f.core.health.get('generation-test')?.consecutive??0,0);
});

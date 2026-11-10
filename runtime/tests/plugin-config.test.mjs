import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {apply} from '../bridge/dsh-go-bridge/lib/index.js';
import {withSources} from './plugin-config-source-fixture.mjs';
const root='/dsh-go/v1/plugin-config';
async function fixture(t,{connection=true,entries=[],addressable=entries}={}){
 const routes=[],dispose=[],hooks=new Map();let reads=0;
 const editor={canWrite:()=>true,entries:()=>addressable,configuration:()=>{reads++;return addressable.map(entry=>({entry,inherited:entry.options.config??{},override:entry.options.config??{}}));}};
 const ctx={logger:{warn(){}},get:n=>n==='loader'?{entries:()=>entries}:n==='configEditor'?editor:n==='connection'&&connection?{requestRejection:()=>undefined}:undefined,
 on(n,fn){const fns=hooks.get(n)??[];fns.push(fn);hooks.set(n,fns);},provide(){},effect(fn){const d=fn();if(typeof d==='function')dispose.push(d);},inject(_deps,fn){fn(ctx);},
 webServer:{register(r){routes.push(r);return ()=>{};},registerUpgrade(){return ()=>{};}}};
 withSources(ctx,entries);apply(ctx,{persist:false,guardRoutes:false});
 const server=createServer((req,res)=>routes.find(r=>r.kind==='prefix'&&req.url.startsWith(r.path)).handler(req,res));
 server.listen(0,'127.0.0.1');await once(server,'listening');
 t.after(async()=>{dispose.reverse().forEach(d=>d());server.closeAllConnections();await new Promise(r=>server.close(r));});
 return {async get(path=root){const r=await fetch(`http://127.0.0.1:${server.address().port}${path}`);const text=await r.text();return {status:r.status,body:text.startsWith('{')?JSON.parse(text):text};},reads:()=>reads};
}
function entry(id,graph,value={}){const schema=Object.assign(v=>v,{toJSON:()=>structuredClone(graph)});return {options:{id,name:'@scope/plugin',config:value},fiber:{uid:7,state:2,runtime:{Config:schema},config:value}};}
const simple={uid:1,refs:{1:{type:'object',meta:{},dict:{visible:2}},2:{type:'string',meta:{}}}};
test('missing connection is 503 before both config reads',async t=>{const f=await fixture(t,{connection:false});for(const p of [root,root+'/one'])assert.equal((await f.get(p)).status,503);assert.equal(f.reads(),0);});
test('duplicate ids cannot select first entry',async t=>{const es=[entry('same',simple),entry('same',simple)],f=await fixture(t,{entries:es});const list=(await f.get()).body.entries;assert(list.every(e=>e.reason==='ambiguous-id'));assert.equal((await f.get(root+'/same')).status,403);});
test('nested Include not addressable',async t=>{const f=await fixture(t,{entries:[entry('nested',simple)],addressable:[]});assert.equal((await f.get()).body.entries[0].reason,'nested-include');assert.equal((await f.get(root+'/nested')).status,404);});
test('inactive failed and unsupported schema never disclose configuration',async t=>{const a=entry('inactive',simple),b=entry('failed',simple),c=entry('opaque',{uid:1,refs:{1:{type:'any',meta:{default:'SYNTHETIC_HIDDEN'}}}});a.fiber.state=0;b.fiber.state=3;const f=await fixture(t,{entries:[a,b,c]});const out=await f.get();assert.equal(out.body.entries[0].state,'inactive');assert.equal(out.body.entries[1].state,'failed');assert.equal(out.body.entries[2].reason,'unsupported-schema');for(const id of ['inactive','failed','opaque'])assert.equal((await f.get(root+'/'+id)).status,404);});
test('shared refs, secret const and ancestor defaults are redacted',async t=>{
 const graph={uid:1,refs:{1:{type:'object',meta:{default:{visible:'ok',parent:{secret:'SYNTHETIC_HIDDEN'}}},dict:{visible:2,parent:3,alias:4}},2:{type:'string',meta:{}},3:{type:'object',meta:{default:{secret:'SYNTHETIC_HIDDEN'},extra:{sample:'SYNTHETIC_HIDDEN'}},dict:{secret:4}},4:{type:'const',value:'SYNTHETIC_HIDDEN',meta:{role:'secret',default:'SYNTHETIC_HIDDEN',extra:{sample:'SYNTHETIC_HIDDEN'}}}}};
 const f=await fixture(t,{entries:[entry('one',graph,{visible:'ok',parent:{secret:'SYNTHETIC_HIDDEN'},alias:'SYNTHETIC_HIDDEN',unknown:'SYNTHETIC_HIDDEN'})]});const {body,status}=await f.get(root+'/one');assert.equal(status,200);assert(!JSON.stringify(body).includes('SYNTHETIC_HIDDEN'));assert.deepEqual(body.value,{visible:'ok',parent:{}});assert(body.secrets.every(s=>s.configured&&s.writable===false));
});
test('transform secret union branch cannot expose same scalar via ordinary branch',async t=>{
 const graph={uid:1,refs:{1:{type:'object',meta:{},dict:{field:2}},2:{type:'union',meta:{default:'SYNTHETIC_HIDDEN'},list:[3,5]},3:{type:'transform',meta:{},inner:4},4:{type:'string',meta:{role:'secret'}},5:{type:'string',meta:{}}}};
 const f=await fixture(t,{entries:[entry('one',graph,{field:'SYNTHETIC_HIDDEN'})]});const {body}=await f.get(root+'/one');assert(!JSON.stringify(body).includes('SYNTHETIC_HIDDEN'));assert.deepEqual(body.value,{});
});
test('secret change invalidates opaque revision even when visible values equal',async t=>{const graph={uid:1,refs:{1:{type:'object',dict:{secret:2}},2:{type:'string',meta:{role:'secret'}}}};const e=entry('one',graph,{secret:'SYNTHETIC_A'}),f=await fixture(t,{entries:[e]});const before=(await f.get(root+'/one')).body;e.options.config.secret='SYNTHETIC_B';const after=(await f.get(root+'/one')).body;assert.deepEqual(before.value,after.value);assert.notEqual(before.revision,after.revision);assert(!before.revision.includes('SYNTHETIC'));});

test('array union removes secret paths even when ordinary branch comes first',async t=>{
 const graph={uid:1,refs:{1:{type:'object',dict:{rows:2}},2:{type:'union',list:[3,4]},3:{type:'array',inner:5},4:{type:'array',inner:6},5:{type:'object',dict:{secret:7,visible:7}},6:{type:'object',dict:{secret:8,visible:7}},7:{type:'string'},8:{type:'string',meta:{role:'secret'}}}};
 const f=await fixture(t,{entries:[entry('one',graph,{rows:[{secret:'SYNTHETIC_HIDDEN',visible:'ok'}]})]});const {body}=await f.get(root+'/one');assert(!JSON.stringify(body).includes('SYNTHETIC_HIDDEN'));assert.deepEqual(body.value,{rows:[{visible:'ok'}]});
});

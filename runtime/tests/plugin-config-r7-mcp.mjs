// Synthetic stdio MCP peer: initialization and empty discovery only, no tools.
import {createInterface} from 'node:readline';
import {appendFileSync,readFileSync} from 'node:fs';
const fields=readFileSync(`/proc/${process.pid}/stat`,'utf8').split(') ').at(-1).split(' ');
appendFileSync(process.env.R7_MCP_RECORD,JSON.stringify({pid:process.pid,ppid:process.ppid,startTicks:Number(fields[19])})+'\n');
const input=createInterface({input:process.stdin});input.on('close',()=>process.exit(0));
input.on('line',line=>{
 const request=JSON.parse(line);if(request.id===undefined)return;
 let result;
 if(request.method==='initialize')result={protocolVersion:request.params.protocolVersion,capabilities:{tools:{},resources:{},prompts:{}},serverInfo:{name:'wave10-synthetic-phone',version:'1.0.0'}};
 else if(request.method==='tools/list')result={tools:[]};
 else if(request.method==='resources/list')result={resources:[]};
 else if(request.method==='resources/templates/list')result={resourceTemplates:[]};
 else if(request.method==='prompts/list')result={prompts:[]};
 else if(request.method==='ping')result={};
 else {process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,error:{code:-32601,message:'Synthetic peer has no operation'}})+'\n');return;}
 process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\n');
});

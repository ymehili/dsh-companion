// Read-only contract probe. Uses the existing local browser credential in memory;
// never prints or writes credentials, prompts, transcript text, or request payloads.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash, createHmac, randomUUID} from 'node:crypto';
const authority = '127.0.0.1:19387';
const credentials = fs.readFileSync(path.join(os.homedir(), '.dsh/.credentials.yaml'), 'utf8');
const block = credentials.split(/\n(?=  \S)/).find(x => x.includes('client-connection/browser-session:'));
const match = block?.match(/secret:\s*['"]?([A-Za-z0-9_-]+)/);
if (!match) throw Error('Browser credential unavailable');
const now = Date.now();
const body = Buffer.from(JSON.stringify({version:1, authority, issuedAt:now, expiresAt:now+60000})).toString('base64url');
const signature = createHmac('sha256', Buffer.from(match[1], 'base64url')).update(body).digest('base64url');
const cookie = `dsh-auth-${createHash('sha256').update(authority).digest('base64url')}=v1.${body}.${signature}`;
async function rpc(method, payload) {
  const rpcId = randomUUID();
  const r = await fetch(`http://${authority}/api/${method}`, {method:'POST',headers:{Origin:`http://${authority}`, Cookie:cookie,'Content-Type':'application/json'},body:JSON.stringify({type:'client-request',rpcId,method,payload})});
  if(!r.ok) throw Error(`Probe HTTP ${r.status}`);
  const e=await r.json();
  if(e.rpcId!==rpcId || !e.result?.ok) throw Error(`Probe refused ${e.result?.error?.code || 'invalid response'}`);
  return e.result.value;
}
const list=await rpc('session/list',{args:{_request:{}}});
console.log(JSON.stringify({listKeys:Object.keys(list),count:list.items?.length,firstItemKeys:Object.keys(list.items?.[0]||{}),projectionKeys:Object.keys(list.items?.[0]?.projections?.values||{})}));
if (process.argv.includes('--image-limits')) console.log(JSON.stringify({imageLimits:list.items.find(x=>x.projections?.values?.imageLimits)?.projections.values.imageLimits}));
if (process.argv.includes('--ui-contract')) {
  const inbox = await rpc('threadInbox/snapshot', {args:{}});
  const records = Object.values(inbox.threads || {});
  if (process.argv.includes('--shelf-parity')) {
    const categories={};
    for(const row of list.items.filter(x=>x.origin!=='subagent')) {
      const r=inbox.threads?.[row.sessionId]||{}, f=r.facts||{};
      const shelf=f.archived||f.deleted||f.subagent?'hidden':r.settledOverride==='settled'?'settled':r.pinnedAt!=null?'pinned':!f.pending?.length&&!f.failedAt&&(f.running||row.running||f.backgroundWork)?'working':'inbox';
      const k=`${shelf}:${row.blank?'blank':'nonblank'}:${inbox.threads?.[row.sessionId]?'record':'missing'}`;
      categories[k]=(categories[k]||0)+1;
    }
    console.log(JSON.stringify({shelfVisibilityAudit:categories}));
    const {spawnSync}=await import('node:child_process');
    const now=Date.now();
    const probe=spawnSync('./build/shelf-parity',[],{input:JSON.stringify({cookie,rows:list.items,inbox,now}),encoding:'utf8',timeout:20000});
    if(probe.status!==0) throw Error('Workspace parity baseline failed: '+probe.stderr.slice(-500));
    const native=JSON.parse(probe.stdout), archived=new Set(native.archived), pinned=new Set(native.pinned), mac={};
    for(const row of list.items) {
      if(row.origin==='subagent'||row.blank||archived.has(row.sessionId))continue;
      const r=inbox.threads?.[row.sessionId]??{pinnedAt:pinned.has(row.sessionId)?1:null};
      const f={...(r.facts??{createdAt:row.updatedAt,lastSendAt:row.updatedAt,running:row.running,backgroundWork:(row.projections?.values?.subagentCatalog??[]).some(c=>list.items.find(x=>x.sessionId===c.id)?.running),pending:[]})};
      const pending=[...(f.pending??[])];
      for(const q of row.projections?.values?.userQuestions?.active??[]) {
        const kind=q.questions?.some(x=>x.intent?.kind==='plan-review')?'plan-review':'question';
        if(!pending.some(x=>x.id===q.callId||x.kind===kind))pending.push({id:q.callId,kind});
      }
      const raised=pending.length>0||(f.failedAt!=null&&f.failedAt>(r.snoozedAt??Infinity))||(f.completedAt!=null&&f.completedAt>(r.snoozedAt??Infinity));
      const shelf=f.archived||f.deleted||f.subagent?null:Number.isFinite(r.snoozedUntil)&&r.snoozedUntil>now&&!raised?'snoozed':r.settledOverride==='settled'?'settled':r.pinnedAt!=null?'pinned':!pending.length&&!f.failedAt&&(f.running||f.backgroundWork)?'working':'inbox';
      if(shelf)(mac[shelf]??=[]).push(row.sessionId);
    }
    const keys=[...new Set([...Object.keys(mac),...Object.keys(native.nativeMembership)])].sort();
    const sameMembership=keys.every(k=>JSON.stringify((mac[k]??[]).sort())===JSON.stringify((native.nativeMembership[k]??[]).sort()));
    const counts=x=>Object.fromEntries(keys.map(k=>[k,(x[k]??[]).length]));
    console.log(JSON.stringify({macCounts:counts(mac),nativeCounts:counts(native.nativeMembership),sameMembership,archivedRegistryCount:archived.size,blankOrdinaryCount:list.items.filter(x=>x.origin!=='subagent'&&x.blank).length}));
    if(!sameMembership)throw Error('Native and Mac shelf membership differ for the same captured inputs');
  }
  const catalog = await rpc('session/modelCatalog', {args:{}});
  console.log(JSON.stringify({inboxKeys:Object.keys(inbox),inboxActive:inbox.settings?.activated,threadCount:records.length,threadKeys:Object.keys(records[0]||{}),factKeys:Object.keys(records.find(x=>x.facts)?.facts||{}),modelGroups:catalog.groups?.length,modelKeys:Object.keys(catalog.groups?.[0]?.models?.[0]||{})}));
  if (process.argv.includes('--inbox-watch')) {
    const start = Date.now();
    const update = await rpc('threadInbox/watch', {args:{request:{epoch:inbox.epoch,revision:inbox.revision}}});
    console.log(JSON.stringify({watchDelta:update.full===false,epochMatches:update.epoch===inbox.epoch,revisionMonotonic:update.revision>=inbox.revision,changedThreads:Object.keys(update.threads||{}).length,waitedMs:Date.now()-start}));
    if (update.full!==false || update.epoch!==inbox.epoch) throw Error('Watch did not honor the source epoch/revision; no client update was mutated');
  }
}
if (process.argv.includes('--socket')) {
  const {spawnSync} = await import('node:child_process');
  const item = list.items.find(x => x.origin !== 'subagent' && !x.blank);
  if (!item) throw Error('No existing ordinary session to observe');
  const result = spawnSync('./build/live-socket', [], {input:JSON.stringify({cookie,sessionId:item.sessionId,control:process.argv.includes('--control'),audit:process.argv.includes('--audit-rendering')}), encoding:'utf8', timeout:20000});
  if (result.status !== 0) throw Error('Native socket probe failed; inspect sanitized stderr: ' + result.stderr.slice(-1500));
  process.stdout.write(result.stdout);
}

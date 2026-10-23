# T3 remaining host seams — narrow static audit

## Scope / confidence

2026-10-17; source-only. Reused supplied extraction provenance: ASAR SHA-256 `b9ec4c2bbc20c9dbc3e39fa4c961434a943434ab0a803052b26753dd15f3b066`, REA evidence `ev_7979e86970c846a799023a9a59149be6c6da854281f49e78a06fc0d627058812`. Provenance is supplied, not newly hashed. No execution/build/install/network/model/live RPC/restart, credentials/liveconfig/personal-state reads, or source edits. This report is the only written deliverable. Supplements, rather than replaces, the [existing matrix](<T3-HOST-CAPABILITY-MATRIX.md>).

**Principal correction:** missing generated Remote ≠ missing engine. The local sidebar plugin already supplies a real host lifecycle service. Queue manipulation and tool invocation also have lower-level engine seams, but those seams are not automatically safe phone APIs. Source registration below means code registers on plugin application; it does not attest personal runtime mounting, activation or transport authorization.

## 1. Thread lifecycle: already provided by custom plugin

[Entrypoint](<../dsh-sidebar-chats/lib/index.js#L1-L2>) reexports host application, not a no-op. [Package](<../dsh-sidebar-chats/package.json#L7-L28>) exports the host and engine; [bundle patch](<../dsh-sidebar-chats/cordis.patch.yml#L1-L7>) inserts `dsh-sidebar-chats` while disabling the original sidebar. The [host](<../dsh-sidebar-chats/lib/inbox-host.js#L158-L174>) requires `storageDomain`, `sessionController`, `workspaceRegistry`, `agents`, `sessions`, `sessionProjections`, `typert`; opens durable domain `thread_inbox_state`, and creates the engine. [Registration](<../dsh-sidebar-chats/lib/inbox-host.js#L206-L243>) constructs a Cordis Service named `threadInbox`, binds namespace `threadInbox`, marks six direct Remote methods, and calls `ctx.plugin(ThreadInboxRemote)`.

No local generated remote-client/host face was found in this plugin's file inventory. That is **not a registration failure**: the current [gateway SRC discovery][GWSRC] scans active Services' `typertRemote` bindings and Remote markers and derives named JSON parameters from function signatures. The methods here have valid identifier-only signatures; `signal` is final/transport-owned. Strict generated descriptors, when present, take precedence; withdrawn strict definitions prohibit SRC fallback. Actual mounting remains unverified.

**Access caveat from current gateway code:** the plugin's Remote markers contain only `{method,invocation}` and no resource readers. [Gateway authorization](</var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-api-gateway/lib/index.js#L1169-L1189>) denies non-owner principals when resource readers are absent (`remote-access/denied`, reason `resource-invalid`). Thus a source-registered `threadInbox` method is not automatically remotely callable by a restricted principal. Whether the custom authenticated phone bridge forwards owner authority or an explicit principal is unverified. Do not solve this by elevating every device to owner: add explicit scoped resource readers/access policy or a narrow bridge authorization layer and filter snapshot/watch output.

### Exact wire methods

All unary requests use business payload `{args:{...}}`. For HTTP, Swift wraps that payload in the carrier described below. No JSON `signal` field.

| Endpoint | Exact `args` | Business result |
|---|---|---|
| `threadInbox/snapshot` | `{}` | `{full:true,epoch:string,revision:number,settings,threads:Record<id,WireRecord>,ready:boolean,capabilities:{lifecycle:true,pullRequests:false,limitResume:false},diagnostics:{storedLogsOpened:number,attachedSessions:number}}` |
| `threadInbox/watch` | `{request:{epoch:string,revision:number}}` | Full snapshot if epoch/revision cannot be bridged; otherwise `{full:false,epoch,revision,settings,threads:Record<id,WireRecord>,ready}`. **Unary long poll**, not a mux stream. Waits up to 20 seconds when current. |
| `threadInbox/apply` | `{request:{commandId:string,epoch?:string,ids:string[],action:string,args?:object,versions?:Record<id,number>}}` | `{epoch,revision,threads,undoToken:string|null,undoExpiresAt:number|null}` |
| `threadInbox/undo` | `{request:{token:string}}` | `{epoch,revision,threads}` |
| `threadInbox/configure` | `{request:SettingsPatch}` | `{epoch,revision,settings}` |
| `threadInbox/preview` | `{request:{}}` | `{autoSettle:number,total:number,days:number|null}` |

Sources: [host methods](<../dsh-sidebar-chats/lib/inbox-host.js#L206-L239>), [snapshots/deltas](<../dsh-sidebar-chats/lib/inbox-core.js#L266-L294>), [commands](<../dsh-sidebar-chats/lib/inbox-core.js#L305-L384>), and [actual web caller](<../dsh-sidebar-chats/lib/client.js#L2784-L2869>). `watch` full responses include capabilities/diagnostics, deltas do not. Full replaces replica, delta merges records. Wrong epoch or stale log window requires full rebaseline.

`WireRecord` always has `version`; non-default fields only: `settledOverride:'settled'|'active'`, timestamps `settledAt/unsettledAt/snoozedAt/snoozedUntil/pinnedAt/lastVisitedAt/returnedAt`, `pinOrderKey/activeOrderKey`, `autoSettleDisabled`, and optional `facts`. Fill omitted lifecycle fields with the [engine defaults](<../dsh-sidebar-chats/lib/inbox-core.js#L25-L73>). Timestamps are JavaScript epoch **milliseconds**, not ISO strings or seconds. Facts deliberately drop internal `generation/nativePinned/live`, null/false/empty-array fields; they are derived, not persisted.

`SettingsPatch` is a partial of `{activated:boolean,autoSettleAfterDays:number|null,autoSettleOnMerge:boolean,snoozeLimitedThreads:boolean,autoResumeLimitedThreads:boolean}`. Defaults: false, 3, true, false, false respectively. Days must be finite 1–90 or null. Configuring activation can immediately initiate observation/auto-settle; it is a mutation, not read-only. PR/limit settings existing in the shape do not override the advertised false capabilities.

### Supported `apply` actions and `args`

| Action | `args` | Important semantics |
|---|---|---|
| `settle`, `unsettle`, `wake`, `unpin` | `{}` | Settle is not archive/delete; wake removes snooze. Unsettle forces active lifecycle. |
| `snooze` | `{until:number}` | Finite future epoch-ms; refuses pending requests or any queued human/automatic work. Does not pause a running engine. |
| `pin` | `{orderKey?:string}` | Reengages settled thread; removes snooze; converges native workspace pin. |
| `reorder-pin` | `{orderKey:string}` | Requires already pinned. Fractional lexical key, not array index. |
| `move` | `{section:'inbox'|'settled'|'pinned',orderKey?:string,orderKeys?:Record<id,string>}` | Settled applies settle checks; pinned accepts per-ID keys; Inbox unpins/unsnoozes/reengages. Not arbitrary queue reorder. |
| `auto-settle` | `{enabled:boolean}` | Per-thread opt-out. |
| `visit` | `{at:number}` | Monotone visited watermark; finite, at most host-now +120,000ms. |
| `mark-unread` | `{}` | Requires completed run; watermark becomes completion minus one. |

Source: [mutation implementation](<../dsh-sidebar-chats/lib/inbox-core.js#L148-L220>), [key generation](<../dsh-sidebar-chats/lib/inbox-core.js#L132-L146>). Keys are lowercase `a`–`z`, nonempty, cannot end in `a`, maximum 2048 characters; use the same midpoint algorithm, not a made-up numeric rank. There is an `activeOrderKey` storage slot but no arbitrary Inbox ordering mutation in this switch.

Command safety: active Inbox required; 1–100 unique thread IDs; commandId nonempty ≤200 chars; IDs nonempty ≤256. Send epoch **and every current version**, although code makes these optional. Command replay uses only a bounded in-memory 256-receipt cache; do not promise durable exactly-once across host restart. Reusing commandId for a different fingerprint conflicts. Whole batch is validated, facts read deeply and rechecked for activity race, then persisted before result. Undo is host-owned, five seconds, version/activity checked, memory-only. Errors are `thread-inbox/<code>`; concrete codes include `inactive`, `conflict`, `busy`, `attention`, `archived`, `subagent`, `not-found`, `invalid-command`, `invalid-action`, `invalid-time`, `invalid-order`, `not-pinned`, `undo-expired`, `disposed`.

[Settle admission](<../dsh-sidebar-chats/lib/inbox-core.js#L107-L129>) refuses running work, queued human input, blocking runtime, unanswered requests and reminders; automatic settlement is stricter. [Native effects](<../dsh-sidebar-chats/lib/inbox-host.js#L133-L155>) can discard automatic wake messages, disarm goals and cancel running subagent descendants while preserving jobs and PTYs. Thus lifecycle operations are genuine mutations, not cosmetic metadata; do not admit them during QAReadOnly. Human input reengages parked threads via [pre-step hook](<../dsh-sidebar-chats/lib/inbox-host.js#L253-L260>).

### Rename/delete/order boundaries

There is **no** `threadInbox/rename`, `threadInbox/delete`, or `apply` rename/delete action. [Bundled web sidebar](<../dsh-sidebar-chats/lib/client.js#L4909-L4912>) delegates Session rename to the native session binding; [workspace actions](<../dsh-sidebar-chats/lib/client.js#L5003-L5008>) delegate workspace rename/delete. Use the existing exact core contracts from the matrix: `session/rename {request:{sessionId,title}}`; `workspace/rename {request:{workspaceId,title}}`; `workspace/delete {request:{workspaceId}}`; `workspace/insertBefore {request:{workspaceId,beforeWorkspaceId?}}`; `workspace/insertSessionBefore {request:{workspaceId,sessionId,beforeSessionId?}}`; pin/unpin `{request:{sessionId}}`. Workspace delete removes a registration, **not files or Session logs**. No hard-delete engine was established in this narrow audit; do not label archive/settle/workspace-delete as Session deletion.

## 2. Phone transport: Swift confirmed; host bridge not in supplied plugin

[NativeGateway](<Sources/NativeGateway.swift#L27-L48>) POSTs `/api/<endpoint>` with JSON, Origin and authenticated cookie, 45-second timeout for Inbox watch, then validates response via native decoder. [Wire](<Sources/Wire.swift#L45-L56>) request is exactly:

```json
{"type":"client-request","rpcId":"<uuid>","method":"threadInbox/apply","payload":{"args":{"request":{"epoch":"<snapshot epoch>","commandId":"<uuid>","ids":["<session>"],"versions":{"<session>":1},"action":"snooze","args":{"until":1792252800000}}}}}
```

The timestamp is only a wire-shape example, not a recommendation or scheduled action. Response carrier is `{type:'server-response',rpcId,result:{ok:true,value:…}}` or `{result:{ok:false,error:{message:…}}}` with matching type/id. Swift currently turns errors into message-only `NativeRPCError`, losing structured host error code; retaining code would permit reliable conflict/inactive handling.

[NativeRPCBody](<Sources/NativeRPCBody.swift#L3-L56>) already supports actual multipart/form-data responses: `metadata` carrier plus `bytes-*` parts; attachment entries `{codec:'bytes',part,path}` address null placeholders in the **unwrapped business result**. It rejects forged JSON `$dshNativeBytes`, duplicates/unreferenced parts, invalid paths, boundaries and non-null placeholders. Caps: 24MiB complete decoded body, 1MiB metadata, ≤16 attachments, ≤32 path segments; bytes are exposed internally as `{$dshNativeBytes:<canonical base64>}`. This tag is phone-internal, not a Host wire format. Native conversion exists; missing host pass-through verification must not be reported as missing Swift bytes support.

[NativeGateway mux](<Sources/NativeGateway.swift#L51-L114>) opens authenticated `/api/remote.mux`, accepts JSON text/data WS frames (16MiB message cap), sends text JSON frames, and rebaselines on malformed/disconnected streams. [NativeStore](<Sources/NativeStore.swift#L262-L299>) emits:

```json
{"type":"open","streamId":"<id>","endpoint":"terminal/attach","payload":{"args":{"agentId":"<session>","id":"<terminal>"}}}
{"type":"item","streamId":"<id>","value":{"type":"write","sequence":1,"data":"<input>"}}
{"type":"cancel","streamId":"<id>"}
```

Auxiliary stream opens are locally restricted to `terminal/attach`, `terminal/retain`, `workspaceFiles/changes`, `job/list`, `job/follow`. Uplink requires connected foreground current-generation terminal/attach subscription, write/resize discriminator and nonnegative integral sequence. This is a **phone client guard**, not host authorization. Downlink and terminal backpressure/acks still need host end-to-end verification under separately authorized QA.

[DesktopStore](<Sources/DesktopStore.swift#L36-L88>) already calls Inbox snapshot/watch. No lifecycle mutation calls were located by the targeted Swift `threadInbox` search; adding `apply/undo/configure/preview` callers is phone wiring, not new engine work.

**Host-source limitation:** the supplied [dsh-mobile-ux host entry](<../dsh-mobile-ux/lib/index.js#L1-L2>) is literally `export function apply() {}`. Its [package](<../dsh-mobile-ux/package.json#L6-L19>) declares mobile presentation and web client injects. [Controller](<../dsh-mobile-ux/src/controller.js#L1-L18>) is a DOM presentation adapter and [guard](<../dsh-mobile-ux/src/guard.js#L1-L18>) is a drawer hit-test/integrity guard, not a security/RPC gate. Bounded searches of this plugin, including generated client, found no `BridgeRPC`, allowlist, multipart, or uplink implementation. Therefore the actual host BridgeRPC allowlist, authenticated HTTP multipart pass-through, mux item acceptance and QAReadOnly enforcement are **unverified/unlocated in the named source**, not shown absent from the running product. Obtain the exact bridge host source path; do not inspect liveconfig/credentials or substitute runtime evidence.

## 3. Queue: lower-level engine exists, but no safe reorder/hold API

Current [Session controller][QUEUE] exposes edit/remove/steer, locates IDs in next-turn/next-step, enforces subagent ownership and text-only nonblank edits. Cold edits may resolve/resume an Agent. Steer specifically removes from next-turn then calls agent.steer while running. Remove retires prompt upload authority when appropriate. Cancel uses `keepInbox:true`. These are existing operations, not missing engine.

The concrete [ReactLoopInbox][INBOX] exposes instance methods/getters `nextTurn`, `nextStep`, `hasPending`, `clear`, `claim`, `append`, `prepend`, `replace`, `remove`, `splice`, `locate`, `current`, `mutate`. It reconstructs pending messages from durable `agent/inbox/spliced` events. There is no move/reorder/hold/resume command in that class. The class is internal implementation (do not presume a package named export), but is attached as `agent.inbox` by the loop constructor.

**Critical: splice is not a safe reorder primitive.** [Mutation][MUTATE] checks unique IDs against both lists, appends durable splice, and when deleting anything through public splice sets `outcome:'canceled'`, emits `agent/inbox/discarded` for every removed item and `inserted` for replacements. Whole-list replacement with the same IDs may preserve the final projection but fabricates cancel/discard/reinsert lifecycle. Remove/re-add through prompt also changes identity/receipts. Do neither to implement reorder. Even `replace` uses these splice semantics; do not extrapolate existing edit behavior into safe bulk reorder guarantees.

Hold is not achieved by cancel: [driver][DRIVER] has followup/steer/inject/send wake logic and cancel with optional retained Inbox; no durable held state. [preStep][PRESTEP] **claims/removes pending messages before** invoking `agent/pre-step`. A plugin rejecting at that hook cannot guarantee queued IDs remain pending. The existing settled-thread hook is not a generic hold API.

### Minimal genuine queue adapter (proposed, NOT available wire methods)

1. Add driver-owned atomic reorder command/event, e.g. `queue/reorder {request:{sessionId,target:'next-turn',itemIds:string[],expectedAsOfSeq:number,commandId:string}}`. Validate allowed Session, exact same pending ID multiset, no duplicates/missing/already-claimed entries; serialize at the loop's claim boundary and CAS. Emit a move/permutation event that preserves message identities, receipts and authority, without discard/claimed notifications. Teach durable fold and live projections the event. Return `{accepted:true,asOfSeq,queue}`. Restrict first version to next-turn; cross-lane steering remains existing explicit operation.
2. Add durable `queue/setHeld {request:{sessionId,held:boolean,expectedAsOfSeq:number,commandId:string}}`; enforce admission before claim and before queued turn start, including cold resume, maintenance replay and automatic wakes. State whether current turn continues or an explicit cancel is separately requested. Resume clears hold then invokes a supported driver wake without generating a synthetic message. Project held state. Do not call private wakeDriver by reflection from a phone plugin.
3. Local not-yet-delivered outbox editing can hold in Swift without host support; do not claim this holds already accepted Host occurrences. Advertise reorder/hold false until actual driver semantics are implemented.

## 4. Git / PR / structured invocation seams

Bounded current-source search across extracted `@deepseek-ai` JavaScript entrypoints found Git use in [workspace changes][CHANGES], not a dedicated Git/PR Remote. That recorder uses argument-vector Git operations for snapshot trees/diffs; its internal scratch-index machinery is not a generic repository management API. No structured `pull_request`/`pullRequest`/`gh pr` implementation was established by this search. This says nothing about installed external providers, credentials or personal runtime tool registration.

There **is** a structured same-process tool engine: [registry][TOOLS] exposes scoped schema views and `execute(exec)` with `name`, JSON `arguments`, `callId`, required cancellation signal, optional Agent/scope and correlation fields. The [pipeline][POLICY] executes pre-policy/ask, guards, around-dispatch, post-policy and finalization; definition `tool.execute` is called only inside that pipeline. Visibility/PTC collapse applies. Do not expose arbitrary `tools.execute` or claim it is an existing phone Remote. Do not bypass policy by calling raw definition callbacks or forging a nested parent token to defeat PTC visibility. A phone integration also needs scheduler/correlation and durable audit ownership, not merely an execution callback.

There **is** an existing generated [dynamic host invoke face][DYNAMICFACE]:

```text
dynamicCordisRunner/invoke
args = {pluginId:string, pluginRunId:string, method:string, args:JSON}
result = {ok:true,value:JSON}
       | {ok:false,code:'plugin-not-running'|'stale-run'|'method-not-found'|'handler-error',message:string,stack?:string}
```

The [implementation][DYNAMIC] checks active plugin/run and registered handler; `harness.handle(method,fn)` registers JSON-normalized handlers. This makes an approved dynamic plugin a possible transport seam, **not evidence a Git handler exists or that pluginId is an authorization boundary**. Outer RPC success can contain inner `ok:false`; decode both. Its [sandbox tool facade][SANDBOX] intentionally exposes only `register`, `schemas`, and schema-only `get`, never executable tool definitions. Do not prescribe dynamic code reaching `ctx.tools.execute`; this facade does not support it. A trusted static narrow service could own an explicitly scoped execution capability, or a dynamic handler can use an explicitly injected, policy-aware narrow repository service, if one is added.

### Minimal repository adapter (proposed, NOT available methods)

Expose a versioned `mobileRepository` service with capability discovery and typed methods rather than generic terminal/command strings:

- Local reads: status, branches, bounded diff `{sessionId,base?,head?,paths?,cursor?}` → typed repository identity/head/index/worktree version, file statuses and hunks/refusals. Resolve canonical repository/worktree from allowed Session; never accept arbitrary host cwd, executable, environment or Git options from phone.
- Local writes: stage/unstage/commit/switch/worktree-create with exact typed arguments, expected HEAD/index version, idempotency commandId, explicit effects/confirmation, normal sandbox and approval policy. No shell interpolation, arbitrary hooks/config execution or auto-fetch disguised as read-only.
- Remote PR/review operations: typed provider capability and identity, PR list/get/comment/create/merge actions, separately authorized network and destructive operations; resolve secrets on Host, never return them. Capture actor/operation audit. Map conversation↔repository/worktree↔PR explicitly; only then advertise `pullRequests:true` for inbox auto-settle. A Session fork remains a conversation fork, not repository/worktree fork.
- Implement behind an existing authorized structured provider or policy-aware tool runtime where actually composed. If unavailable, report capability false. Never use terminal/create as a hidden unsandboxed Git escape hatch; never trigger a model prompt to impersonate a deterministic button action.

## 5. Safety / completion checklist

- **Answered:** local lifecycle service registration and mutation payloads; real rename/workspace deletion boundaries; Swift carrier/multipart/uplink emission; lower Inbox methods and unsafe-reorder side effects; structured tool and dynamic-handler engine seams.
- **Partially answered:** Git/PR absence is bounded to inspected source/Remote faces, not external tool availability. Proposed adapters have not been implemented or tested.
- **Unresolved:** actual Host BridgeRPC source/allowlist, authenticated multipart pass-through, mux uplink acceptance, security enforcement and runtime mounting. The named presentation plugin does not establish these. No personal runtime inference.
- At every bridge ingress authorize nested IDs to allowed workspace/session/terminal before forwarding. Filter global baseline **and delta** streams and Inbox snapshots/watch by authorized IDs. Cap body/output/time budgets. For isolated QA, never send production snapshots, preview/deep reads or unrelated snippets.
- Enforce QAReadOnly server-side for unary, stream-open, stream-item and HTTP/media; client booleans are insufficient. Deny every lifecycle/config mutation, queue mutation/resolve side effects, terminal ownership/create/uplink, Git writes, provider/network calls and dynamic invocation unless a specifically allowlisted fixture-only read handler is proven safe. This audit invoked none.
- Prioritize: (1) locate bridge source and verify its exact whitelist/carrier handling; (2) wire existing lifecycle actions with epoch/version/idempotency and capability handling; (3) add true driver reorder/hold semantics; (4) add explicit repo/provider adapters. Do not reimplement existing lifecycle engine or fake missing queue operations.

## Extracted source references

Temporary extraction paths below identify supplied static source, not live application configuration.

[GWSRC]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-api-gateway/lib/index.js#L1225-L1300>
[QUEUE]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-api-session-controller/lib/index.js#L1000-L1066>
[INBOX]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js#L14-L178>
[MUTATE]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js#L179-L207>
[DRIVER]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js#L780-L869>
[PRESTEP]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-agent-loop/lib/index.js#L887-L926>
[CHANGES]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-workspace-changes/lib/index.js#L280-L394>
[TOOLS]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-tools/lib/index.js#L3115-L3269>
[POLICY]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-tools/lib/index.js#L3320-L3428>
[DYNAMICFACE]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-cordis-host-runner/lib/typert.remote-client.js#L449-L530>
[DYNAMIC]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-cordis-host-runner/lib/index.js#L2110-L2147>
[SANDBOX]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-cordis-host-runner/lib/index.js#L570-L584>

# EXCLUDED — user explicitly removed Git and PR from scope

User decision: **leave Git/PR out**. Stop repository feature work. Do not integrate, mount, activate or deploy this adapter. The iPhone app excludes all repository/Pulls source and tests. The following is historical staged work only, not a remaining product requirement.

# Native repository adapter contract v1 (historical; not deployed)

Namespace `mobileRepository`; unary business payload `{args:{request:{...}}}` inside existing Wire carrier. Every request includes `sessionId`. Resolve root from that authorized Session's header, never phone-supplied cwd or command. No Agent resume/model/provider discovery. All reads must suppress external diff/textconv/fsmonitor execution; mutations/network only explicit UI confirmations. Fixed executable/argv, no shell or terminal fallback. Per-repository serialized mutations, fresh `version` comparison, immutable `requestId`, payload fingerprint. Durable completed/pending operation ledger; ambiguous pending writes are NEVER replayed automatically. Fixture services never invoke the production transport/process/GitHub or personal repositories.

## status

`status({sessionId})` returns:

```
{sessionId, version:string, rootLabel:string, head:string|null, branch:string|null,
 files:[{path:string,oldPath?:string,status:"modified"|"added"|"deleted"|"renamed"|"untracked"|"conflict",staged:bool,unstaged:bool,added:number|null,deleted:number|null,binary:bool}],
 branches:[{name:string,current:bool,remote:bool}],
 worktrees:[{path:string,branch:string|null,head:string,current:bool,locked:bool}],
 github:{owner:string,name:string}|null,
 capabilities:{git:bool,github:bool,worktrees:bool,writes:bool}}
```

No raw credential-bearing remote URLs. `version` binds actual content/index/HEAD snapshot, not just an unchanged porcelain M flag. Reject oversized/unverifiable snapshots for write authorization, do not call them clean. Relative literal paths validated at Host, no escapes/symlink outside root. Git flags protect against option/pathspec injection. Repository root must be within authorized workspace or require an explicitly stronger authorization, never silently expand root.

## diff / mutate

`diff({sessionId,version,path,staged:bool})` -> `{sessionId,version,path,patch:string,binary:bool,truncated:bool}`. Unified patch capped and honestly marked; includes source identity. No fake workspace/changes seq for Git diffs.

`mutate({sessionId,version,requestId,action,...fields})` -> `{accepted:true,snapshot:Status,worktreePath?:string}`.

Actions: `stage|unstage` fields `paths:[string]`; `commit` fields `message:string,runHooks:bool` (explicit UI choice, no silent hook execution/bypass); `createBranch` fields `name:string,base?:string`; `switchBranch` fields `name:string` (never discard dirty files); `createWorktree` fields `name:string,base?:string` (server-managed destination only, no arbitrary phone path); `removeWorktree` fields `path:string` previously listed, no force; `fetch|pull|push` no raw remote/command fields, confirmed network action and no force. Invalid action must reject, not approximate it with a different operation. Git itself may refuse conflicts; retain state and expose error safely. Reads do not auto-run any of these.

## pull requests

**Integration tightening (authoritative):** `PullSummary.head` is the immutable 40/64-hex commit SHA, NOT a branch name; `headRef` may additionally carry its display branch. `base` remains a branch ref. Every `pullMutate` request MUST include captured `version`, `repository:{owner,name}` and `expectedHead` (SHA). Existing-PR writes use the returned PR head SHA; create uses local snapshot.head SHA and its explicit `head` input is a branch ref. Validate repository identity and preconditions before any write. Reviews bind API commit_id to that SHA; merge uses GitHub's atomic SHA precondition. Plain comments/PR creation only offer head preflight where GitHub lacks an atomic CAS—do not claim atomic remote CAS, and disclose/retain the captured revision on a racing result. Unknown or non-SHA heads disable writes rather than guessing.

`pulls({sessionId,state:"open"|"closed"|"all",limit:number})` -> `{sessionId,repository:{owner,name},items:[{number:number,title:string,state:string,draft:bool,author:string,url:string,head:string,base:string,updatedAt:string}],hasMore:bool}`. GitHub hostname fixed to github.com unless separately authorized configuration; native UI never follows arbitrary Host-provided URLs.

`pull({sessionId,number})` -> `{sessionId,repository:{owner,name},item:PullSummary,body:string,files:[{path,status,added:number,deleted:number,patch:string|null}],comments:[{id:string,author:string,body:string,createdAt:string}],checks:[{name:string,state:string}],mergeable:string}`. Fields may be empty only when genuinely empty; unsupported/unavailable must error honestly.

`pullMutate({sessionId,requestId,action,number?,...fields})` -> `{accepted:true,number:number,url?:string}`. Actions: `create` fields `title,body,head,base,draft`; `comment` fields `number,body`; `approve|requestChanges|reviewComment` fields `number,body`; `merge` fields `number,method:"merge"|"squash"|"rebase",expectedHead:string`. Safe CAS for remote PR mutation needs expected PR/head identity; backend may require more preconditions and must document additions in this contract before client mutation is enabled. No automatic merge/approval/comment creation or provider credential discovery. Writes require durable idempotency/ambiguity handling, even when local Git status is unchanged. Never return auth tokens. Missing GitHub CLI/account is a capability error, not fake empty PR results.

## errors / lifecycle

Stable codes `repository/unavailable`, `repository/conflict`, `repository/invalid-request`, `repository/permission`, `repository/uncertain`, `repository/too-large`, `repository/auth-required`; scrub stdout/stderr credentials, bound user-visible errors, do not log payloads/tokens. Native controls can show capability/setup explanation while staged adapter is not mounted, but must not invent success. User owns activation/restart; do not alter the running bridge/profile as QA.

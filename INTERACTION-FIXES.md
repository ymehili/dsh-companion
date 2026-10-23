# Steering, questions and JEV interaction fixes — work in progress

## Reported behavior

The user reported forced queueing on iPhone, missing agent questions and JEV Auto apparently pausing after phone use. These now take priority alongside the selected refined Mac-style sidebar.

## Phone transport changes

- Prompt mode is captured with the immutable PendingPrompt: **steer when running; queue admission when idle**, matching the Mac submit contract. Explicit retry retains the exact original mode/request ID/content. This is not an instant kill: host steering is admitted at a step boundary; an already-ended turn can admit it on the next turn. Stop remains separate. Existing queued messages are not moved, duplicated or replayed automatically.
- The old iPhone had no `user-questions/request` handler. Native question cards/forms now parse the canonical service fields (including camel-case `multiSelect`), show single/multiple/custom choices without preselection, and require a complete validated answer batch.
- Live answers use `$events/result` for the exact event/client. Continued answers use `userQuestions/answer` for the exact owning agent/call, independent of the selected chat. They are not generic chat prompts.
- Timed question waits attach only while the form is visible and release on exit. Cancellation/removal is authoritative. Failures retain form choices and show a scoped retry error. Accepted continued replies are locally hidden while awaiting admission.
- Unsupported waterfalls delegate with `kind:next` instead of silently holding the Mac's chain. Backgrounding delegates unresolved live questions, without answering them or changing the Mac agent/model. Reconnect/question lifecycle and global/sidebar discoverability remain under regression review.

## Evidence

Current shipped Host contract was extracted with REA CLI after MCP analysis/extraction timed out. Evidence identity is retained in the workspace extraction receipt. Source-confirmed API: `@deepseek-ai/dsh-user-questions`, direct answer args `{agentId,callId,answer:{answers}}`, attachWait stream args `{agentId,callId}`, boolean continued-answer result, plus the existing `$events` waterfall result channel.

The new **5 interaction unit tests passed**, together with the existing 18 (23 total): running steer with identical retry, idle queue admission, live answer failure/retry + claim cancellation, continued reply to an unselected session, and background delegation. UI and full regression runs are still in progress; do not treat unit success as on-device release proof.

## JEV

A separate audit found a same-step stale model-selection snapshot on provider retry can falsely trigger JEV's manual takeover logic. This also appeared with Mac-style IDs; client attribution by UUID casing is heuristic. Phone viewing does not call JEV enable/disable or model selection. Explicit model selection is still a genuine override and must remain respected.

The reviewed patch and 51 isolated passing tests are documented in the JEV plugin's retry-fix note. It is staged in the existing desktop plugin, with the old module backed up. **The running DSH process was not restarted/reloaded, so activation is not claimed.** No auto re-enable, global default change, provider fallback, real model request or approval decision was performed. A coordinated reload/restart remains necessary.

# Sidebar correction, 0.4

## User's reference

A flat Mac DSH rail: leading whale/wordmark, full-width New Session, inline search, workspace/title/status rows, subtle selected fill, compact Working/Settled disclosures and a bottom footer. iPhone adaptation must retain this appearance while keeping Apple's native navigation and gesture mechanics. Plugins and Automation tasks remain omitted, per the user's earlier request.

## Root cause of the inflated Inbox

The previous native model discarded `session/list`'s `blank` property and never subscribed to `workspace/follow`. That separate core workspace feed carries `archivedSessionIds`, `pinnedSessionIds` and the workspace title/membership registry.

Consequently, blank sessions and archived sessions—especially archived entries absent from the Inbox plugin snapshot—were passed through the default `record == nil → inbox` classification. Reading the same Inbox snapshot was not sufficient to reproduce the Mac's UI.

Mac source `sessionVisible` first excludes subagent children, non-current blank sessions and the registry's archived IDs. Only then does ThreadInbox derive its record/facts and classify the remaining rows. Native now uses that same ordering and the same missing-facts/pinning/pending-request fallback semantics. Existing facts do not silently inherit a different running flag from the session summary.

## Live, read-only verification

Captured actual session summaries, an Inbox snapshot and the workspace baseline. The Swift implementation and Mac JavaScript rules compared **the exact session-ID sets** for every shelf in memory; no private IDs or conversation text were logged.

Observed result at that capture:

- Inbox: **6** on both implementations.
- Working: **2** on both.
- Settled: **931** on both.
- Exact shelf membership equality: **true**.
- Workspace archive registry: 298 IDs; ordinary blank sessions: 56.

The user's earlier screenshot shows 5/2/931. Counts can change as conversations start/finish; the implementation does not hard-code five. The parity check proves identical classification for shared captured inputs, not a claim that an old screenshot's counts never change.

The regression fixture reconstructs the reported magnitude: 5 real Inbox entries + 56 blank entries + 223 archived entries without Inbox records would previously produce **284**. Correct visibility yields **5**, with 2 Working and 931 Settled. Fixture titles/data are synthetic, not copies of the user's private session titles.

## Implementation boundaries

Workspace follow is read-only; no archive, pin, settle, workspace or account mutations were invoked. Membership isn't guessed from recency. Counts remain unknown until both visibility and Inbox data are available; cached last-good data remains usable across interruptions. Sending is unavailable while visibility is unknown or the selected session is archived.

The Mac's workspace UI filter is a client-local selection. The supplied screenshot contains several workspaces and the default all-workspaces/default archive view is the target here. Native uses the same default visibility; it does not alter the Mac's UI selection or preferences. A current blank placeholder can legitimately differ between clients that are viewing different new-session placeholders.

The footer displays the Mac connection rather than fabricating an account identity. DSH branding/flat row styling are app-specific SwiftUI composition; List, NavigationLink, TextField, Button, DisclosureGroup and the edge-back navigation remain native.

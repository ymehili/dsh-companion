# Refined Mac-style iPhone sidebar — 0.6

The user explicitly selected **Refined Mac-style sidebar**, not ChatGPT history. The initial rendered refinement was shown in light/dark modes, then the user clarified that **Working and Settled must stay at the bottom**, like the existing Mac UI.

## Existing Mac implementation inspected

The installed/custom sidebar source represented in `dsh-sidebar-chats/lib/client.js` uses a flex-column Inbox root with `margin-top:auto` on its tail/Working shelf, and a growing scroll body. That pushes lower shelves down when Inbox content is short; it is not merely a section appended immediately after Inbox.

For phone, the new native layout reserves a bottom shelf dock above the compact connection footer. Pinned/Inbox retain the main native List. Working/Snoozed/Settled have fixed visible disclosure headers; expanded contents use bounded independent native Lists, so a long Inbox cannot scroll away the lower headers and expanding a large Settled shelf cannot consume the entire screen. Search temporarily presents matching shelves together in the main List; normal docking resumes when search clears. Counts, filters, archived/blank visibility and sorting remain host-backed and unchanged.

## Presentation

- DSH wordmark retained at a phone-appropriate width.
- Native New Session action no longer uses a large gray bordered slab.
- Neutral bounded native search with 44pt clear target.
- Title-first rows, smaller workspace metadata and quiet completed checkmarks; meaningful running/failed/input/approval state remains labeled and accessible.
- Subtle selected tint, flat rail, no per-row card UI.
- Single-line Mac connection footer retaining pairing, approvals and question access.
- Native NavigationSplitView/NavigationLink/back mechanics; no root custom gesture.

The first combined run passed 49 unit/UI cases including native questions/steer. Two focused dock renders passed and were inspected. A new long-Inbox dock-position/navigation test has executed and passed in the final full run; complete final counts and installation are recorded when that run ends.

All previews use synthetic conversations. Private user screenshots/session transcripts were not copied into UI fixtures.

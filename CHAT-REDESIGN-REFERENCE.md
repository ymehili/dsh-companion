# Chat redesign reference — evidence before implementation

## User request

Replace the current poor chat presentation with a detailed ChatGPT **iPhone** reference-based design. Preserve DSH's Mac-style sidebar, fixed visibility/data parity, backend operations, outbox/retry safety, multi-photo support and permissions. Do not silently replace these with a web view or fake ChatGPT capabilities.

## Reference identity and observations

Official Apple listing: https://apps.apple.com/us/app/chatgpt/id6448311069

Apple's public lookup metadata: https://itunes.apple.com/lookup?id=6448311069&country=us

Listing observed in this session: version 1.2026.272. Eight official iPhone marketing screenshots were downloaded into the ignored reference directory. Seven chat-related screens were visually inspected; the voice-specific screen is not a requirement to invent a DSH voice implementation. These are official marketing compositions, not a live recording of the user's installed app.

Observed across the chat screenshots:

- Uncluttered reading canvas. No permanent Chat/Trajectory segmented toolbar or engineering status bar occupies the top of the conversation.
- Compact top navigation: sidebar affordance on the left; new-chat/overflow controls on the right. No oversized truncated conversation title across the center.
- Right-aligned rounded user bubbles; shown light-mode examples use pale blue fill and blue text. Assistant prose is unboxed and has consistent readable gutters, paragraph spacing and list hierarchy.
- User image attachments are displayed as rounded media separate from the text bubble, not as filenames pretending to be a full image experience.
- A **single floating rounded composer capsule** near the bottom, with plus, inline placeholder/text and trailing actions. It is not a rectangular TextField stacked over model, permissions, task and send bars.
- Composer surface is subtly material/shadowed; chat content may continue behind it with an appropriate bottom reading margin.
- Assistant message actions form a restrained small icon row below the response. The references show copy/audio/rating/regenerate/share; DSH must only expose supported actions, not fake rating/voice/regenerate behavior.
- Task/goal details and tool call/result logs are not permanently interleaved as prominent blue chat rows in the reference. DSH needs quiet activity summaries with a secondary detailed surface.

## DSH adaptations, not observed ChatGPT facts

- Keep native navigation/edge-back to the existing Mac-style sidebar, rather than reintroducing global custom drag recognition merely to imitate a hamburger icon.
- Keep DSH branding, backend model/provider identities and real permission state. Show configuration/status through a deliberate secondary surface instead of a permanent composer dashboard.
- Retain Trajectory, tasks/goals, tool details, stop and approvals in accessible secondary controls. Running work and pending approval must remain discoverable, not hidden for cosmetic parity.
- Keep ordered multi-image picking, additive batches, per-image removal and retry identity. Redesign previews as compact items integrated with the composer, not a tall strip with a separate row of oversized red delete controls.
- Use supported Copy/Share/Select Text actions. Do not add nonfunctional voice, feedback or regeneration buttons just because the reference contains them.
- Safety warnings (offline/uncertain delivery/approval) remain real and scoped. No visual cleanup may remove the operator's ability to stop a running Mac agent.

## Not yet observed — needs user reference or live inspection

Marketing images do not establish the exact keyboard-open layout, long/multiline editing transitions, attachment menu and selected-preview states, streaming behavior, scroll anchoring, selection/long-press menu, edit/regenerate semantics, errors, offline states or dark appearance in the user's installed version. A short user-supplied iPhone recording or screenshots was requested for these. Do not label approximations as a pixel-perfect/live-app reproduction.

## Process change

Create a reference-based rendered prototype and compare it before another installation. Automated protocol counts alone are not a UX acceptance criterion. Required comparison states: empty chat, short/long response, keyboard open, multiline draft, two/three attachments, streaming, scrolled-up with new tokens, pending approval, error/retry and dark appearance. Preserve the existing sidebar and transport tests.

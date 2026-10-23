# Chat 0.5 prototype — not installed

The phone remains on the verified 0.4.1/build-7 release. The working project is now 0.5.0/build 8 **prototype**, based on the official iPhone references described in CHAT-REDESIGN-REFERENCE.

## Implemented presentation changes

- Removed the permanent Chat/Trajectory segmented control from the primary conversation.
- Replaced the multi-row composer dashboard with one floating material capsule containing plus, multiline input and send/stop. Removed permanent task/goal, model and permission rows from the composer.
- Model choice, session configuration, permissions, tasks/goals and approvals remain in the session menu/details. Activity/Trajectory is a separate read-only sheet; it does not mount another composer.
- Tool events remain in the reducer and activity history, but adjacent tools now have a quiet neutral activity entry in the conversation instead of nested blue per-event disclosures.
- Added actual Copy/Share response actions. No fake rating/voice/regeneration controls.
- Compact photo previews are integrated into the capsule with corner removal controls. Ordered multi-select, additive batches, per-image removal, generation guards, sequential preparation and immutable retries remain.
- Existing native sidebar/detail routing, Mac sidebar appearance/visibility registry, stream reducer, backend, pairing, permission policy and tunnel were not redesigned.
- Removed the extra keyboard toolbar Done row; native interactive scroll dismissal docks the composer directly above the system keyboard.

## Evidence so far

The first prototype compiled and passed 15 scripted store tests and two new UI prototype cases. Actual rendered screens were reviewed in light/keyboard/dark-two-photo states. This is **not** a claim that the old full UI suite passes unchanged: tests that expect the old segmented tabs/model footer need migration, and broader new-layout regression cases remain.

Visual review caught the extra keyboard toolbar gap and transparent one-pixel fixture thumbnails; these were corrected. Synthetic photo fixtures are now labeled colored JPEGs rather than blank pixels. Removing the keyboard toolbar initially exposed a scroll-dismissal failure; focus is now released when the native scroll phase becomes interacting (not on a custom drag/tap). Prototype render 3 passed all 15 store cases and both UI cases, including keyboard dismissal, compact surface geometry, activity access and per-photo removal. Light keyboard and dark two-photo renders were inspected. No prototype has been installed on the physical phone.

## Remaining before release

- The user reviewed the prototype and explicitly selected **Continue refining this direction**. Captures of their actual ChatGPT iPhone version remain useful; marketing screenshots do not establish all interactions.
- Refine typography, gutters, user-bubble treatment, header affordances and activity/thinking density against those references. Keep DSH identity rather than misbrand the app as ChatGPT.
- Historical image refs are now parsed and integrated as authenticated media cards using the source-confirmed session/attachment RPC, bounded off-main decoding and authorization-epoch/session-scoped memory caching. Decoder rejection tests and 116 pure checks pass; real-card loading/error/cache UI integration tests and full-screen viewing remain to verify/implement.
- Rich partial text selection/message menu, live reasoning/streaming, pending approvals/stop discoverability, errors/delivery uncertainty, multiline keyboard resizing, history anchors, dark/accessibility and photo picker regressions require further verification.
- Remove unused old inline-trajectory/pane code after the replacement presentation is finalized.
- Show the rendered prototype before installation; do not install another unreviewed redesign automatically.

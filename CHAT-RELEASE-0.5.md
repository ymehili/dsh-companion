# Chat redesign 0.5.0 / build 8

## Reference and review

The user asked to replace the previous console-like chat with ChatGPT iPhone's UI. Official iPhone screenshots were reviewed first, then the user supplied four actual dark-mode/keyboard/conversation screenshots. The user viewed the first rendered prototype and chose **Continue refining this direction**. The supplied private screenshot contents/account suggestions were not copied into fixtures or source archives.

Chat-only styling now follows the observed black canvas, dark-blue user bubbles, compact response actions, floating header/new-session/overflow controls and centered latest-message affordance. The composer is narrower/single-row while idle and expands to a wider two-row input/control layout when focused or holding a draft/photos. The same native TextField preserves focus/editor identity across the layout change. The system keyboard/language remains the user's setting.

Permanent Chat/Trajectory, goal/task, model-name and permission footer bars are removed from the conversation/composer dashboard. Model/configuration, Activity/Trajectory, session details, tasks/goals, permissions, approvals and Stop remain real accessible DSH controls, not deleted functionality. The existing Mac-style sidebar and exact session visibility/membership rules remain unchanged.

## Media and actions

- Multi-photo ordered picking, additive batches, session-specific drafts and per-photo removal remain; previews use compact corner controls inside the composer.
- Historical media uses the canonical attachment descriptor and authenticated `session/attachment` RPC. The Mac verifies the attachment belongs to the addressed durable session. No guessed filesystem paths or arbitrary Markdown image URLs are loaded.
- Returned ID/type/bytes/dimensions and actual image type/pixels are checked. Decode/downsampling is off-main; thumbnails are bounded, memory-only, keyed by authorization epoch + session + attachment ID. Device reauthorization rotates the epoch. No user photo/credential is logged or persisted by this cache.
- Copy, native Share and a read-only native text-selection sheet are implemented. Selection does not edit a draft or open a keyboard. The selection sheet currently shows original text/Markdown, not a duplicate rich Markdown editor.
- Stop is directly available for a running agent with an empty composer, and always available in session actions while running. Typing a queued draft does not remove the menu Stop action. The tap captures stop/send intent and send photos before the asynchronous action begins.

## Verification

- **116 pure Swift checks** passed, including canonical image descriptors, duplicate-ref content identities, nested names/dimensions, no URL-to-ref conversion, archive/blank visibility, ordered photo retries and security/rendering tests.
- Complete simulator suite: **18 unit/store/image tests + 23 UI tests = 41**, zero failures.
- The actual Apple picker selected two photos and then appended a third in a later batch. Native back/cancel, keyboard/focus, drafts, scroll-follow recovery, sidebar 284→5 visibility regression, markdown/code, loading/offline/uncertain delivery and model/trajectory navigation remained covered.
- A dedicated offline RPC fixture exercised the actual historical-image loader: first request failed, explicit Retry succeeded, and the canonical metadata/base64 generated a visible 320×220 image card. It did not use a real Mac/model or personal image.
- Actual light/keyboard/dark-attachment and historical-image renders were exported and inspected. A prior model-menu UI test was ambiguous after the composer gained a second model entry; the session menu received a stable accessibility identifier and the complete run passed afterward.

## Explicit differences / remaining boundaries

This is a reference-based DSH adaptation, not a claim that every ChatGPT product behavior is copied. Native back retains its system back affordance rather than changing global navigation gestures to imitate the menu icon. The start-screen Chat/Work modes, voice, ratings, connected-account suggestions and source cards are not fabricated. DSH-specific activity/permissions/model/approvals remain in its own surfaces.

Historical images currently display bounded thumbnail cards (GIF first frame); full-resolution zoom/download/share-original is not implemented. The transport materializes the authenticated RPC JSON before per-image validation; a transport-wide streamed response cap is not introduced here. Full-screen image presentation, date/time separators, full Markdown selection parity, rich source/citation rendering and broad Dynamic Type/VoiceOver/rotation review remain future refinements. No real model prompt, approval or model change was executed during these tests. The user must still assess physical-device feel and real provider uploads.

Drafts, selected photos and uncertain outbox payloads remain memory-only across app termination/update. Mac/tunnel/DNS/provider/permission configuration is unchanged. Existing pairing and bundle identity are retained.

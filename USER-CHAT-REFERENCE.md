# Actual user-provided ChatGPT iPhone reference

The user supplied four screenshots after reviewing the initial prototype. These supersede generic App Store marketing shots for dark appearance and composer geometry. Private screenshot/chat/account contents are not copied into source fixtures or distributable archives.

## Directly observed

- Pure black chat canvas, not the prototype's dark gray DSH canvas.
- Dark saturated blue right-aligned user bubbles, white/off-white text; assistant answers are unboxed with compact gray action icons underneath.
- Unfocused composer: narrow floating single-row capsule, about 34pt horizontal insets on a 390pt-wide phone, plus on left and trailing actions on right.
- Keyboard-focused composer: wider rounded rectangle, about 12pt outer insets, text entry on an upper row, plus and trailing controls on a lower row. The initial one-line-only prototype is insufficient.
- Composer moves directly above the system keyboard with no extra floating Done-toolbar row. Return is a newline-style key in the reference. User keyboard happens to be AZERTY; app must respect the system/user keyboard, not hard-code language or key arrangement.
- Conversation header has floating left sidebar control and a shared right capsule with new-chat and overflow. The Chat/Work segmented control is shown on the empty/start screen, not inside the supplied existing conversation; do not restore the old always-visible DSH Chat/Trajectory strip by mistaking these for the same semantics.
- Jump-to-latest is a small circular down-arrow centered just above the composer.
- Response actions include copy/share/more. Screenshot with Copy state shows a compact confirmation near the header. Provider-specific ratings, sources, voice and account-connected suggestion cards are not evidence that DSH implements those features.
- A date/time divider separates later conversation activity. Image content is rendered as media cards, not filenames.

## Adaptations

Use DSH's actual model/configuration, send/queue and stop actions in place of unsupported ChatGPT tools; no pretend microphone/voice/rating actions or copied connected-account suggestion cards. The installed Mac-style sidebar/data membership stays unchanged. Retain native edge-back mechanics; its back affordance can differ from ChatGPT's menu icon if changing it would break interactive native navigation.

## Implementation begun

A chat-only palette now isolates the observed black/deep-blue appearance from sidebar colors. A custom SwiftUI **Layout** positions the same native TextField and Buttons in compact/expanded arrangements, preserving editor/focus identity; this is layout composition, not a custom text editor or pan gesture. Model controls appear only in the expanded action row. The latest-message affordance moves to the center. Header gains the actual New Session action alongside overflow and removes the truncated large title.

Still requires rendered comparison and regression checks for editing/focus transitions, multiline height, attachments, tool/model selection, native back, loading/offline, running stop/queue and authentication-scoped historical media. These notes are observations/design requirements, not a declaration that all visual details are already reproduced.

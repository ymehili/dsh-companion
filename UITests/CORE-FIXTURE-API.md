# Selected core UI fixtures (Lead handoff)

- All launches MUST include `-native-ui-fixture`.
- `-native-photo-import-fixture`: Attach photos is a DEBUG-only synthetic transfer button (same AX label). First tap imports two newly rendered test JPEGs through actual `NativeStore.importPhotos`; second imports one more. Transfer loaders are async and store/session-owned. No Photos library read. Focus nativeComposer to expand 72pt photos; `attachment-count` reports 2/3 photos attached. Remove IDs stay `remove-photo-0`, etc. This replaces unowned personal Photos-gallery selection, not production PhotosPicker (unchanged when this explicit flag is absent).
- `-native-multi-photo-fixture`: two already prepared synthetic photo previews, no library.
- `-native-question-fixture` + optional `-native-question-retry-fixture`: synthetic live batch; session actions -> Questions (1) modal, inline card owns composer slot until answered even when collapsed. Option IDs `question-option-direction-0`, `question-option-details-0`; inline IDs `inline-question-*`. Local books are Store/auth scoped. Continued question ownership is covered by NativeInteractionTests with real `userQuestions/answer` fake transport; there was no original continued-question UI flag.
- `-native-question-draft-fixture` additionally seeds `Keep my separate draft` while question owns slot.
- New-task Cancel now saves local and returns Home: query buttons whose identifier BEGINSWITH `local-draft-`, tap to resume nativeComposer. No duplicated `session-<draftSID>` in Mac shelves.

No production/debug default fallback to fake transport after a live error. No model/Send calls from the UI fixtures above.

# Photo picker confirmation handoff — 0.6.2/build 12

The user can open +, select photos and confirm with the picker checkmark, but sees no photos in the composer afterward. The exact first-open chat error remains unconfirmed because the screenshot could not be attached.

## Fix scope

The old import was a SwiftUI composer `.task(id:photoGeneration)`; view disappearance cleared the picker selection and changed its generation. This tied slow Photos/iCloud transfer to a transient input view's lifetime. The new import is a session-draft-owned task in NativeStore. The stable conversation receives the picker selection and starts that import before clearing the picker binding; clearing the binding no longer cancels the import. View disappearance only releases keyboard focus, not selected photo transfer.

Imports remain ordered/additive, bounded JPEG preparation is still off-main, and ownership stays on the session that picked the photos even if another chat becomes selected. Explicit Cancel/host session removal invalidates the token and cancels the task. An old cancelled import cannot append to or clear a newer batch. No file-path/permission/provider changes or extra model requests are introduced.

Errors from Photos transfer/image preparation are now visible immediately beside the composer as a scoped photo-import issue, rather than solely in a global error property. Missing library data tells the user to retry selection and, if applicable, download an iCloud original in Photos. This is not a claim that iCloud was the user's cause.

## Verification underway

The three new unit cases passed: delayed transfer survives cancellation of its initiating view task and stays with the original session; cancelled older transfer cannot join/erase a replacement batch; missing library data produces a visible per-session issue. Existing unit tests also passed (26 unit tests total). The complete run passed **26 unit + 28 UI = 54 tests**, zero failures, including the actual simulator Photos picker selecting two photos then adding another batch. Device build and strict signature verification passed. Installation failed with CoreDevice 4016: trusted remote connectivity/power/services assertions were unavailable. **0.6.2 is not installed**; the user was asked to unlock/reconnect the phone. No lock bypass or repeated speculative install attempt was made.

No physical personal-photo library was opened or copied. A successful simulator picker test alone cannot prove every real-device iCloud/HEIC path; the user should retry + → select → checkmark on the phone after installation.

## Separate chat-load report

NativeStore/NativeGateway have cancellation-sensitive stream opening on SwiftUI detail tasks. That is a plausible first-load timing issue, not yet the established cause of the user's unspecified error. This photo patch does not claim to fix that separate issue. Once attachment works, capture the exact loading error or type its text before changing connection semantics.

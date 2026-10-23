# First-open chat cancellation — 0.6.3/build 13

The user supplied the actual error screenshot: `Couldn’t load this conversation. The operation couldn’t be completed. (Swift.CancellationError error 1.)`. Retry succeeded.

## Reproduction

Two deterministic tests reproduced that exact error text in the old implementation:

1. Cancel the SwiftUI-style detail task while its `session/follow` send is suspended.
2. Enter chat selection from a detail task already cancelled during mounting.

Both tests expected the current selected conversation to load, and both failed with the user's exact `Swift.CancellationError error 1` message. Other existing tests remained green. This establishes the source-level lifecycle failure mechanism, without claiming a physical-device trace of the exact transition.

## Fix

The selected session store now owns the initial read-only follow-opening task. SwiftUI view-task cancellation does not cancel that task. The opening is still cancelled on a newer session/follow, reconnect, app background/disconnect, selected-session removal, or the existing timeout. Session ID, stream ID and connection generation guard late results/errors. Remounting an already-loading same session coalesces instead of clearing/restarting the transcript.

Deliberate obsolete/deadline cancellation does not replace the current state with technical Swift error 1. Real transport/data failures still surface with explicit Retry; deadline expiry still produces the meaningful timeout message. This is not just hiding every error or retrying indefinitely. Follow is read-only; no prompt, model change, approval or agent resume is sent by this load fix.

## Verification

After the change, both original repro cases passed. The superseded-session and genuine failure/retry tests also passed, together with all then-current 30 unit tests. Added final checks cover remount coalescing and meaningful timeout preservation. The complete run passed **32 unit + 28 UI = 60 tests**, zero failures. Device build and strict signature verification passed for **0.6.3/build 13**. The earlier installation was blocked by CoreDevice 4016 (trusted connectivity unavailable). After the user connected and unlocked the iPhone, installation succeeded and an independent device-app inventory confirmed **0.6.3/build 13**, database sequence 3808. Physical-device first-open/photo behavior still awaits the user's check.

The candidate also includes the 0.6.2 session-owned photo-import hardening, which was signed/tested but could not previously be installed because CoreDevice trusted connectivity assertions were unavailable. User later successfully attached the original error screenshot; that does not by itself establish which app version is currently installed or prove the iCloud path. Only an independent device inventory will establish installation.

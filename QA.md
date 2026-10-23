# Native iPhone chat redesign — 0.5.0

Current release: **0.5.0/build 8**, signed and independently verified installed (device database sequence 3612). The user reviewed the prototype and selected Continue refining this direction; their four actual screenshots then guided dark colors, focused/unfocused input layout and floating controls. Final complete run passed **18 unit/store/image + 23 UI = 41 tests**, zero failures, plus **116 pure checks**. Historical image loading/explicit retry was exercised through an offline authenticated-RPC fixture. See [release details and remaining differences](<CHAT-RELEASE-0.5.md>). No real model/approval/provider mutation was used for QA; native back and Mac sidebar parity regressions remain covered.

The existing bundle/login are retained. No Mac app/tunnel/DNS changes. Open the app manually after the update; no lock bypass attempted. This is a reviewed DSH adaptation, not an identical implementation of every ChatGPT product feature. Full-resolution image zoom/share-original, voice/ratings, connected-account suggestions, date separators and complete Markdown selection parity remain unimplemented.

# Multi-photo update history — 0.4.1

## Current release verification

**0.4.1/build 7** was signed, signature-verified and installed successfully on the paired iPhone (device database sequence 3604). An independent installed-app query confirmed **0.4.1 / 7**. The Mac/tunnel configuration is unchanged. Open DSH manually after the update; no phone lock bypass was attempted.

- **111 pure checks** passed, including multi-photo append/order, additive batches, individual removal, cancel tokens, count/byte limits and ordered retry fingerprint boundaries.
- Final complete run: **15 store tests + 19 UI scenarios = 34 cases**, zero failures. Includes exact multi-image prompt contents/order, unchanged multi-image retry payload/ID, and limit rejection without clearing a draft.
- The **actual Apple Photos picker test executed and passed**: selected two synthetic simulator images, confirmed both in the composer, reopened the picker and appended a third. Preview/removal/per-session navigation also passed. Reviewed the real-picker selection badges and final three-photo composer screenshots.
- An initial focused run returned success with zero tests and was explicitly rejected as evidence. A full run exposed Apple's image-tile accessibility hit-test limitation; the final test uses observed tile-center coordinates. The final log confirms the picker case actually executed, not merely that xcodebuild returned zero.
- The simulator library contained imported synthetic fixtures and Apple's bundled stock samples. No physical-phone photo library was read or copied, and no real model request was submitted. Upload/provider behavior still needs user exercise; the wire payload itself is verified through the scripted transport.

See [multi-photo limits and behavior](<MULTI-PHOTO.md>). The sidebar parity work and its earlier verification follow below as history; the final 34-case run retains those regressions.

# Sidebar/data parity history — 0.4

## Corrected target

The supplied Mac sidebar screenshot—not Apple's generic grouped-card sidebar—is the visual target. Version 0.4 uses flat DSH rail styling, a leading wordmark without the iOS 26 decorative glass capsule, full-width New Session before inline search, compact workspace/title/status rows, subtle selected fill, compact native disclosures and a fixed connection footer. Plugins, Automation tasks and the unsupported microphone remain omitted.

List, NavigationLink, Button, TextField, Menu and DisclosureGroup remain native. NavigationSplitView still owns navigation and edge-back animation/cancellation; no custom global drag/offset drawer was reintroduced. Production appearance follows the device; forced dark appearance is an explicit DEBUG fixture only.

## Data bug and live verification

The 0.3 phone model discarded session `blank` flags and lacked the independent `workspace/follow` registry carrying archive IDs, pinned IDs, workspace titles and membership. Blank sessions and archived sessions missing from the Inbox snapshot were therefore defaulted into Inbox. Native now applies the Mac's visibility rules before classification, preserves existing facts, merges pending projections, and uses the same missing-facts fallback. Unknown visibility does not become an invented Inbox count.

A read-only probe captured actual host summaries/Inbox data/workspace baseline and compared exact shelf session-ID sets in memory. At the recorded capture, both implementations produced **6 Inbox / 2 Working / 931 Settled**, with **exact membership equality true**. The archive registry contained 298 IDs; there were 56 ordinary blank sessions. No credentials, private IDs, workspace names or transcript text were logged.

The user's earlier reference shows 5/2/931; counts can change as sessions run. Five is not hard-coded. The synthetic regression fixture deliberately creates **5 legitimate Inbox + 56 blanks + 223 archived missing-record sessions = the old 284**, alongside 2 Working and 931 Settled. Correct visibility displays 5/2/931.

See [sidebar investigation](<SIDEBAR-PARITY.md>) for source/rule boundaries, including default archive filtering, all-workspaces scope and per-client current blank placeholders.

## Tests and visual evidence

- **98 pure Swift checks passed**, including archive-registry visibility, current/non-current blanks, workspace display names, live archive updates, malformed-baseline retention and missing-facts semantics, plus the prior protocol/rendering/security checks.
- The complete 0.4 candidate suite passed **12 store tests + 17 UI scenarios** with zero failures. A final identical run is retained as the release verification after preserving the current blank draft when navigating back.
- UI coverage includes the 284→5 dense fixture and explicit dark render, native edge-back/cancellation, full-width sidebar return, draft preservation, search keyboard dismissal, loading/offline/retry, model/trajectory controls, stale/unknown/empty shelves, rendering and native scroll-follow recovery.
- Reviewed actual rendered light and dark simulator previews. The first forced-dark launch argument did not set iOS appearance; an explicit DEBUG-only SwiftUI color-scheme fixture corrected that. An accessibility header combined its child count identifiers; explicit combined shelf labels fixed the test target without changing membership.
- The final dark preview shows all five Inbox rows, both Working rows and collapsed Settled (931) on a phone screen, without grouped cards or the logo glass capsule.
- Native transport/caching/outbox/photo and agent-stop safeguards from 0.3 remain. A failed log stream must not pretend the Mac agent stopped or hide Stop. The earlier actual chat snapshot of 1,167,557 bytes decoded with the raised 16 MiB limit; no automatic prompt replay was introduced.

Tests use explicit synthetic fixtures and a scripted transport, not production network-error fallbacks. They do not send a real model prompt, change a real model, approve tools, archive sessions or otherwise mutate agent workspace data. Live probes are read-only.

## Installation

Version **0.4.0/build 6**, iOS 18+, was signed, signature-verified and installed successfully after review (device database sequence 3588). An independent installed-app query confirmed **0.4.0 / 6**. The existing device login/bundle identifier is retained; no Mac app, tunnel, DNS or server configuration changes were required. No further automatic launch was attempted after the phone's earlier explicit Locked refusal; unlock and open DSH manually. The final release run passed all **29 XCTest cases** (12 store + 17 UI), 0 failures.

## Remaining boundaries

Mac scope/filter choices are client-local; this implements the default all-workspaces/non-archived view matching the supplied multi-workspace reference. A client actively viewing a different blank placeholder may legitimately show one different placeholder. The footer shows connection state rather than fabricating the Mac account identity.

Real-device feel and camera/QR redemption, photo/provider compatibility, actual send/stop/model/approval actions, long-idle Wi-Fi/cellular handoffs, rotation, VoiceOver and broad accessibility-size review still need on-device exercise. No physical FPS/battery benchmark is claimed. Drafts/photo drafts/unconfirmed payloads are memory-only across process termination. Unconfirmed admissions retain IDs for explicit retry; resolve/discard the prior unconfirmed admission before sending another in that session.

Markdown remains a tested subset rather than complete CommonMark/GFM; remote images never auto-fetch. Some context-trigger labels approximate desktop behavior and developer-message context is still hidden. General files/downloads, historical images, provider/permission editing, shelf mutations, advanced team/subagent and question/plan editors, voice, push/Face ID and App Store distribution are not implemented.

This is a reviewed development build with concrete parity fixes, not a claim that every interaction is flawless. Fixture images are not the user's real conversations or proof of the physical phone's current screen.

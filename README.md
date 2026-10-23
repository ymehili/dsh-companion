# DSH Native iPhone 0.6 — native chat, shelves and questions

Current phone release **0.6.0/build 10** adds running-session steering, native pending-question forms and bottom-docked Mac shelves. The **0.6.1/build 11** refinement moves search to the header, New Session/settings to bottom controls and removes per-chat chevrons without replacing native split navigation. See [interaction fixes](<INTERACTION-FIXES.md>) and [sidebar refinement](<SIDEBAR-REFINEMENT-0.6.md>). JEV's retry fix is staged separately; the user chose to restart Mac DSH later.

Version **0.5.0/build 8** redesigns the conversation around the user's actual ChatGPT iPhone captures: black/dark-blue chat palette, focused two-row composer, compact idle input, media cards, response actions and secondary Activity/details surfaces. The Mac-style sidebar and backend remain unchanged. See [chat release evidence and explicit differences](<CHAT-RELEASE-0.5.md>).

A SwiftUI client for your Mac's existing DSH Mobile connection. **No embedded website.** Native controls do not require Apple's default grouped-card appearance. Version 0.4 restores the user's Mac-style flat rail, leading wordmark, full-width New Session, inline search and compact thread/shelf rows while retaining system-owned navigation, gestures and button mechanics.

It also fixes the inflated Inbox by reading the separate `workspace/follow` archive/visibility registry and preserving session `blank` flags before classification. Reading the Inbox snapshot alone was insufficient. See [exact membership investigation](<SIDEBAR-PARITY.md>); no counts are hard-coded.

Requires **iOS 18+** for native scroll APIs. Your iPhone 16 supports this minimum. Development version: **0.6.1 / build 11**.

## OpenUI cards (assistant answers and plugin tool results)

A top-level fenced block in an **assistant** answer whose first info token is exactly `openui` renders as a sandboxed OpenUI card. This applies to live streaming and committed answers. The app UI is otherwise unchanged: reasoning, context, user text and nested or other-language fences stay native, so this is a scoped exception to "No embedded website" above. Limits match desktop: at most 8 cards per answer and 256 KiB per card. Larger cards fall back to a code block. The shared assets are in `Resources/OpenUI` (copied from `dsh-openui/assets`) and are bundled as a folder reference. Run `xcodegen generate` after updating them.

Successful, exactly named `openui_card` tool results also render cards, using only durable `tool/result` presentation metadata (`data.meta.openui`) with `kind: "card"`, a string `title` (at most 160 UTF-8 bytes), and a nonblank string `source` (at most 256 KiB UTF-8). Numeric `version: 1` always selects the unchanged `chat-v1` catalog. Numeric `version: 2` additionally requires exactly `catalog: "intelligent-v1"`; unknown versions/catalogs stay generic. The intelligent catalog composes explanatory text, diagrams and locally reactive controls in one answer; its redundant native heading is hidden. Legacy titles remain native, literal text. The source goes directly to the same committed sandboxed card, including its readable native source fallback on rendering failure. Tool summary text and the existing Input/Output/Copy UI stay unchanged; source is not added to model-facing output. Guide results, failed tools, other tool names and invalid/missing metadata retain generic native tool UI. The app never extracts tool cards from arguments, result text, user text or assistant text; the pre-existing assistant fenced renderer remains a separate path. No custom session event, desktop source change or bundled renderer change is needed; the Host plugin can update independently of the official desktop app.

**Placement (0.7.4):** tool cards appear **only inside a completed turn's final assistant answer** — below the answer text and above its copy/time footer — never in a tool work group (collapsed or expanded) and never while the turn is running. `Conversation` keeps a cached per-turn ledger (`OpenUITurnLedger`) fed one durable event at a time in seq order, so no history scan happens at render time. Rows are attributed only by their recorded `data.turn`. A turn publishes cards only when all of these hold:

- its actual `turn/end` reports `data.reason.kind == "completed"`. Only the first end of a turn counts.
- it has a final reply: an assistant message with text and no later tool row in that turn. A reply followed by more tools is intermediate.
- the cards come from that turn's successful exact `openui_card` results recorded before its end, in durable call order. Cards are deduplicated by `callId`, with at most 8 per turn.

Running, aborted, errored, reason-less and reply-less turns, results without a durable turn, and rows recorded after the end show no card anywhere. Live tail events, snapshot replay, history pages (one rebuild per page) and out-of-order or replaced events all produce the same placement. A turn's end bumps `transcriptRevision` once, so a reader at the bottom follows the new cards. `OpenUIFinalAnswerTests` covers this through the ledger, the grouped transcript and a hosted `NativeConversation` driven by live store frames. The hosted run saved screenshots: [running, no card](<build/openui-final-answer-running.png>) and [completed, cards in the final answer](<build/openui-final-answer-completed.png>).

- Each card is a `WKWebView` with a memory-only data store. It also uses a compiled content rule list that blocks every non-`file:`/`data:`/`blob:`/`about:` load; if that list doesn't compile, the card stays on the native fallback. The page has a no-network CSP. Only the bundled `index.html` may load, once, in the main frame. Links, reloads, subframes, popups, dialogs, context menus, file pickers and media capture are all refused. Bridge messages are accepted only from that document's main frame.
- The native bridge remains **protocol 2**. Every `ready`, `height`, `error`, `action`, `state` and `copy` message must carry numeric `protocol: 2`. A mismatched lifecycle message (`ready`/`error`) fails visibly with an incompatible-renderer fallback; other malformed/mismatched messages are ignored. Updates use `window.dshOpenUIUpdate({response, isStreaming, dark, labels, catalog, initialState, theme})`; the native body-font Dynamic Type metric supplies `theme.fontSize` in logical CSS pixels and `fontFamily: "system-ui"`. Light/dark and text-size changes preserve edited local controls. A single offline runtime exposes both legacy and intelligent catalogs through the same React/WebKit frame; no arbitrary scripts or remote assets are enabled.
- Each update is checked. If `window.dshOpenUIUpdate` is missing or throws, the `evaluateJavaScript` error is no longer ignored: the card falls back to its native source with a Retry button. A state counts as delivered, which enables actions, only after the update succeeds.
- The answer's height follows its content (44–12,000 pt) in the outer transcript, without an inner scroll view. The shared renderer uses the source fallback for content beyond that safety budget. During streaming, updates are coalesced (~80 ms). If the card doesn't report ready within 10 s, or it fails to render or its process crashes, the native source is shown with a Retry button.
- Local controls update the answer without an assistant turn or network request. For final-answer cards with a durable session ID and call/card ID, JSON-object state (at most 16 KiB, depth 32) is coalesced by one-shot timers and persisted in device-local UserDefaults. Remounts restore it; source/catalog SHA-256 fingerprints invalidate stale values. Storage is bounded to 64 records and 1 MiB, evicting oldest values. This is not credential storage: do not put secrets in cards. There is no cross-device state sync and local state is not silently added to model context. Streaming, not-yet-delivered, failed and unmounted frames cannot write further state; unmount flushes the latest accepted value.
- Actions are accepted only from committed (not streaming) cards, after a trusted click, one per second, and only as `continue_conversation` events up to 16 KiB. An action is never sent directly. The native confirmation shows the human-friendly message and readable form/context values first; **Details — exact message** expands the complete JSON. Nothing is sent until the user taps **Send**. The ordinary outgoing message remains `OpenUI card action:\n` plus the event's exact canonical compact JSON, including all hidden values. `NativeStore.sendStagedText` uses the same request-ID, durable pending save, delivery and explicit-retry path as the composer. It never reads, clears or attaches the editable draft or its photos.
- An explicitly clicked local Copy action may emit `{protocol: 2, type: "copy", text}` (at most 16 KiB). Native ready/delivery/nonstreaming/main-frame checks and the same rate limit apply. It writes only that text to the clipboard, never reads the clipboard, shows a brief Copied status, and starts no model turn.

**Native validation (20 October 2026):** the complete `DSHCompanionTests` target passed **161/161**, zero failures/skips, on the iPhone 18 Pro iOS 27 simulator after the shared assets were rebuilt. Coverage includes both catalogs; the unchanged final-answer-only ledger; bounded/corrupt-state handling, ownership and source/catalog invalidation; ready/delivery/streaming/failure/coalescing/copy gates; and real WebKit calculator edits, theme changes and restoration after remount. The hosted final-answer test also verifies session isolation and durable card-ID threading. Simulator derived data and result bundle are outside the source tree; no device build/install or signing changes were made. The full UI-test target was not rerun for this scoped change.

## Multi-photo update

Select multiple photos in the native ordered picker (up to the host’s 20-image limit), add another batch without replacing existing photos, preview/remove each photo, and send them together. Preparation honors host limits with mobile bounds of 1600px, 8 MB per photo and 32 MB total. Every ordered image is retained in explicit retry payloads. See [multi-photo behavior and validation](<MULTI-PHOTO.md>). The actual picker test selected two photos, reopened it and added a third.

## Apple-owned interactions

- `NavigationSplitView`, `List` and `NavigationLink`: full-screen Chats on a compact iPhone, standard edge-back animation/cancellation, native keyboard/focus handling. No custom `DragGesture`, offset drawer or global pan recognizer.
- Native search, segmented Chat/Trajectory `Picker`, standard `Button` styles, `Menu`, sheets/forms, `PhotosPicker`, `TextField`, `DisclosureGroup`, `ProgressView` and unavailable/error states.
- Native scroll geometry and phases keep the chat following only when at the bottom; returning to the bottom re-enables follow. Short chats no longer show a false jump-to-latest control.
- Microphone, Plugins and Automation tasks controls are omitted because their native implementations are unavailable.

Brand artwork, message layout and the Markdown renderer are app-specific SwiftUI views—not claims that Apple supplies a stock DSH/chat component. Standard controls own their press feedback, navigation/sheet animations and gesture cancellation.

## Reliability and rendering

- Cached durable transcript; streamed tokens no longer sort/rebuild history or redraw the entire sidebar. Observation tracks individual model properties.
- Human messages and injected host context are distinct. Context stays collapsed instead of masquerading as something you typed.
- Native headings/lists/quotes/tables/fenced code, selectable text and code Copy. Only safe HTTP(S) links; remote images are never fetched automatically. This is not complete CommonMark/GFM support.
- WebSocket limit raised from 1 MiB to 16 MiB; JSON decoding runs off-main. Twenty-second heartbeat with a ten-second pong watchdog, generation checks and explicit reconnect/rebaseline behavior.
- No reconnect for ordinary inactive→active transitions; no duplicate startup connect. Actual backgrounding pauses updates. Scoped conversation retry states, handshake/load deadlines, exponential reconnect backoff and no all-stream reconnect loop when a session ends.
- Immutable send payloads are separate from the next editable draft. Unconfirmed messages keep their request ID for an explicit Retry; a durable host receipt resolves an uncertain HTTP response. No automatic prompt replay. Resolve or discard an unconfirmed message before sending the next one in that session.
- Per-session photo drafts with load tokens/cancellation; ImageIO downsamples off-main and doesn't copy EXIF/GPS metadata into the new JPEG. Photos cap at 1600px and 8 MB.
- Inbox/Working/Settled use the real snapshot/watch lifecycle and ordering, retain last-good groups on errors, and show unknown counts before first sync—not guessed membership.

## Existing backend and pairing

The same HTTPS tunnel, device login, session APIs, streaming, cancellation, model/effort selection and approvals remain in use. No Mac app, DNS, firewall, server or tunnel configuration was changed.

Create a fresh QR in the Mac's existing DSH Mobile manager at http://127.0.0.1:19401/. Scan/paste it in the app and confirm Authorize. Only https://dsh.ymehili.com/ invitations in the exact `/__pair#key=...` format are accepted; they are single-use and expire after ten minutes. Keep them private.

The app stores its own device login in Keychain (`WhenUnlockedThisDeviceOnly`). One-time migration may read the old prototype app's own cookie store; it does not display a web page, access Safari's login or copy Mac credentials. Revoke devices in the existing Mac manager. Re-pairing creates another record, so remove obsolete records there when appropriate.

Cloudflare terminates HTTPS as before; this is not independent application-level end-to-end encryption. Keep the Mac awake with DSH running. Agents keep working while the phone app is suspended.

## Build and tests

Open `DSHCompanion.xcodeproj`, select your development signing team and bundle identifier, and Run on a trusted iPhone with Developer Mode. The installed development instance retains `com.ymehili.dshcompanion` for its existing app data/login. No signing keys or provisioning profiles are in the source archive.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project DSHCompanion.xcodeproj -scheme DSHCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/dsh-native-quality \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Keep derived data outside cloud-synced Documents. Regenerate after source/project inventory changes. The scheme contains real store-level XCTest tests with a scripted transport plus fixture UI scenarios.

```sh
mkdir -p build
xcrun --sdk macosx swiftc -target arm64-apple-macosx14.0 \
  Sources/HostAddress.swift Sources/Wire.swift Sources/ChatImageReference.swift Sources/Conversation.swift \
  Sources/PromptRetries.swift Sources/DesktopPresentation.swift Sources/InboxReplica.swift \
  Sources/WorkspaceReplica.swift Sources/PhotoLimits.swift Sources/AttachmentDrafts.swift Sources/MarkdownBlocks.swift Tests/main.swift \
  -o build/quality-pure-tests
build/quality-pure-tests
```

See [QA](<QA.md>) and [design notes](<DESIGN-PARITY.md>) for exact evidence and remaining limits. Fixture data is explicit DEBUG-only test input, never a network-failure fallback.

## Remaining limits

This is a reviewed development build, not a promise that every real-device flow is flawless. Drafts, unconfirmed payloads and photo drafts are memory-only across process termination. General files/downloads, historical image display, provider/permission editing, shelf mutations, voice capture, advanced teams/subagents, native question/plan editors, push/Face ID and App Store distribution remain outside this slice. Some rare Markdown constructs and exact Mac context-trigger presentation differ; see QA. Physical camera, actual send/stop/approval/model changes, photo upload/provider compatibility, long-idle Wi-Fi/cellular handoffs and broad accessibility/orientation coverage still need on-device exercise.

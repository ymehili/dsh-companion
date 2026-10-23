# T3 native iPhone DeepSeek OAuth relay — static feasibility/security audit

## Verdict

**The phone-loopback → paired bridge → Mac callback relay is compatible with the inspected Host's callback/PKCE contract. Loopback-only `callbackOrigin` is not a blocker.** It is not implemented or runtime-proven here. The stronger requirement “phone independently validates the expected OAuth state before forwarding” **does have a missing wire contract**: the Host generates state privately, and neither start/watch exposes it. Do not infer its availability from an opaque authorize URL.

Two honest implementation choices:

1. **No Host changes:** phone strictly parses/bounds a candidate callback and relays it; Host is the authoritative expected-state validator. Keep the local browser response pending until Host accepts/settles the callback; an invalid callback must not consume the phone attempt. This is a real OAuth relay, not fake sign-in, but is not independent phone state validation.
2. **Preferred for the stated stronger requirement:** add a narrowly scoped authenticated native-attempt descriptor exposing `expectedState` and `redirectUri` to the owning paired device (never PKCE verifier/token), with attempt/device binding. Existing start/watch do not provide this. A bridge alone cannot recover the private state from the inspected APIs. Only rely on authorize-URL state if a separately established provider contract guarantees it; this source does not.

High confidence in these static Host conclusions; conditional confidence in iOS end-to-end viability. Safari/ASWebAuthenticationSession HTTP-loopback navigation, redirects, app scheduling, and actual provider redirect acceptance need separately authorized physical-device tests. SDK declarations alone do not prove those behaviors.

## Evidence/scope

2026-10-17, read-only source inspection. Reused extraction `ev_7979e86970c846a799023a9a59149be6c6da854281f49e78a06fc0d627058812`, ASAR SHA-256 **b9ec4c2bbc20c9dbc3e39fa4c961434a943434ab0a803052b26753dd15f3b066**, as recorded in [T3 Host matrix](<T3-HOST-CAPABILITY-MATRIX.md#L3-L7>). No new extraction/digest verification, code execution, GUI/browser/network requests, auth/account/provider/model calls, opened ports, keychain/config/credentials/personal-state reads, or app restart. Only this document was written. Reading source containing credential/file operations did not execute them.

Source aliases: [platform][P], [account controller][AC], [generated account wire schema][A], [client connection][CC], [webserver][W], [bridge source][B]. Extracted paths are temporary and may expire.

## Exact current Host contract

| Question | Observed implementation |
|---|---|
| Callback origin | `loginOrigin` accepts only a complete HTTP origin matching case-insensitive `^http://(?:localhost|127\\.0\\.0\\.1|\\[::1\\]):([0-9]+)/?$`, with explicit nonzero port, parsed by `new URL`; no user/password/path/query/fragment. URL parsing imposes valid port range (up to 65535). Numeric port normalized; trailing slash removed. Port 80 is accepted explicitly even though URL normally suppresses default ports. No check ties this port to the Mac listener or proves who owns it. Phone should use canonical `http://127.0.0.1:<actual-port>`. [platform:306–325][P] |
| Start | `account/startSignIn` named args `{client:{version:string,locale:string,timezoneOffsetSeconds:number},callbackOrigin:string,loginSource:'web'|'desktop'}`. Offset is seconds east of UTC. No `request` nesting. Controller delegates directly. [controller:246–263][AC], [schema:131–155][A] |
| Initial result | AccountState, not a direct URL/string and not guaranteed ready. New attempt starts `initializing`; a currently active attempt in initializing/waiting-browser/exchanging/committing is reused **regardless of new callbackOrigin/client/source**. Never cancel another device's existing attempt silently. [platform:824–883][P] |
| State availability | `{status:'signed-out'|'credential-stored',links:{usageUrl:string,topUpUrl:string},attempt:null|{id:string,phase:'initializing'|'waiting-browser'|'exchanging'|'committing'|'succeeded'|'cancelled'|'expired'|'failed',authorizeUrl?:string,expiresAt?:number,errorCode?:'expired'|'no-response'|'network'|'protocol'|'storage'}}`. No OAuth state, redirectUri, owner-device identity or verifier field. `id` is a UUID, **not OAuth state**. Host generates separate 32-random-byte base64url state and verifier. [schema:73–87,131–172][A], [platform:971–976][P] |
| URL timing | Subscribe `account/watch` (no args) for initial state and later changes, wait for own attempt `waiting-browser` with URL and deadline. `update` removes authorizeUrl on each subsequent phase update. `expiresAt` is epoch milliseconds, capped by Host configured attempt timeout (default 600000 ms) and provider `expires_in`. [platform:917–944,963–969,981–1046][P] |
| Callback route | Raw HTTP **GET** `/oauth/callback?code=<encoded>&state=<encoded>`, not RPC and not JSON POST. Handler parses `req.url` relative to `http://127.0.0.1`; checks pathname, exactly one state and code, nonempty code, byte-length equality then timingSafeEqual for state. Extra parameters are not forbidden by Host. There is no callback request-origin/Host equality check against `attempt.origin`, no cookie check and no browser-CSRF-marker requirement. [platform:991–1016][P] |
| Callback refusal/replay | Bad method/path/state/missing or duplicate code/state → 400 no-store. Valid shape/state but aborted, already claimed (`attempt.callback` assigned), or not waiting-browser → 410 no-store. Invalid requests do not claim callback. First valid request claims response before resolving code, preventing concurrent replay. Route disposed after attempt settles and response finishes; later requests can become 404. [platform:876–879,1002–1015][P] |
| PKCE/redirect semantics | `redirectUri = attempt.origin + '/oauth/callback'` is sent **identically** in both `auth_init` (`code_challenge`, method S256, state, locale, login_source) and `auth_exchange` (`code`, **Mac-only** `code_verifier`, redirect_uri, Mac device identity/model/OS). Exchange does not derive redirect_uri from the relay request's Mac destination URL. Tokens committed on Mac only. [platform:1018–1026,1050–1089][P] |
| HTTP result | Callback response is retained through exchange/credential commit. Authorized outcome → 302 to validated provider `/dsh/authorized?...&login_source=...`; otherwise 204. Failure → 200 static close-tab HTML for `web`, 204 for `desktop`. Thus neither HTTP 200 nor 204 proves sign-in success; follow AccountState. Provider `error`-only callbacks are not recognized (400); watch expiry/cancel remains necessary. [platform:861–879,1129–1140][P] |
| Cancel | `account/cancelSignIn` args `{attemptId:string}` returns AccountState; matching attempt is aborted/cancelled except during **committing**, when cancellation waits for commit instead. Host tries `auth_cancel` using authorize_id/verifier after an aborted initialized attempt; no phone token/verifier involved. Closing a watch, browser or HTTP connection is **not** this explicit cancellation. [platform:884–893,1093–1127][P] |
| Watch/expiry | `account/watch` initial snapshot + coalesced updates, cancellation releases listener; terminal phases remain visible. `account/watchExpiry` streams only future `'session-expired'` events (credential expiry, not login-attempt timeout). `getState` gives reconnect snapshot. Do not automatically call profile/balance/bonus APIs. [controller:279–317][AC], [platform:615–626,917–944][P] |

### Cookie, CSRF and source boundaries

The callback is registered on raw webServer, **outside client-connection /api authentication**. Webserver dispatches exact routes directly, without a global cookie/origin fence ([webserver:378–408,494–497][W]). OAuth state + PKCE are its intended anti-forgery controls.

Account RPCs are different: client-connection checks trusted Host authority, rejects `Sec-Fetch-Site: cross-site`, allows absent Origin or otherwise requires HTTP(S) same authority, and requires authenticated browser cookie/live peer ([connection:240–269,736–749][CC]). Do not accidentally apply these RPC assumptions to the raw callback, or assume the provider browser shares paired app cookies.

Existing [bridge:51–56,95–159][B] checks public Host, any Origin equality, exact Origin for mutations, pairing session cookie, then proxies to current loopback Mac listener. It replaces upstream Host and cookie, rewrites existing Origin/Referer to Mac origin, strips forwarding headers, and strips Mac Set-Cookie from response. GET without Origin is allowed if otherwise authenticated. Therefore an authenticated native URLSession request can relay raw callback through the existing proxy. **ASWebAuthenticationSession itself need not possess pairing cookies**: the app owns that bridge request. Do not forward the provider navigation directly to the public bridge expecting authentication.

For native POST/RPC transport use the exact paired HTTPS Origin, valid pairing cookie, and JSON content type; hostile cross-site markers must not be forwarded. HTTPS terminates at the tunnel per source comments; certificate validity/pinning/deployment was not inspected. The source uses an operator-equivalent upstream cookie, not narrow account capability isolation. A new native-specific bridge endpoint should bind requests to device + attempt and not expose arbitrary callback targets or arbitrary Mac URL forwarding. This audit did not inspect custom native gateway modules or their allowlists.

## Authorize URL restrictions — from actual source, not a guessed allowlist

Host default platform origin is `https://platform.deepseek.com`, configurable in code. It validates returned authorize URL against **configured exact origin** and exact path **`/dsh/authorize`**, rejects username/password/fragment, permits query, returns normalized URL. If `rewriteBrowserOrigin` is enabled, it first accepts an HTTPS returned origin then rewrites to configured origin. Explicit development loopback HTTP requires `allowLoopbackHttp` ([platform:33–74,500–517,1028][P]).

Production phone policy: allow only HTTPS, exact approved Host deployment origin (default `https://platform.deepseek.com`, default port only), exact `/dsh/authorize`, no credentials/fragment, no suffix-host matching. Do not silently accept development HTTP or arbitrary configured hosts. If multiple deployments must be supported, provision a trusted permitted platform origin separately; do **not** treat untrusted URL text as its own allowlist. Preserve authorize URL query exactly; never append invented OAuth parameters, replace redirect_uri, or manufacture an authorize URL. The source validates neither state nor redirect_uri in authorize URL; it may carry only opaque authorization identifiers.

## Minimal correct native protocol (design, not existing API)

### Current wire operations

Business gateway payloads are `{args:{...}}` (carrier request IDs/envelopes are transport-owned):

```json
{"args":{"client":{"version":"<app-version>","locale":"en-US","timezoneOffsetSeconds":28800},"callbackOrigin":"http://127.0.0.1:<prebound-port>","loginSource":"desktop"}}
```

Endpoint `account/startSignIn`; `desktop` avoids returning a failure HTML page, but is not a new `ios` enum. Keep mobile identity truthful in version metadata. `account/watch` / `getState` take `{args:{}}`; `cancelSignIn` takes `{args:{attemptId:"<owned-id>"}}`. Raw callback is different:

```http
GET /oauth/callback?code=<same-percent-encoded-code>&state=<same-percent-encoded-state> HTTP/1.1
Host: <paired-bridge-authority>
Cookie: <pairing-session, never provider cookie>
Accept: application/octet-stream
```

Bridge proxies that exact origin-form request target to its discovered Mac listener, with Mac Host/cookie. Do not send a full phone URL as the upstream URL; do not proxy to caller-supplied destinations. Disable HTTP redirect following **for this callback transaction**: consume/discard Host 302 Location/body, never allow URLSession to follow provider completion with bridge cookies. Accept only bounded Host result metadata, not arbitrary HTML. No OAuth code/state/authorize URL/request-target logging anywhere in app, bridge, tunnel/access/analytics/crash logs.

### Recommended optional native descriptor extension

Not present today; requires explicit future Host/API work and regenerated schema:

```ts
type NativeAttemptDescriptor = {
  attemptId: string;
  redirectUri: string;       // exact prebound phone loopback URL
  expectedState: string;     // opaque Host-generated value; confidential in transit
  authorizeUrl: string;
  expiresAt: number;         // epoch ms
};
// Delivered only to initiating authenticated device for its attempt,
// not broadcast into the current global account/watch projection.
```

A bridge could separately expose `submitNativeCallback({attemptId, callbackTarget})` with server-side device/attempt mapping, strict bounds, and fixed Mac callback destination, returning `{accepted:boolean}` plus safe AccountState. It must not pretend to know `expectedState` without the Host addition. An alternative new Host callback-validation operation can validate state before exchange, but also is a new contract, not a shipped method.

### Sequencing and security invariants

1. Explicit user Sign in action only; deny initiation/callback mutations during QAReadOnly. Establish paired TLS transport and ownership serialization. If Host already has an active attempt, offer “Sign-in already in progress on another client”; do not open its URL against a new phone listener. Current Host has no owner tag: bridge serialization plus a preflight snapshot reduces races but cannot prove ownership against concurrent Mac initiation. A fully robust descriptor must bind callback origin/device and attempt atomically.
2. Generate independent ≥128-bit cryptographic **close nonce** in phone memory. Create TCP NWParameters with `requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)`, no endpoint reuse, no Bonjour service and no wildcard/IPv6 listener. Instantiate NWListener, install handlers/start queue, wait for `.ready`, capture nonzero assigned `listener.port`, **keep it bound**, only then start Host sign-in. Never probe/reserve a port then close/rebind it. SDK supplies these APIs, but binding behavior must be verified in future tests; `acceptLocalOnly` alone is not proof of 127.0.0.1-only bind.
3. Retain listener/session/coordinator strongly through the whole attempt, not only screen-view lifetime. Wait for owned waiting-browser descriptor/update before opening URL. Abort cleanly on listener failure or `.start()` false; use a foreground presentation anchor.
4. Open provider **only in ASWebAuthenticationSession**, using `.customScheme("dshcompanion-auth")` (iOS 17.4+) or earlier callbackURLScheme initializer. Never WKWebView, injected JavaScript, proxy-login HTML, copied password form or fake successful account. No provider cookies or bridge credentials injected into auth browser. Ephemeral-browser preference is a privacy/SSO choice, not an OAuth security boundary.
5. HTTP parser must be incremental and bounded, e.g. request line ≤8 KiB, headers ≤16 KiB, ≤32 headers, ≤4 concurrent connections, 5-second read timeout, zero request body. Accept only HTTP/1.1 GET origin-form exact `/oauth/callback`, exact single Host `127.0.0.1:<port>`, one nonempty code/state, no fragments, malformed escapes, duplicate query keys, Transfer-Encoding, positive Content-Length, Expect, upgrades, pipelining or absolute-form URLs. Require loopback peer. A conservative code/state length cap is app policy, not a documented provider limit; fail safely if exceeded. Forbid extra query keys unless explicitly justified. Do not require same-origin Origin/Sec-Fetch-Site on this inbound provider navigation (it is naturally cross-site).
6. With descriptor: compare received state to expected bytes in constant time; claim callback atomically only after validation. Preserve the accepted raw callback target so percent encoding, `+`, Unicode and `%2B` do not change code/state semantics. Never trim/re-encode twice. Relay code/state **only** over existing authenticated paired TLS to fixed `/oauth/callback`. Do not forward arbitrary received browser headers. With no descriptor: Host validates expected state; reject Host 400 without consuming local attempt, preserve listener until deadline; 410/404 requires reconciliation, never success. Invalid requests must not cancel an otherwise valid pending attempt.
7. Allow at most one valid submission in flight; keep a private submission state separate from OAuth success. Bound callback HTTP response size (e.g. 16 KiB), do not display/log returned HTML, and use deadline-aware timeout allowing Host exchange/commit. Dropped transport after submission is **indeterminate**, not safe to replay blindly: read owned AccountState and reconcile. Host may already have committed.
8. After accepted Host callback completion (including terminal auth failure), local listener emits its **own** `302 Location: dshcompanion-auth://complete?nonce=<close-nonce>`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `Content-Length: 0`, `Connection: close`. No code/state/provider completion URL/token in this custom URL. Validate scheme + exact host/path + exactly one nonce, no extra items/fragment/credentials, constant-time nonce check in ASWebAuthenticationSession completion. A matching nonce only closes browser; it never establishes account success. Random unsolicited custom callbacks are ignored/reconciled, not successful login.
9. Observe Host `succeeded`/`credential-stored` for sign-in success; `failed`, `expired`, `cancelled` are explicit terminal UX. Respect committing: user Cancel can finish successfully if commit won the race. Do not call signOut as a cancellation substitute. No automatic profile/balance/provider discovery.
10. Close active sockets, listener and ASWebAuthenticationSession; cancel timers and watch subscriptions; discard callback target/code/state/nonce from memory on terminal outcome. Explicit browser Cancel calls `account/cancelSignIn` only for the owned attempt, then reconciles. Listener/network failure, real application background/suspension or deadline does bounded best-effort owned cancellation and cleanup. Inactive scene while system auth sheet is presented is not alone cancellation; distinguish inactive from actual background. Do not rely on indefinite background execution or a loopback server surviving suspension. If background tasks are used for brief cleanup, expiry closes local resources; Host expiry is the fallback when bridge unavailable.
11. Maintain a local monotonic deadline capped by Host expiresAt and local policy (default Host cap 10 minutes); watch reconnection never extends it. On foreground/reconnect, fetch state, never reopen a stale URL, never silently restart auth. Surface “Sign-in interrupted; retry” with explicit user retry.

## Apple SDK static evidence and remaining release gates

[ASWebAuthenticationSession.Callback header][CB] exposes custom scheme and associated-domain **HTTPS** host/path matching (iOS 17.4+), not HTTP-loopback callback matching. Therefore the HTTP listener + final nonce-only custom redirect is meaningful; merely passing an HTTP URL to the callback API is not equivalent. [ASWebAuthenticationSession header][AS] supports HTTP(S) initial URL, secure system authentication UI, presentation-context requirement, completion on callback/cancel, start result and explicit cancel; it does not promise all browser navigation to localhost is permitted under every OS/provider policy.

[Network interface:616–705,2536–2551][NW] exposes listener ready/failed/cancelled states, assigned port, TCP listener initializer and requiredLocalEndpoint/endpoint-reuse/local-only controls. These declarations support the design but are not a socket-binding or background-execution test.

Before claiming production sign-in works, separately authorize physical-iPhone tests for: exact 127.0.0.1 bind/no LAN reachability; system auth browser→loopback HTTP navigation; nonce-only 302 interception; provider accepts that redirect_uri; state descriptor or documented delegation; existing-attempt races across Mac/phones; cancellation during initialization/exchange/commit; suspension, lock, bridge loss, listener failure, expired/invalid/replayed/oversized callbacks; callback request logging redaction and URLSession no-redirect behavior. No such tests were run here.

## Impact on whole T3 UX

[Current Providers UI](<Sources/MobileProviders.swift#L29-L39>) intentionally drops authorizeUrl and [shows Mac-only sign-in](<Sources/MobileProviders.swift#L171-L185>). That is honest current implementation status, **not evidence the Host cannot support a phone relay**. The full T3 plan must include native account coordinator, owned-attempt wire/security seam, system browser session, loopback lifecycle/parser, paired relay, cancellation/reconciliation and truthful terminal UX. Keep Mac sign-in fallback until these gates pass; do not silently omit native auth from parity or replace it with a fake grant.

[P]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-deepseek-account-platform/lib/index.js>
[AC]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-api-account-controller/lib/index.js>
[A]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-api-account-controller/lib/typert.remote-client.js>
[CC]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js>
[W]: </var/folders/tx/s3yv703n58gd0tp7qffw6p4h0000gn/T/rea-extracted-b77fa1b1-10a1-4240-8c6e-319994392b9c/dsh/node_modules/@deepseek-ai/dsh-host-webserver/lib/index.js>
[B]: </Users/ymehili/dsh-mobile/bridge.mjs>
[CB]: </Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Cryptexes/OS/System/Library/Frameworks/AuthenticationServices.framework/Headers/ASWebAuthenticationSessionCallback.h>
[AS]: </Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Cryptexes/OS/System/Library/Frameworks/AuthenticationServices.framework/Headers/ASWebAuthenticationSession.h>
[NW]: </Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/Network.framework/Modules/Network.swiftmodule/arm64e-apple-ios.swiftinterface>

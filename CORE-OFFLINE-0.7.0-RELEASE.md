# Core chat + offline drafts — 0.7.0 (14)

## Selected scope

Native T3-inspired DSH Threads/chat/composer/keyboard/photos, model/project selection, questions/approvals/activity, thread lifecycle and basic settings; offline drafts only. Files, Terminal, change review, provider/server administration, schedules, voice, Git/worktrees and PR integrations are excluded from the generated app build. No staged backend adapters activated. Official T3 mobile reference remains pinned at 2fae0f9841448e6edb93d0ebe4cbaf2d546bb38c with MIT notice retained.

## Offline behavior

- App-private, per-HTTPS-origin vault with atomic checksummed protected files, safe hashed names, bounded storage and no silent eviction/corruption repair.
- Text and prepared photo IDs/bytes stay session-scoped; leaving a new task saves it under Drafts on this iPhone, not a fabricated Mac Inbox row. Missing Mac sessions get a local-only editor.
- Unconfirmed sends are durably saved BEFORE network dispatch. Request ID, content, ordered image bytes, send mode and client timezone are immutable across restart/retry. A separate next draft is retained. No automatic send/replay on reconnect or restore.
- Disk/quota/corruption failures retain data and block dispatch rather than silently dropping it. Stale revisions cannot resurrect deleted drafts or repeatedly advance over another saved copy. Local discard requires explicit confirmation and does not delete the Mac conversation or undo delivered messages.
- Existing selected-session load ownership and store-owned photo transfer lifetime remain intact. Question books are store/auth scoped; inline/global answers remain explicit and batch-validated.

## Verification

Full selected suite: **103 unit + 40 UI = 143 passed**, zero failures, exit 0.

```
build/core-offline-release-verified.log
/private/tmp/dsh-core-offline-release-verified.xcresult
```

All 28 migrated original core behavior cases are included. Photo-transfer UI uses explicit generated image sources through the actual importer, never an unowned personal Photos gallery. Five store-integration tests verify disk reopen, exact pending retry payload, no dispatch before durable save, disk failure/no-send, scoped next drafts/photos and local-only discard. Vault tests cover on-disk checksums, corruption preservation, host isolation, stale revisions/tombstones and concurrency.

Three offline-draft UI cases independently reran and passed for final screenshots, including cancelled-new-task resume, confirmed/cancelled local discard and orphan editor/pending-request preservation. Screens under build/core-offline-release-previews and build/core-offline-draft-images use synthetic content only.

## Signed candidate / deployment gate

```
/private/tmp/dsh-iphone-core-offline-release/Build/Products/Release-iphoneos/DSHCompanion.app
CFBundleIdentifier: com.ymehili.dshcompanion
CFBundleShortVersionString: 0.7.0
CFBundleVersion: 14
codesign --verify --deep --strict: exit 0
```

Signed Release iPhone build succeeded, exit 0. User reviewed the final Home/Chat/Offline drafts screenshots and explicitly selected “Approve and install (Recommended)”. Installed successfully on physical iPhone (device identifier redacted), exit 0, installation database sequence 3832. A fresh bundle-filtered devicectl inventory confirms DSH / com.ymehili.dshcompanion / 0.7.0 / build 14, exit 0. Installation receipts: /private/tmp/dsh-core-offline-install.json and /private/tmp/dsh-core-offline-installed-version.json. The app was not launched by QA, so no real messages were sent or personal sessions captured. No Mac backend replacement/restart, real session/model/provider/automation mutation or personal conversation/file/photo probing was performed for this release QA.

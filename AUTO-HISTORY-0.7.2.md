# iPhone automatic earlier-history loading — 0.7.2 (16)

User requested progressive automatic loading on upward scroll, without an Earlier button.

- Initial positioning/layout/keyboard changes do not fetch history. A genuine upward gesture near the top loads one page; another gesture is required for another page. No automatic drain-to-start.
- Progress/loading/error state is session + connection + follow + snapshot-generation scoped. Old completions cannot mutate a new selection or clear its busy state. Errors require explicit inline Retry rather than an automatic retry loop.
- Strictly older contiguous pages must meet the loaded boundary; invalid/gapped/duplicate mixed pages cannot silently skip or overwrite history. All typed requests still use the existing read-only session/page API, not Agent resume/model calls.
- Stable work-group identities preserve the mounted target when older tool events merge into it. Anchors capture raw visible offset immediately before prepend; actual post-layout dimensions determine restoration. Expanded groups preserve existing tools and expanded detail rows; new gestures, Latest, viewport changes and later transcript revisions invalidate stale restoration. Layout probes include revision even for unchanged frame dimensions.
- Normal Earlier button is replaced by Scroll up / loading status; Retry appears only on failure. Drafts/photo import lifetime, vault-path fix, exact pending retries and deferred-feature exclusions remain intact.

Verification: **116 unit + 8 safe UI tests passed**, zero failures, exit0. Three auto-history UI cases verify initial latest behavior, automatic paging/Latest, explicit error retry/next-draft ownership, and collapsed/expanded tool/detail position retention within5pt. Five core guards cover keyboard/reading position/follow/navigation drafts/synthetic photo imports. No personal gallery or real backend/session/model calls used.

```
build/iphone-auto-history-release.log
/private/tmp/dsh-iphone-auto-history-release.xcresult
build/iphone-auto-history-signed.log
```

User explicitly approved Install now. Signed normal Release 0.7.2/build16 installed successfully, database sequence3924; app data was not uninstalled or reset. No live messages were sent, Mac settings changed or backend restarted. Device installation receipt /private/tmp/dsh-auto-history-installed.json; version receipt /private/tmp/dsh-auto-history-version.json.

Desktop is separate: dsh-mobile-ux now uses public native event-window seq progress (not DOM head identity), waits for an upward scroll to settle and loads ONE batch per gesture. No multi-page chaining; 27 desktop presentation/paging tests pass. The rebuilt module was verified served by the current desktop host49305. The user confirmed older desktop messages appear; subsequent drain-to-start feedback produced the single-batch adjustment. Do not confuse the installed iPhone bundle with the desktop client extension.

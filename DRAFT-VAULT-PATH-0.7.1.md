# Physical-iOS draft path fix — 0.7.1 (15)

## Failure

User screenshots from build14 showed `Unsafe draft vault path: non-directory var`. Foundation can present iOS's trusted `/private/var` location through the root-owned `/var` symlink even after resolving a parent URL. The component-by-component no-symlink check then incorrectly rejected that system ancestor. Simulator temp-folder tests had not exercised the production physical-iOS Application Support factory.

The save-before-send barrier correctly prevented dispatch, but the affected message existed only in RAM. User explicitly copied the original text before authorizing an app replacement. Nothing was discarded or replayed by the repair.

## Narrow fix

Allow `/var` only when lstat confirms a root-owned symlink whose exact target is `private/var` or `/private/var`, and the destination is a root-owned real directory. The exception applies only ABOVE the vault root and host directory, never at either leaf. Arbitrary symlinks, non-directory ancestors, symlink/hard-linked records, checksums, host scoping, revision/tombstone and save-before-network protections remain enforced. New regression asserts that `/var` cannot itself be used as an aliased vault root.

No user draft directories/files were reset, migrated or deleted.

## Physical verification

A separate QA bundle could not install because of Apple's three-free-development-app limit; no other apps were removed. User approved a temporary storage-only host in the existing DSH app slot, followed immediately by the normal patched app. This host contains only a static SwiftUI label and the vault implementation, NOT NativeStore, credentials, transport or backend clients. It uses a synthetic HTTPS origin and owned UUID temp roots, never the user's draft origin. Existing DSH data/container was retained.

Fresh physical test run: **14 tests passed, zero failures**, including actual production Application Support factory save/reopen and exact pending data, plus all vault security/concurrency cases.

```
build/vault-physical-approved-fresh.log
/private/tmp/dsh-vault-physical-approved-fresh.xcresult
```

Simulator patch run: **104 unit + 3 offline-draft UI tests passed**, zero failures.

```
build/vault-patch-regressions.log
/private/tmp/dsh-vault-patch-regressions.xcresult
```

Normal 0.7.1/build15 signed Release build and strict code-signature verification succeeded. Installed back over the temporary QA host without uninstalling the app or deleting its data. No Mac model requests, session mutations, configuration changes or backend restarts were used for QA. The copied, previously unsaved text must be pasted by the user; it is never automatically resent.

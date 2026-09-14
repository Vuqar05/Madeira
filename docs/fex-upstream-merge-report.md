# FEX upstream catch-up: ios-port-2607 -> FEX-2609

## Result

Madeira's FEX submodule (`willfaust/FEX`, branch `ios-port-2607`, pinned at
`053c385`, 2026-08-28) forked from upstream tag **FEX-2607** (2026-07-02).
This branch merges upstream tag **FEX-2609** (2026-09-07) into it: 588 upstream
commits, 387 files, including the persistent JIT translation cache
(DiskCache), the `SharedCodeBufferManager` rework with lock-free atomic
code-buffer allocation and the "ever shrinking JIT code buffer" fix, and a new
atomic bitmap allocator.

The merged FEX tree is complete and compiles. It is **not yet wired into
Madeira**: `.gitmodules` still points at `053c385`, because the result has
nowhere to be pushed from this session (see "Finishing the integration").

| | |
|---|---|
| FEX branch | `ios-port-2609` (local to the session that produced it) |
| Merge commit | `893bed951905e9c9ccc8e06a1dd20eb152537486` |
| Build-fix commit | `1fae40312d96706283b0b173d13f3e894a98351d` |
| Net change vs the current Madeira pin | 386 files, +19,829 / -5,057 |
| iOS-port delta vs plain upstream FEX-2609 | 66 files, +8,383 / -215 |

Two artifacts next to this file reproduce it without that session:

- `fex-ios-port-2609-vs-upstream.diff` - the **whole** iOS port on top of
  upstream `FEX-2609` (531 KB). `git checkout FEX-2609 && git apply` it on a
  clone of `FEX-Emu/FEX` and you have the merged tree, bar the nested
  `External/rpmalloc` pointer (see below).
- `fex-upstream-merge-conflict-resolutions.diff` - only the files where the
  resolution had to differ from plain upstream, for review.

## How it was done

A rebase (replaying the fork's 57 commits onto FEX-2609) conflicted on the very
first commit in six core JIT/allocator files, and would have re-raised the same
conflicts up to 57 times. Abandoned for a single merge, which resolves the whole
two-month gap once: 13 conflicts across 12 files plus the rpmalloc submodule.

Every resolution was decided from evidence, not by picking a side. The merge
commit message carries the full per-file rationale; the load-bearing decisions:

- **rpmalloc**: kept the fork's pin. It points at a *different repo*
  (`willfaust/rpmalloc:ios-madeira`, carrying a poison-log sink, 64MB spans
  and VA-band following), not a bump of `FEX-Emu/rpmalloc`. Whether that
  branch itself should be caught up is a separate question, not attempted.
- **The code-buffer allocator.** Upstream moved `CodeBuffer` and the manager
  into `SharedCodeBufferManager` and replaced the mutex-guarded cursor bump
  (`CodeBufferWriteMutex` + `LatestOffset`) with a lock-free
  `AtomicAllocateBuffer`. The fork's 119 lines of `CodeBufferWriteMutex`
  deadlock machinery in `JIT.cpp` (ml446 self-nesting stamp, ml449, the
  ml455 bounded try_lock) guarded a lock that no longer exists and are gone.
  The invariant they *also* enforced survives: under a delivery compile (TEB
  slot 3 depth != 0) the JIT now allocates only from the current buffer and
  bails through `IosCountUnpubBailOrTerminate` rather than migrating or
  swapping from under a live outer emission. Everything else iOS moved with
  the code it belonged to: `LatestMutex` (the sweeper reads `Latest` from
  another thread) and the generation counter into the manager; the 32MB
  `MAX_CODE_SIZE` cap and the ml364 pool-exhaustion degradation into the
  `CodeBuffer` constructor; `IosRemoteMigrateStale`, `IosMigrateLock` and
  the whole pool-tail sweeper stay in `CPUBackend`, on the new API.
- **Writes to JIT memory.** Upstream's new copy into the shared buffer, and its
  new DiskCache `LoadCachedCode` path, store straight to the allocation
  address. On iOS that is the RX alias and a direct store faults; both now go
  through `WritePtr()` with the RX->RW mirror offset re-armed after emission
  into the heap temp buffer, exactly as the fork's copy did.
- **`NtReadFile` locking** (`ARM64EC/Module.cpp`): upstream stopped holding
  JIT locks across a blocking read (a real hang: the PhysX msiexec installer),
  keeping the locking path only for `P5R.exe`. Reconciled with the fork's TEB
  slot mirror of the in-locked-read flag so the dying-thread lock release still
  sees it; the fork's `After` early-return now falls through so upstream's
  post-read invalidation actually runs.
- Cross-file consistency a merge tool cannot see: upstream's new
  `SharedCodeBufferManager.cpp` calls `prctl(PR_GET_MDWE)` on every
  non-Windows target, so the constant was added to the fork's Apple stub branch
  of `PrctlUtils.h` too; `DetermineVASize` -> `GetHostVABits` was carried
  into the fork-only `__APPLE__` implementation, which every caller had
  already auto-merged to; `EmitDetectionString` was dropped because upstream
  removed it deliberately (`fe1ac1bc1`) along with its declaration and call
  site; a duplicate `HadDispatchError` declaration in `Core.cpp` and a
  double `ClearRelocations` on the iOS unpublished path were caught and fixed.
- `Frontend.cpp`: the fork's entire delta was commented-out logging (verified
  against the merge base), so upstream's restructured decoder was taken whole.

## Validation

FEX's CMake builds the ARM64 JIT sources even on an x86_64 host-debug
configuration, so a genuine compile check was possible here:

- `ENABLE_X86_HOST_DEBUG=ON`, `BUILD_TESTING=OFF`, Debug, clang 18.
- **All 168 FEXCore objects compile; `libFEXCore.a` links** - the resolved
  files and every auto-merged one.
- Three fixes came out of it (second commit): `PassManager.cpp` needed
  `ostringstream` for upstream's new `IR::Dump` signature; the other two were
  **already broken at the fork tip** and merely exposed - the Linux half of
  `Allocator.cpp` lost its `"Utils/Allocator.h"` include in the original iOS
  port commit, and two iOS-only reporters in `Core.cpp` were unguarded.
- Still failing on Linux, out of scope: `External/rpmalloc/rpmalloc.c` (the
  fork's own rpmalloc calls Win32 `WriteFile`/`GetStdHandle` unconditionally
  in its poison-log sink; it is built for the arm64ec PE target, where those
  exist).

**Not verified here, and nothing in this session can verify:** every
`FEX_IOS_HOST` / `__APPLE__` branch (no iOS toolchain), all of
`Source/Windows/` (not built on Linux), and runtime behaviour. Treat the
ported allocator code in particular (`JIT.cpp`, `CPUBackend.cpp`,
`SharedCodeBufferManager.*`) as unrun until an iOS build and a device
session say otherwise.

Things to watch for on the first device runs, because behaviour changed on
purpose:

- No `CodeBufferWriteMutex`: TEB slot 6 (0x16e8) is never stamped now, so
  `IosThreadHoldsEmissionLocks()` reports only the WPM shared-hold depth.
- `AllocateCodeBufferInSharedCache` clears/migrates the buffer on a full
  `AtomicAllocateBuffer` in a loop; with the 32MB cap and pool pressure this
  is the same policy as before, on a different mechanism.
- DiskCache is new. Check its config default before assuming it is on.
- `[ffs-bypass]` and `[cb-entry]` now log only on `FEX_IOS_HOST` builds
  (which is the only place they ever had data).

## Finishing the integration

The merged branch could not be published from this session: the GitHub tooling
here is scoped to `Vuqar05/Madeira` alone (forking `willfaust/FEX` and
creating a repo were both refused), and there is no push access to
`willfaust/FEX`. Three ways to close the loop:

1. **Recommended.** Fork `willfaust/FEX` on GitHub as `Vuqar05/FEX`, then let
   the session attach it (`add_repo`, push access) and push `ios-port-2609`
   - only the 58 commits beyond upstream travel. Then in Madeira:
   `.gitmodules` -> `url = https://github.com/Vuqar05/FEX.git`,
   `branch = ios-port-2609`, and `git update-index --cacheinfo
   160000,1fae40312d96706283b0b173d13f3e894a98351d,FEX`.
2. Reconstruct it anywhere from the diff above (`FEX-2609` +
   `fex-ios-port-2609-vs-upstream.diff`), then set
   `External/rpmalloc` to `e60293eb1fac2e75c2e8524cc22de8ae2c0c23da` from
   `willfaust/rpmalloc` (the diff already carries the `.gitmodules` URL).
3. Host it inside the Madeira repository as its own branch and point the
   submodule at Madeira's own URL. Works without a new repo, but drags FEX's
   full history into Madeira; not recommended.

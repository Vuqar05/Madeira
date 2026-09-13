# FEX rebase-to-upstream attempt — findings

## What was asked

Catch Madeira's pinned FEX fork up to current upstream FEX-Emu, in a separate
branch, and see how far it gets.

## Where Madeira is pinned today

`.gitmodules` → `https://github.com/willfaust/FEX.git`, branch
`ios-port-2607`, commit `053c385` (2026-08-28). That branch name records its
own fork point: upstream tag **FEX-2607** (2026-07-02). Confirmed with
`git merge-base`.

Current upstream: tag **FEX-2609** (2026-09-07). Between FEX-2607 and
FEX-2609, upstream landed **588 commits / 387 files / +19.6k -4.8k lines**,
including a persistent JIT translation cache (DiskCache), a rework of
`SharedCodeBufferManager` (with a fix for "the ever shrinking JIT code
buffer" — the same class of pool-exhaustion problem Madeira's own iOS code
has fought by hand), and a new lock-free atomic bitmap allocator.

## What was tried

**Rebase** (`git rebase --onto FEX-2609 <fork-point> ios-port-2607`): aborted
after the very first of 57 fork commits produced 6 conflicting files in the
core JIT/allocator, because it would have meant re-resolving similar
conflicts up to 57 times as each commit replays against a different
intermediate tree.

**Merge** (`git merge FEX-2609` from the fork tip): the right tool here — it
resolves the whole two-month gap once. Produced **13 conflicts across 12
files** (one file, `PrctlUtils.h`, had two separate blocks) plus one
submodule conflict:

```
External/rpmalloc                                                (submodule)
FEXCore/Source/Interface/Core/CPUBackend.cpp                     (4 blocks, ~423 lines)
FEXCore/Source/Interface/Core/CPUBackend.h                       (2 blocks, ~79 lines)
FEXCore/Source/Interface/Core/Core.cpp                           (6 blocks, ~76 lines)
FEXCore/Source/Interface/Core/Frontend.cpp                       (3 blocks, ~91 lines)
FEXCore/Source/Interface/Core/JIT/JIT.cpp                        (4 blocks, ~210 lines)
FEXCore/Source/Interface/IR/PassManager.cpp                      (1 block, ~321 lines)
FEXCore/Source/Interface/IR/Passes/RedundantFlagCalculationElimination.cpp (1 block, ~5 lines)
FEXCore/Source/Utils/Allocator.cpp                               (1 block, ~16 lines)
FEXCore/include/FEXCore/Utils/PrctlUtils.h                       (2 blocks, ~35 lines)
Source/Windows/ARM64EC/Module.cpp                                (3 blocks, ~136 lines)
Source/Windows/Common/FEXUnixLib.cpp                             (6 blocks, ~127 lines)
Source/Windows/Common/WinAPI/IO.cpp                              (1 block, ~29 lines)
```

## Resolved, with real verification (5 of 12)

Each of these got a real investigation, not a mechanical pick of one side —
and each turned up something a blind "take ours" or "take theirs" would have
gotten wrong:

- **`External/rpmalloc`** — kept the fork's pin. It points at a *different
  repo* (`willfaust/rpmalloc:ios-madeira`, not `FEX-Emu/rpmalloc`) carrying
  its own iOS patches (a poison-log sink, 64MB span sizing, VA-band
  following). Confirmed the pinned SHA is exactly that branch's tip. Taking
  upstream's pin would have silently discarded all of it. (Whether
  `ios-madeira` itself needs catching up to `FEX-Emu/rpmalloc` is a separate,
  second-order question — not attempted.)

- **`PrctlUtils.h`** — upstream renamed `PR_GET_MDWE` in under an
  `#ifndef _WIN32` umbrella; the fork instead branches `__linux__` /
  `__APPLE__` explicitly (Apple has no real `prctl`). Kept the fork's
  structure, added the new `PR_GET_MDWE` constant to *both* branches. It
  turned out to be load-bearing: the new upstream file
  `SharedCodeBufferManager.cpp` calls `prctl(PR_GET_MDWE, ...)`
  unconditionally on every non-Windows target — without the constant defined
  in the Apple branch, that file would not have compiled on iOS at all.

- **`Allocator.cpp`** — upstream renamed `DetermineVASize()`/`HostVASize` to
  `GetHostVABits()`/`HostVABits` project-wide (confirmed by grepping every
  caller: `64BitAllocator.cpp`, `Allocator.h`, `ELFCodeLoader.h`,
  `VDSO_Emulation.cpp` — all already auto-merged to the new name). Kept the
  fork's actual improvement (a more robust multi-page VA probe, `Find()`,
  replacing a single top-of-range probe) under the new name. Then found —
  by grepping, not by the conflict markers, since git had no reason to flag
  it — that the file's separate `__APPLE__` branch (100% fork-original code;
  upstream has no Apple branch here at all) still called the old name.
  Renamed it too. Missing this would have built fine on Linux and failed to
  link on iOS.

- **`RedundantFlagCalculationElimination.cpp`** — two independent new
  `#include`s, not actually in conflict. Kept both.

- **`Source/Windows/Common/WinAPI/IO.cpp`** — the fork deleted a debug-trace
  block that was a proven stack-smash (documented byte-for-byte in the
  commit: a fixed 88-byte buffer overflowed by a preview string, corrupting a
  saved register, hijacking a `blr`). Upstream separately added real
  `lpOverlapped` offset support to the same `NtWriteFile` call the trace sat
  next to. Unrelated changes that only looked like a conflict because they
  touched adjacent lines — kept the fork's deletion and upstream's real
  offset argument together.

## Not resolved — genuinely deep, need a build+device to trust (5 files)

`CPUBackend.cpp`/`.h`, `Core.cpp`, `Frontend.cpp`, `JIT.cpp`,
`PassManager.cpp` — about **1,140 conflicted lines** in the most
safety-critical part of the tree. These aren't textual disagreements; they're
upstream re-architecting the same subsystems Madeira's iOS patches are
threaded through:

- Upstream moved code-buffer growth (`MAX_CODE_SIZE`/`AllocateNew`) out of
  `CPUBackend.cpp` into a new `SharedCodeBufferManager`, with a new
  lock-free atomic bitmap allocator underneath. The fork's conflicting block
  in `CPUBackend.cpp` isn't a stray edit — it's `IosRemoteMigrateStale()`,
  the machinery that migrates a parked thread off a stale code-buffer
  generation, plus the exec-allocation degradation path for the documented
  "858/896MB pool exhaustion, freelist 0" failure. Porting it correctly means
  understanding upstream's new allocation-ownership model well enough to
  re-implement that migration and degradation against it — not something to
  pattern-match.
- Upstream changed `PassManager`'s constructor to take a `Context*`
  (`Core.cpp`'s conflict), which fans out into `PassManager.cpp` itself — a
  321-line single block that turned out to contain `IRTopoSweepEnabled()`, an
  opt-in IR-corruption-hunting sweep built from real incident forensics
  (`ml599`/`ml599b`) after a corruption bug that stalled the renderer for an
  entire session. `Frontend.cpp` and `JIT.cpp`'s conflicts sit in the same
  neighborhood (decoder/pass wiring; `JIT.cpp`'s block includes
  `IosCountUnpubBailOrTerminate()`, the watchdog that stops a 69,902-loop CPU
  burn at pool exhaustion from running to jetsam).

Getting any of this wrong produces silent runtime corruption or a freeze, not
a compile error — exactly the failure class the codebase's own comment trail
(ml363, ml389-417, ml599, ml690, …) shows costs real debugging sessions to
even *localize*, let alone fix, and I have no iOS build toolchain or device
here to catch a mistake before it ships. I did not force resolutions here.

## Sampled but not finished (2 files, ~263 lines)

`Source/Windows/Common/FEXUnixLib.cpp` and `Source/Windows/ARM64EC/Module.cpp`
— first blocks sampled look like the *same shallow pattern* as the 5 files
above that got resolved (an iOS early-return guard clause next to an
unrelated upstream rename; upstream renamed `UnixLibAvailable()` to
`Available()` in `FEXUnixLib.cpp`, for instance). Not fully verified across
all their blocks — flagging as "probably tractable" rather than claiming
done.

## Bottom line

The two-month gap is real and worth having — DiskCache and the code-buffer
fixes land squarely on Madeira's own pain points. The merge is mechanically
tractable (5 of 12 files closed with actual verification, not guesses), but
the remaining safety-critical core needs either a FEX-familiar reviewer or a
real build-and-device-test loop before it's trustworthy — neither of which
exists in this environment. I did not fabricate a "done" result: the FEX
submodule pointer in Madeira has **not** been changed, and this partial merge
exists only in this session's scratch clone (I have no push access to
`willfaust/FEX` and no existing fork under this account to publish it to).

`resolved-conflicts.patch` in this same directory has the diffs for the 5
closed files, for reference.

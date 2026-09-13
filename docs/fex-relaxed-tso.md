# Relaxed TSO mode (per title)

An **opt-in, per-title** switch that turns off FEX's software emulation of
x86's memory ordering. It is off for every title. Nothing about it has been
measured or validated on device — see [Status](#status).

## Why it exists

Madeira is CPU-bound, not GPU-bound, on the titles that matter. The measured
case is Lethal Company: GPU busy 8.32 ms inside a 42.02 ms frame interval
(~20% GPU utilisation, on-device Metal HUD). The frame time is being spent on
the CPU, and part of what the CPU is doing is preserving x86's memory model.

iOS does not expose the ACTLR_EL1 hardware-TSO bit to apps, so
`FEX::Windows::UnixLib::TryEnableHardwareTSO()` returns `false`
unconditionally under `FEX_IOS_HOST`
(`FEX/Source/Windows/Common/FEXUnixLib.cpp:156`) and FEX falls back to doing it
in software.

## What it actually changes

FEX already owns the knob. `TSOEnabled` is defined in
`FEX/FEXCore/Source/Interface/Config/Config.json.in:450` (default `true`) and
is read from the environment variable `FEX_TSOENABLED`. **No FEX source change
was needed and none was made** — see [How it is wired](#how-it-is-wired).

With `FEX_TSOENABLED=0`:

- **Ordinary loads and stores lose their ordering.** The opcode dispatcher
  stops selecting the TSO IR ops (`_LoadMemAutoTSO` / `_StoreMemAutoTSO` in
  `FEXCore/Source/Interface/Core/OpcodeDispatcher.h:2429`), so
  `DEF_OP(LoadMemTSO)` / `DEF_OP(StoreMemTSO)` in
  `FEXCore/Source/Interface/Core/JIT/MemoryOps.cpp:767` and `:1778` are never
  reached. Plain `ldr`/`str` are emitted where `ldapur`/`ldapr`/`ldar` and
  `stlur`/`stlr` would have been.
- **LOCK-prefixed instructions are not affected.** They lower to the
  `AtomicFetch*` and `CAS` IR ops, and
  `FEXCore/Source/Interface/Core/JIT/AtomicOps.cpp` emits `ldaddal` (or
  `ldaxr`/`stlxr` without LSE) unconditionally — there is no TSO config gate on
  that path at all. A guest's explicit interlocked operations keep their
  acquire-release semantics in both modes.

So this relaxes *ordering between ordinary accesses*, which is exactly the
guarantee a hand-rolled lock-free algorithm leans on. FEX's own description of
the option is "Highly likely to break any multithreaded application if
disabled". No barrier was removed, reordered or second-guessed by this change;
the existing, deliberate barrier placement is untouched and only the
already-supported configuration path is used.

### Other TSO options that exist but are not wired here

| Option | Env var | Default | Note |
|---|---|---|---|
| `TSOEnabled` | `FEX_TSOENABLED` | `true` | what this feature toggles |
| `VectorTSOEnabled` | `FEX_VECTORTSOENABLED` | `false` | already off; `ml512` tried `true` and reverted |
| `MemcpySetTSOEnabled` | `FEX_MEMCPYSETTSOENABLED` | `false` | already off, same experiment |
| `HalfBarrierTSOEnabled` | `FEX_HALFBARRIERTSOENABLED` | `true` | unaligned backpatching; moot once `TSOEnabled=0` |
| `ExtendedVolatileMetadata` | `FEX_EXTENDEDVOLATILEMETADATA` | `""` | per-module/per-range TSO disable — **unreliable on iOS**, see below |

`ExtendedVolatileMetadata` looks like the more surgical tool (disable TSO for
one module rather than the whole process) and would be the better long-term
answer, but it is applied through `ImageTracker`, and on iOS `NotifyImageMap()`
deliberately skips the `ImageTracker` half to avoid a
code-invalidation-mutex self-deadlock — the comment at
`FEX/Source/Windows/ARM64EC/Module.cpp:1319` names "extended volatile/ForceTSO
metadata" as a known casualty of that. It would therefore apply for some
modules and silently not for others, which is the worst possible property for
an A/B. The process-wide knob is used instead; since Madeira runs one game per
launch, process-wide *is* per-title here.

## How it is wired

`app/Madeira/WineProcessBridge.m` → `madeira_apply_tso_profile()`, called from
`wine_process_thread()` just after the target exe is resolved and before Wine
snapshots the environment. It resolves a mode for the exe and always writes
`FEX_TSOENABLED` explicitly (`1` = strict, `0` = relaxed), with
`overwrite=1`, so a value left behind by an earlier launch in the same host
process cannot decide the current one.

Resolution order:

1. `Documents/madeira-tso.txt`, if present and it says something applicable.
2. The built-in per-title table in `WineProcessBridge.m` (every entry
   `MADEIRA_TSO_STRICT`).
3. Strict.

The override file takes one directive per line; `#` begins a comment:

```
# everything not named below
default = strict
Lethal Company.exe = relaxed
```

A line with no `=` is taken as the default mode, so a file containing just the
word `relaxed` works too. A per-title entry beats `default` regardless of line
order. Keys and values are case-insensitive. Accepted values:
`strict`/`off`/`0`/`false` and `relaxed`/`on`/`1`/`true`; anything else is
ignored (and reported in the log) rather than being silently read as strict.

Because it is a file in `Documents/`, flipping arms needs **no rebuild and no
re-sign** — which matters here, since a free provisioning profile expires
weekly and a rebuild between arms changes more than the one variable under
test.

`build/ntdll-unix/env_ios.c` adds `FEX_` to the `[iOS env]` beacon list so the
log proves the variable crossed into the Windows environment rather than
leaving it to be inferred.

## Manual test procedure

This has to be run on device. Everything below is the procedure, not a report
of results.

### 1. Build

A plain Xcode build of the app is enough. **No FEX rebuild and no new
`xtajit64.dll` is required**: the committed
`app/Madeira/arm64ec-windows/xtajit64.dll` (build-id `ml755`, compiled
2026-08-27) already contains the `FEX_TSOENABLED` config lookup and the
report line that proves how it resolved — both confirmed present in that
binary.

```sh
cd build/ntdll-unix && ./build.sh     # only if you want the [iOS env] beacon
cd app && xcodebuild -scheme Madeira -configuration Release ...
```

The `env_ios.c` beacon change needs `build/ntdll-unix/build.sh` to be re-run so
the new `libntdll_unix.a` is linked in. The switch itself works without it;
you just lose one of the three verification checkpoints.

### 2. Select the arm

On device, in the app's Documents folder (Files app, or `devicectl`):

- **Strict arm (control):** delete `madeira-tso.txt`, or write
  `default = strict`.
- **Relaxed arm:** write

  ```
  Lethal Company.exe = relaxed
  ```

Force-quit the app between arms. The environment is snapshotted once per Wine
process, so changing the file while a game is running does nothing.

### 3. Verify the arm actually took effect — do this every run

Three independent checkpoints in `Documents/madeira-log.txt`. **If checkpoint 3
does not match the arm you intended, the run is void; do not record its
numbers.** Two secretly identical arms look exactly like "no measurable
effect", which is the specific way this experiment fails silently.

| # | Grep for | Strict arm | Relaxed arm |
|---|---|---|---|
| 1 | `[tso]` | `-> strict (FEX_TSOENABLED=1, ...)` | `-> relaxed (FEX_TSOENABLED=0, ...)` |
| 2 | `[iOS env] INCLUDED: FEX_TSOENABLED` | `=1` | `=0` |
| 3 | `FEX: TSO config` | `tso=1` | `tso=0` |

Checkpoint 3 is FEX itself reporting what the JIT is doing, and it is the one
that matters. Checkpoint 2 is absent unless you rebuilt `libntdll_unix.a`.

### 4. What to run in the game

Use the same place every time — a scene whose CPU load is repeatable and which
does not depend on procedural generation:

- Load the same save/lobby, host a solo game (no other players: netcode timing
  is an uncontrolled variable).
- Stay on the **ship, doors closed, before landing**. Stand in one fixed spot
  facing the same direction — pick a landmark and use it every run. This is the
  most repeatable CPU load the game has.
- If you want a second, heavier sample point: land at the same moon
  (Experimentation) and stand just inside the main entrance, again facing the
  same way. Accept that indoor generation varies and treat this sample as
  noisier than the ship.

Do not move the camera while sampling — Metal HUD numbers move with what is on
screen.

### 5. What to record

From the on-device Metal HUD, per sample point:

- **Frame interval (ms)** — the number that answers the question. This is the
  CPU-bound one.
- **GPU time (ms)** — expected to be ~unchanged (the 8.32 ms baseline). If it
  moves, something other than TSO changed and the comparison is invalid.
- FPS, if the HUD shows it, as a cross-check on frame interval.

**Sampling, not a reading.** A single frame number is worthless here; frame
interval on this stack varies run to run and drifts with thermals.

- Let the game run **60 seconds after reaching the sample spot** before
  recording anything, so JIT warm-up and shader compilation settle.
- Then observe for **at least 2 minutes**, writing down the frame interval
  every 15 s → 8+ samples per run.
- Do **3 runs per arm**, each from a cold app launch (force-quit in between)
  → ~24 samples per arm.
- **Alternate arms** (strict, relaxed, strict, relaxed, …) rather than doing
  all of one then all of the other. The device heats up, and thermal
  throttling otherwise loads entirely onto whichever arm you ran second.
- Note whether the device is warm, and keep it plugged in or unplugged
  consistently.

Compare **medians**, not best frames. Treat anything under roughly 5% as
indistinguishable from noise at this sample size. The hypothesis is only
interesting if the relaxed arm is meaningfully faster — if it is within noise,
the answer is "the barriers were not the bottleneck" and the switch should stay
off.

### 6. Correctness, which is the harder half

**A short clean session is not evidence that relaxed mode is correct.** TSO
violations usually present as rare silent corruption — a value read stale once
in millions of iterations — not as an immediate crash. The failure mode is
that everything looks fine for twenty minutes and then something is subtly
wrong, or nothing visibly happens at all while a save file quietly rots. This
is why longer and repeated testing matters more here than for a typical change,
and why a per-title opt-in with a strict default is the only safe shape.

If the frame-time result is not clearly positive, **do not do this section** —
there is no reason to take on correctness risk for a change that bought
nothing.

If it is, run at least a few **30+ minute** sessions and watch for:

- **Desync / netcode:** in multiplayer, players seeing different item or enemy
  positions; an entity that exists for one client and not another; a client
  that drifts and never re-syncs.
- **State corruption:** inventory items vanishing, duplicating or changing
  slot; quota/credit totals wrong; a save that loads with the wrong contents.
- **Physics and AI:** entities stuck in geometry, teleporting, or frozen;
  doors/ladders/turrets not responding; an enemy that stops pathing.
- **Rendering:** flickering geometry, objects at the origin, UI elements
  stale or one frame behind — anything that looks like a value being read
  before the write that produced it.
- **Hangs:** a thread spinning on a flag that was published without ordering
  is a classic symptom. A freeze with no crash log is a strong signal here.
- **Crashes:** note the module and address. Compare against strict-arm
  crashes — this stack has its own background crash rate, so a crash is only
  evidence if it is new or much more frequent.

Run the **same sessions in the strict arm** as a control. Without that, you
cannot tell a TSO violation from a pre-existing Madeira bug.

Anything on that list means turn the title's entry back to `strict`. A
non-reproducing oddity still counts — the failure mode is rare by nature, so
"I only saw it once" is the expected shape of a real problem, not a reason to
dismiss it.

## Status

**Unvalidated in both directions.** No part of this has been run on hardware.

- **Performance:** unmeasured. Whether removing acquire/release from ordinary
  loads and stores produces any frame-time improvement in Lethal Company is
  exactly the open question, and it may produce none — the barrier overhead
  could be a small fraction of a frame that is CPU-bound for other reasons.
- **Correctness:** unmeasured. Unity, Mono and the CRT are all multithreaded,
  and whether any of them depends on x86 ordering in a way that matters here
  is unknown.

Do not ship a title with `relaxed` until both have been answered on device.

## Upstream

FEX-Emu's contribution policy prohibits AI-generated code, and this change was
AI-assisted. It is fork-local and must not be proposed upstream. It also
touches no FEX source, so there is nothing here to send: the option it uses is
upstream FEX's own, unmodified.

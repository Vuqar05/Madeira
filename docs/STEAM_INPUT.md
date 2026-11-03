# Steam Input through Valve's client

Goal: let Valve's own Steam Input, running inside the client Madeira Dock
already hosts, handle the controller for Steam games, instead of Madeira
re-implementing Steam Input (the community-layout importer in
`SteamInputLayouts.swift` / `PadKeyboardMouse.swift`).

Status: end-to-end gamepad input through the January client is verified for the
tested game/controller combination. The current remaining-work plan is
[Finish Steam Input integration](STEAM_INPUT_INTEGRATION_PLAN.md), covering game
defaults, community downloads and personal layouts. The notes and phased plan
below include earlier experiments; a queued cache load alone is not evidence
that a working binding exists.
The exact client SHA-256 remains pinned (`71b391fe…f640`).

## How Steam Input works on Windows (from the client DLL)

All of Steam Input lives in `steamclient64.dll`, the library Dock already loads.
`steam.exe` and the web UI are not needed for the input path itself.

- **Hardware.** The client's controller manager reads pads itself, through a
  statically linked SDL with its HIDAPI drivers ("Controller using HIDAPI
  driver, vid=…, pid=…", `SDL_JOYSTICK_HIDAPI_*`). On Windows HIDAPI means
  setupapi + `hid.dll` + `CreateFile`/`ReadFile` on the HID interface: the
  path Madeira's HID DualSense (`MADEIRA_PAD_MODE = hid`, served by
  `build/wineserver/hidpad_ios.c`) already answers.
- **Which pads.** Per-type opt-ins in the client config:
  `SteamController_PSSupport`, `_XBoxSupport`, `_SwitchSupport`,
  `_GenericGamepadSupport`, plus per-app `UseSteamControllerConfig`.
  PlayStation support defaults to "in games without PlayStation support".
- **Configs.** The client picks the layout for (app, controller type)
  itself: the developer's official config, a Workshop one, or the user's own,
  synced through Steam Cloud. API: `GetConfigForAppAndController`,
  `SetSelectedConfigForApp`, `LoadConfigFromVDFString`, `ActivateConfig`.
- **Outputs.**
  - Keyboard and mouse: `SendInput` from the client process (Dock).
  - Virtual Xbox pad: not a driver. The client writes pad state into a shared
    memory stream (`CXInputSteamMemStream`, `controllerxinput_win.cpp`) and
    `GameOverlayRenderer64.dll`, injected into the game, hooks XInput and reads
    it (`CXInputGameMemStream`, `ISpoofControllerXInput`). The overlay must both
    load in the game and successfully install its XInput hooks.
  - Native Steam Input games (`ISteamInput`, action manifests): the game asks
    the client over Steam IPC. No overlay needed.

## The interface Dock can drive

`IClientControllerSerialized` is a pipe-level interface (built with user 0 in
the pipe constructor, RVA `0x942a0b`), stored at pipe entry `+0x60`.

| What | January build |
|---|---|
| `CSteamClient` slot 66, `GetIClientControllerSerialized(this, HSteamPipe)` | RVA `0x943380` |
| `IClientControllerSerializedMap` vtable | RVA `0x12c9fd0` |
| slot 22 `GetNumConnectedControllers(this)` | RVA `0x765790`, IPC ID `0x9b1eac33` |
| slot 23 `GetAllControllersStatus` | `0x739640` |
| slot 24 `GetControllerDetails` | `0x749dd0` |
| slot 38 `LoadConfigFromVDFString` / 40 `ActivateConfig` | `0x81caa0` / `0x704ce0` |
| slot 80 `PS4SettingsChanged` / 82 `ControllerSettingsChanged` | `0x821920` / `0x725e70` |
| slot 102 `EnumerateControllers` | `0x731ca0` |
| slot 113 `SetControllerSetting` / 114 `SetSelectedConfigForApp` | `0x83bf90` / `0x84c100` |
| slot 121 `GetGamepadIndexForXInputIndex` | `0x756ea0` |
| slot 124 `GetConfigForAppAndController` | `0x7487a0` |
| slot 132 `GetControllerEnableSupport` | `0x749f70` |

Slot names come from each IPC wrapper's RIP-relative reference to its own name
string (149 slots, 0 to 148). The pipe-entry offset was cross-checked against the
neighbouring constructors: `+0x38`…`+0x50` are the four System managers
(slots 38 to 41) and `+0x58` is `IClientVRMap` (slot 61). The September build was not
inspected, so it gets no pins and the feature is off there, as with Friends.
Reproduce with `madeira-dock/tools/check-client-layout.py`.

## Feasibility

Possible. The parts that are already in place:

1. Valve's genuine client is running for the whole game (Dock stays up).
2. A HID DualSense the client's HIDAPI should be able to open.
3. A pinned path to the controller interface.

Open questions only a device can answer, in order:

1. Does the controller manager run in a headless client (no `steam.exe`)?
   Phase 1 answers this.
2. Does SDL's HIDAPI inside the client find and open `\Device\MadeiraHidPad0`?
   That needs Raw Input or `WM_DEVICECHANGE`, and both may be missing.
3. Is Steam Input switched on for the pad and the app? (`GetControllerEnableSupport`,
   the PS support setting.)
4. Do the outputs reach the game? `SendInput` from another process should
   work in Wine. The virtual Xbox pad needs `GameOverlayRenderer64.dll` in the
   game, which loads with `c000007b` today (`tests/host/check-log-summary.py`).
   Native `ISteamInput` games do not need it.

## Plan

### Phase 1: probe (this change)
- Dock: `steam_input.c`. Pin slot 66 and slot 22 for the January build, verify
  slot address, name and IPC ID, and report `steam-input-available` and
  `steam-input-controllers=N` (on change, polled once a second while the game runs).
  `MADEIRA_DOCK_STEAM_INPUT=0` turns it off.
- Madeira: a per-game Controller choice, **Steam Input**, for Dock launches.
  It exports `MADEIRA_DOCK_STEAM_INPUT=1` and makes player 1 a HID DualSense
  for that launch (`MADEIRA_HIDPAD=dualsense`), so the client's HIDAPI has a
  device to find. Player 1 leaves Madeira's own XInput (as in HID mode), so the
  game does not see the pad twice. Madeira's keyboard-and-mouse emulation is
  not used.
- Device test: a Steam game through Dock with a paired pad. Then read
  `[steam-host] steam-input-*` in the log.

### Device result 1 (2026-11-01)
`steam-input-available=1`, `steam-input-controllers=0`. Steam's
`logs/controller.txt`: `CHIDDeviceListSDL(): Couldn't load SDL3.dll, not
enumerating devices`. Wine refused `Steam\SDL3.dll` with `c000007b`: the January
client ships only a 32-bit SDL3 (for `steam.exe`, which owns controllers on
Windows), and no package of that build has a 64-bit one. The game itself read
the HID DualSense, which is why its buttons worked.

Fix: `build/sdl3/build.sh` builds upstream SDL at the commit Valve's copy
reports (`SDL-release-3.4.0-98-gb1362f8a4`), unmodified, for x86-64, and
stages it as `system32\SDL3.dll` next to `dockhost.exe`. It exports the same
1,271 functions as Valve's 32-bit copy. Steam tries its own folder first, which
fails, and then the search by name finds this copy.

### Device results 2 to 9 (2026-11-01)
- Polling `GetNumConnectedControllers` once a second broke up the game's
  audio. One call, 15 s after the launch, does not.
- `<appid>\UseSteamControllerConfig` (IClientUser store 1) set to 2 gives
  "Opted-in Controller Mask Forced On" for the game.
- The client-wide mask (`AppId 0`), which decides which pads the client
  opens, stays `1000` without the PlayStation setting. `SetConfigInt` for
  `SteamController_PSSupport` never reached the client's reader in any store.
- Desktop Steam (a CrossOver bottle) writes that setting to
  `userdata/<account>/config/localconfig.vdf`, at the top level of
  `UserLocalConfigStore`, and the client reads it when it starts. Madeira now
  writes `"SteamController_PSSupport" "2"` there before a Steam Input launch and
  puts the line back when the Dock session ends (`DockSteamInput` in
  `MadeiraDock.swift`).

### Device results 10 to 13 (2026-11-01)
- With `SteamController_PSSupport` 2 in localconfig.vdf the client-wide mask
  is `1001` (PlayStation pads in), and the game's mask is "Forced On".
- The client's `CSteamController::CHIDIO Thread` lists the virtual DualSense
  and reads its attributes, caps and strings, but never opens it for input.
- Wine's `CM_Get_Parent` was a stub, so SDL's HIDAPI saw no bus. With
  `CM_Get_Parent` reading a `Parent` value (wine branch
  `madeira-cm-get-parent`) and a registered USB composite parent, the client
  now detects USB and finds the USB device among
  `GUID_DEVINTERFACE_USB_DEVICE` interfaces, and still does not open the
  pad. The next check is inside the client's own HID code (not SDL).

### Device result 14 (2026-11-01)
Steam's `CHIDDeviceListSDL` builds non-Steam pads from SDL joysticks
(`sdl://N`), and in a headless client nothing starts SDL's joystick
subsystem. Dock now calls SDL's public `SDL_InitSubSystem(SDL_INIT_GAMEPAD)`
once the client has loaded `SDL3.dll`. Result: `steam-input-sdl-init=1`,
`steam-input-sdl-joysticks=1`, and in `controller.txt` "Local Device Found
… path: sdl://2", "Controller using HIDAPI driver", "Steam controller device
opened for index 0", "reserving XInput slot 0", PollState 0 to 1, and the
account's config sets for the DualSense loaded. `steam-input-controllers=1`.
Audio stayed fine. Next: which layout is active for the game, and whether its
output reaches the game (virtual XInput needs the overlay).

### Phase 2: switch it on
- If the count is 0: trace the client's HID enumeration (Wine `+hid,+setupapi`
  for the Dock process) and fill what Madeira's HID device misses.
- If N ≥ 1: pin `GetControllerEnableSupport` / `SetControllerSetting` /
  `PS4SettingsChanged`, so Steam Input can be forced on for PlayStation pads in
  this app. Log `GetConfigForAppAndController` to see which layout Valve chose.

### Phase 3: outputs
- Keyboard/mouse layouts: check that the client's `SendInput` reaches the game
  window.
- Native `ISteamInput` games: should work once phase 2 does.
- Gamepad layouts (virtual Xbox pad): make `GameOverlayRenderer64.dll` load in
  the game, or serve the client's XInput memory stream to Madeira's XInput.
  That second route is undocumented, so the overlay comes first.

### Phase 4: retire the imitation
- Once phases 2 and 3 work, the community-layout importer and
  `PadKeyboardMouse` become the fallback for non-Steam games only.

## Loader and installation corrections (2026-11-02)

The pinned January client's `LoadConfigFromVDFString` and `SetFocusedWindow`
return **void**. The old bool declarations produced arbitrary values (including
255) in success logs. The report now distinguishes `layout-queued`,
`mapping-cached` (HasGameMapping, slot 128) and `activation-requested`; none
asserts that the overlay has delivered input to a game.

Dock now checks the indexed `IsControllerConnected(0, false)` before loading,
asks `GetConfigForAppAndController` for the selection key, resolves its bare
template name or account-local autosave (also accepting legacy template URLs
and Steam-local files), waits for the asynchronous mapping cache, then
resets the enable cache, warms and activates. Focus changes re-request activation
without overwriting or reloading a user's selection. Late enumeration, failed
SDL initialization, bounded file/cache retries and reconnection no longer depend
on the first foreground-PID change. Full controller enumeration remains one-shot
because it previously interrupted audio.

Reproducible installation also needs:

- Valve's pinned `public_all` package (including `controller_base`), with its
  size and full SHA-256 checked. Its 3,832 ZIP entries exceed the old 256-entry
  reader limit; the bounded limit is now 4,096. Fresh setup includes it, and a
  Steam Input launch adds missing controller files to an existing verified
  client installation without replacing differing files.
- The x64 SDL3 DLL and notices in the Dock runtime build/cache contract, excluded
  from Wine's DLL-source inventory. `build/sdl3/windows-x64.cmake` keeps the
  Windows cross-target during CMake regeneration.
- A PlayStation opt-in file for first-time accounts. The single-key editor
  accepts and preserves CRLF, and failed restoration retains its recovery note.
  Setup errors abort preparation instead of silently starting a controllerless
  session.

Validation: Dock's C lifecycle tests run under ASan/UBSan, the client ABI checker
verifies every called slot against the actual pinned DLL, Swift settings tests
exercise CRLF/first-account/recovery cases, and the ZIP test extracts the real
pinned public package. An isolated, unsigned-in Windows parser probe accepted
Valve's PS5 Gamepad template and reported XInput feature 1. The full iOS Debug
build succeeds. The first two device retests stopped before loading: the first
guard required a template URL, and the second accepted paths but still rejected
bare names. Inspection of January SteamUI.dll's resolver (`0x544440`) established
that the client returns selection keys, including bare template names and
`AC-app-device` autosave keys. The resolver now handles both, with host tests
checking the actual file paths.

The next device run confirmed the selected autosave was queued, cached and
activated. A read-only diagnostic of the January client's `SteamXInput` shared
stream then confirmed slot 0 was reserved, connected and producing changing
gamepad state. Steam's controller engine is producing output; this does not
establish delivery to the game.

### Game-side hook writes (2026-11-02)

The overlay log prints `XInput Hooked` even when its preceding
`WriteProcessMemory` failed. Madeira's `NtWriteVirtualMemory` sent every write
through the wineserver, whose iOS pseudo-processes deliberately have no task
port for writes. Consequently even the overlay's writes to its own process
were denied. Earlier notes treating `XInput Hooked` as a successful hook were
incorrect.

The current-process pseudo-handle now uses a local, protected copy in
`build/ntdll-unix/virtual_ios.c`, matching the local read path. JIT destinations
use their writable aliases; other process handles still take the unchanged
server path. The host test exercises ordinary, overlapping and aliased writes,
read-only and overflowing destinations, and denial for another process handle
under ASan/UBSan. The full iOS runtime and app build succeed.

Device verification: the user confirmed the controller works in the game.
The final overlay log contains nine XInput hook reports and zero
`WriteProcessMemory` failures; the app log records successful local five-byte
writes and a connected Windows.Gaming.Input gamepad for XInput slot 0.
The Dock report confirms connected, changing Steam output. This establishes
end-to-end input for the tested game/controller combination; it does not
establish every layout type, controller model or rumble path.


### Selection service foundation (2026-11-02)

The session-bound read-only query service now has matching C/Swift wire codecs,
atomic feed installation/command claiming, launch/game/controller lease and
sequence checks. Its feed exposes a selected key/Workshop identity, queued state,
generic cache presence and activation-request state separately. There is no
active-revision acknowledgement yet; apply/reset return an explicit unsupported
result and do not change layouts. The app retains the observed Steam selection
alongside an explicit Madeira choice in a versioned account/game/controller
store. Dock's own generic fallback is flagged and excluded from this migration.
The controller identity currently represents the virtual slot-0 bridge.

The transport forwards ordinary buttons/D-pad, sticks, analog triggers and Sony
touchpad click where supplied; it does not sample motion, touch coordinates,
rear buttons or extra Deck/Steam Controller touch inputs. The service exposes
this transport mask without claiming every physical pad supports every group.
Wire details and result codes are in the Dock README; outstanding work and
validation boundaries remain in `STEAM_INPUT_INTEGRATION_PLAN.md`. Host sanitizer,
cross-language migration, selection/settings tests and both PE builds pass.
This new service has not been validated on device.


A subsequent full iOS Debug build succeeds and the signed
`Steam Input M1 · 11-02` build is installed on the connected iPad. This includes
an observer for Valve's public configuration-loaded callback 2803 (exact x64
40-byte bounds, launched-app filtering, capped numeric reporting; creator
identity skipped). Its revisions describe the action manifest and cannot by
themselves acknowledge VDF bytes. Device service/callback verification is
pending. Static server tracing found that the private configuration/revision
getter candidates operate on binding objects, not a controller index, so they
are not enabled as active-layout getters.


The first M1 service test found a disconnected feed and no SDL-init event: the
directly built app omitted the required x64 SDL3 DLL. `build/madeira-dock/build.sh`
now builds/stages SDL3 and its notice, and runtime validation rejects other
architectures and missing dependency files. The corrected `Steam Input M1 R2`
build is installed with all required Dock files checked in its bundle. Its
controller/service/callback runtime acceptance is pending a new game launch.


R2 device verification now confirms SDL/controller initialization, successful
layout query, observed-selection migration, connected/changing Valve output and
public configuration-loaded callback delivery. Live source-query and stale/
replay/malformed command tests pass; reserved apply/default return result 7 and
preserve the connected layout. A normal relaunch/reconnect check is pending.
The public manifest revision remains 0/0 for this test and is not a VDF content
acknowledgement. Exact-revision apply/restore/rollback remain incomplete; the
pinned private load-completion callback is the next investigation lead.


R2 acceptance correction: the owner observed PlayStation glyphs and working
physical reconnect input. The submodule sources/pins match the earlier verified
worktree, but this checkout's ignored native archives were stale. The linked R2
app lacked the overlay's local current-process write fix and the server HID-owner
restriction, so its engine/query/migration checks do not establish Steam-to-game
input delivery. Both native libraries were rebuilt from source and the full app
relinked. `tools/check-steam-input-runtime.py` rejects the old bundle and passes
the rebuilt app; the IPA packaging path now runs it. The corrected signed
`Steam Input M1 R3 · 11-02` build is installed; glyph/overlay/game-input validation
is pending. After normal relaunch the service has a fresh nonce, a successful
query and the same selected autosave. Virtual epoch 1 persisted: physical
reconnect is not proof of a virtual-controller lease transition.


R3 device result: the owner confirms controller input with Xbox glyphs. The
overlay log has nine XInput hook reports and zero memory-write failures; Dock
reports initialized SDL, gamepad configuration-load notification and connected,
changing Xbox output. The linked native runtime passes the new capability
preflight. This restores Steam-to-game input for the tested combination. The
reference and current worktrees already have the same submodule pins; ignored
native build outputs were the mismatch and were rebuilt from source here.
Exact-VDF-revision acknowledgement and fixture apply/restore/rollback remain
outstanding; working Xbox input alone does not close milestone 1.


R4 is installed for an opt-in native document-revision experiment. The private
load-result callback carries the VDF `revision`, distinct from public manifest
major/minor values; its exact layout and source were checked against the pinned
binary. A bounded reader compares it with queued bytes without altering them.
An explicitly compiled one-shot action-5 diagnostic applies a synthetic
face-button-only A/B swap (revision 731) and attempts original-byte restoration
after the observation window. Ordinary builds reject it; normal apply/default
commands remain disabled. Sanitizers, C/Swift regressions, cross-builds, full
Debug app build and native capability checks pass. The owner confirmed the
live A/B swap and automatic restoration in a fresh-session menu test. Completed
callbacks reported revision 731 then original revision 0, and the selected VDF
remained byte-for-byte unchanged. This verifies the serialized diagnostic path;
ordinary apply/default, persistence and rollback remain unimplemented. See Dock
README/HANDOFF for the protocol and test boundaries.

The next diagnostic prepares private apply/restore copies with distinct native
document revisions greater than both originals. Only root revision metadata
changes; source files and unknown binding bytes stay untouched. Matching the
old startup revision cannot acknowledge restoration. Bounded materialization
and delayed-callback rejection are covered by host tests. R5 device validation
passed: the owner observed the swap and restoration, completed callbacks reported
732 then 733, and the original selected VDF remained byte-for-byte unchanged.
Ordinary apply/default remain disabled pending production transaction handling.

Local transaction preparation is implemented separately from live application.
A portable coordinator serializes revision reservations and requires a matching
private completion plus activation request; timeout initiates a single bounded
rollback and a failed rollback leaves only a historical working receipt. The
app uses the same C metadata code to prepare queue copies. Its scoped journal
synchronizes revision reservations and records immutable SHA-256-addressed
source, baseline, apply and rollback objects. Receipts must match reservation,
launch nonce, epoch, sequence, hash and revision. Launch/end/reconnect interrupt
unfinished work instead of replaying it or treating it as active. Local
preparation can persist an explicit requested template/personal layout; it sends
no native mutation. Ordinary apply/default and startup reapplication remain
outstanding. Host tests cover coordinator and real filesystem recovery behavior;
these additions do not extend the installed R5 device evidence to production
application.

The local submission/receipt bridge now connects the coordinator and journal,
behind `DOCK_LOCAL_APPLY=1` (ordinary builds stay disabled). Capability flag 16
advertises it. Action 3 consumes a scoped, bounded two-layout envelope with native
revisions and SHA-256 digests, verifies those digests and the current rollback
baseline, and waits for exact completion before activation. Atomic transaction
receipts distinguish accepted, applying, confirmed, rollback and unknown working
state. Swift journals before sending and only updates lastActivated for a fully
matching receipt; generic acceptance/state/cache observations cannot do that.
Host tests cover the endpoint, CryptoAPI boundary, failed/overlapping requests,
rollback/late callbacks, cleanup, and C-to-Swift receipt persistence. Device
validation, startup reapplication and held-output recovery remain outstanding.

R6 native endpoint device validation passed: command-based apply revision 732 and
separate restore revision 734 each returned their expected SHA-256 receipts.
The owner observed the button swap and restoration; the original selected VDF
remained byte-for-byte unchanged. The sender was an external test tool, so app
journal persistence, startup reapplication and device failure/held-output recovery
remain unverified. The production build gate remains in place.

Startup reapplication is now implemented behind the existing local-apply gate.
Capability 32 advertises an atomic, scoped exact working-layout snapshot. The
app waits for that fresh baseline and a completed query, proves stored source
bytes against a historical confirmed queue, then uses normal preparation,
submission and hash-bound receipts to reapply the last confirmed choice once
per fresh launch. It preserves newer unconfirmed requests, consumes no old
revision twice, and cannot mark historical acknowledgement active before a new
receipt. A bounded source-confirmation history survives fallback to Steam's
baseline. Interrupted old-launch reservations can be retired only with a new
scoped baseline; same-launch connection recovery remains explicit. Clearing an
explicit request preserves history and delegates subsequent startup to Steam.
Host coverage includes persistence/relaunch, wrong nonce/baseline rejection,
newer-intent preservation, rollback history and the scoped Debug-only fixture
trigger that will exercise app-side persistence on iPad. Device validation and
held-output/failure recovery remain outstanding; R6 is still the last installed
validated build until R7 is installed/tested.

R7 app-side device validation passed: the app persisted fixture acknowledgement
at revision 732, automatically reapplied it after normal relaunch with a fresh
nonce at revision 734, then restored the captured original mapping at revision
736 and persisted cleared explicit intent. The owner confirmed swapped behavior
after relaunch and normal behavior after restore; the original selected VDF was
byte-for-byte unchanged. Cleared-intent relaunch and fault/held-output recovery
remain to be verified before production enablement.

The final R7 cleared-intent relaunch also passed on device. A fresh nonce, native
state activation-requested and sequence/result 1/1 established query-only startup;
the journal retained the previous launch's restore receipt rather than adding a
new transaction. Explicit intent remained nil, the exported native baseline
exactly matched the pre-test original VDF, and the original selected source was
unchanged. The owner confirmed buttons remained normal. Persistence, relaunch,
restoration and override cleanup are device-validated; fault/reconnect and
held-output behavior remain outstanding before ordinary-build enablement.

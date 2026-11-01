# Steam Input through Valve's client

Goal: let Valve's own Steam Input, running inside the client Madeira Dock
already hosts, handle the controller for Steam games, instead of Madeira
re-implementing Steam Input (the community-layout importer in
`SteamInputLayouts.swift` / `PadKeyboardMouse.swift`).

Status: research done, phase 1 (probe) implemented, phases 2 to 4 need device
results. Analysis was static only (PE/RTTI and disassembly of the pinned January
`steamclient64.dll`, SHA-256 `71b391fe…f640`). No Valve code was executed.

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
    it (`CXInputGameMemStream`, `ISpoofControllerXInput`). Without the overlay
    in the game there is no virtual Xbox pad.
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

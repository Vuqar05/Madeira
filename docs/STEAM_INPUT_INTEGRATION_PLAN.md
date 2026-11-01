# Finish Steam Input integration

Updated: 2026-11-02. Status: implementation plan; unchecked items are outstanding.

This is the current plan for using Valve's Steam Input engine in Madeira.
`STEAM_INPUT.md` records the investigation and verified runtime fix.
The separate `steam-input-layouts` branch contains the older
`docs/STEAM_INPUT_PLAN.md` and community-layout import/emulation work. That branch
is not merged into `main`; its milestones are not evidence of functionality on
this branch or of layouts running through Valve's engine. Review and port any
useful individual components explicitly; do not merge that alternative solution.

## Outcome

For a Steam game launched through Dock, a player can:

1. Use the game's recommended/default Steam Input layout.
2. Browse, download and apply a community layout.
3. Create, edit, save, duplicate, import and export a personal layout.
4. Switch between these choices, restore the game default and retain the choice
   across launches. Valve's engine executes the selected layout.

The existing Madeira controller editor remains available for its existing uses.
Steam Input layout selection must have its own persisted state and execution path.
Selecting a Steam layout must not silently change the game to Madeira's keyboard
and mouse mode or discard bindings that the existing importer cannot represent.

## Verified starting point and concrete gaps

| Area | Current evidence | Work still required |
|---|---|---|
| Controller transport | A paired pad reaches Valve through Madeira's virtual DualSense | Verify additional hardware, motion, touch and reconnect behavior |
| Gamepad output | User confirmed game input; overlay writes succeed and Windows.Gaming.Input sees a pad | Broader games, output types, multiplayer and lifecycle tests |
| Layout loading | Dock resolves template names, Steam-local paths and account-local autosaves, then queues/cache-checks/activates | A complete resolver for official, Workshop and personal selections |
| Game default | An existing cached selection can load; absent selection falls back to the PS5 Gamepad template | Resolve the actual game recommendation; a generic template is not proof of the game's default |
| Community browser | The separate `steam-input-layouts` branch has a public listing/download implementation; it is absent from main | Implement or selectively port listing/downloads, preserve raw files and apply them through Dock; `selected_workshop != 0` currently prevents loading |
| Custom layouts | The separate branch has a `ControllerSetup` JSON editor/importer; it is absent from main | Lossless Steam layout editing, serialization and application through Valve |
| Runtime control | Startup activation and refocus handling exist, currently centered on controller index 0 | Acknowledged layout-change commands, per-controller state and safe live switching |

Current implementation: `madeira-dock/src/steam_input.{c,h}` and
`app/Madeira/{MadeiraDock,Library}.swift`. Optional reference code on the separate
branch: `app/Madeira/{SteamInputLayouts,SteamInputLayoutsView}.swift`.

## Implementation rules

- Keep Valve's client, real authentication, ownership checks and game DRM intact.
- Verify each new private client method against the pinned binary: signature,
  lifetime, slot/address, IPC identifier and asynchronous completion behavior.
  Unknown client builds disable the adapter with a clear explanation.
- Use Valve to evaluate layouts, actions, activators, layers and output behavior.
  Reuse existing UI/parsing where appropriate without converting native layouts
  into the reduced `ControllerSetup` representation.
- Preserve unrecognized VDF fields, repeated keys and ordering when editing.
  Preserve untouched original bytes as well as editable revisions.
- Keep game/controller/account selections isolated. Do not overwrite an existing
  selection just because a network request or download fails.
- Bound downloads, parsing, command inputs and retries. Use atomic installation,
  revision checks, cancellation and rollback. Never log credentials or account data.

## Milestone 1 — Selection model and a reliable Dock layout service

- [ ] Add a versioned per-game selection model: Game default, Community item,
  Personal layout, or explicitly selected template. Record controller identity,
  source, revision/content hash and last successfully activated revision.
- [ ] Distinguish an explicit choice in Madeira from an existing Steam selection.
  On migration, retain both and avoid replacing either without an explicit choice.
- [ ] Define the bridge between Madeira and Dock for querying the current layout,
  listing available sources, applying a revision and restoring the game default.
  Reuse the existing session-command transport where suitable after inspecting it.
- [ ] Bind each command to the current session, game and controller; include a
  sequence ID and structured result. Reject stale commands and unsafe file paths.
- [ ] Separate requested, downloading, validated, queued, cached and active states.
  An activation request or generic cache presence is not an acknowledgement that
  the requested layout revision became active. Determine a reliable client-side
  acknowledgement and verify it through a distinctive changed mapping.
- [ ] Route startup selection and live changes through the same service. Preserve
  the last working revision on failure and serialize conflicting apply requests.
- [ ] Inventory physical inputs that Madeira actually forwards to the virtual
  controller; expose compatibility accurately, including Deck/Steam Controller
  inputs that the current device cannot provide.

Done when: a local fixture can be selected, acknowledged, used in-game, restored
and retained after restart without affecting another game's selection. Failed or
stale requests leave the previous working layout usable.

## Milestone 2 — Use the game's default layout

- [ ] Inspect how the pinned client resolves developer recommendations, native
  action manifests and controller-specific defaults. Record the proven APIs and
  data sources; do not assume the current GetConfig call discovers recommendations.
- [ ] Resolve and fetch the game's recommended layout and dependencies through
  verified client mechanisms. Handle game metadata that is not yet cached.
- [ ] Implement Game default as an explicit reset to Valve's current recommendation,
  distinct from the user's previous custom/community selection.
- [ ] Preserve existing Steam selections during migration and show which layout is
  active, where it came from and whether the player has overridden the default.
- [ ] Offer a clearly named generic template only when no game recommendation is
  available. Do not label it as the developer's layout or silently apply it after
  a transient failure. Allow retry or an explicit fallback choice.
- [ ] Verify native Steam Input manifests/action sets independently of XInput-only
  games; the current Gamepad template cannot serve as proof of native action support.

Done when: a fresh install with no hand-copied controller files obtains a game's
recommendation, visibly uses its distinctive bindings, and restores it after a
community/custom override. Also test a game without a recommendation and offline
use of a previously cached default.

## Milestone 3 — Download and apply community layouts through Steam Input

- [ ] Implement the public layout query/cache, using the separate branch's
  `SteamInputLayouts.swift` as a reference or selectively porting appropriate
  components. Add pagination, refresh, search/filtering and controller compatibility
  information. Verify the service behavior during implementation.
- [ ] Keep the original VDF and Workshop identity/revision, including bindings the
  legacy importer does not understand. Make raw validated content available to Dock.
- [ ] Implement the pinned client's Workshop selection/download resolver. Inspect
  the actual UGC download and selection contract before choosing whether the client
  or Madeira supplies the bytes. Remove the current nonzero-Workshop-ID rejection
  only once this path is implemented and tested.
- [ ] Handle private/deleted items, missing URLs, unsupported formats, incompatible
  controller inputs, interrupted transfers and revisions that change mid-download.
  Validate a response and its game association before installing it.
- [ ] Apply a community layout via the new service and acknowledge the active
  revision. Preserve attribution and let users return to Game default.
- [ ] Cache complete revisions for offline reuse. Detect updates and offer an
  explicit update while retaining the previous working revision for rollback.
- [ ] Let a user copy a community layout into a personal layout for editing without
  modifying the downloaded original or losing its attribution.

Done when: a downloaded layout changes a known binding in-game through Valve's
engine, survives relaunch and works from cache offline. A failed download/update
does not erase the active layout. Test keyboard/mouse and mixed-output layouts,
not only layouts that emit Xbox buttons.

## Milestone 4 — Create and edit personal Steam Input layouts

- [ ] Build an editable Steam layout model and lossless VDF writer. The separate
  branch's parser preserves repeated keys and may be useful as a reference, but
  its import-to-JSON path is not a native Steam Input layout writer.
- [ ] Support creating from the game default, a template, a community copy or an
  existing personal VDF. Assign stable local identities and revision history.
- [ ] Reuse editor controls where possible, backed by the native model. Implement
  buttons/chords, stick and trigger behavior, dead zones/curves, activators,
  toggle/turbo, action sets/layers/mode shifts, gyro, touchpad and menu bindings.
- [ ] Use the game's action manifest for named actions in native Steam Input games.
  Validate references to groups, action sets and layers before applying changes.
- [ ] For fields outside the editor's supported surface, preserve them and clearly
  show that they cannot yet be edited. Never remove them on an unrelated save.
- [ ] Add draft/save/apply, undo/redo, duplicate, rename, delete, restore default,
  VDF import/export and a recovery path for invalid or incompatible files.
- [ ] Make deletion safe for active/referenced layouts and retain the prior revision
  until a replacement is acknowledged. Live editing releases held outputs before
  switching and restores the working revision if validation/activation fails.
- [ ] Store personal layouts persistently and register/select them using the pinned
  client's proven local-layout contract. Do not invent Steam selection keys.
- [ ] Establish whether account cloud sync is supported by this client path. If it
  is, implement conflict handling and test it; otherwise label layouts as local
  and provide explicit import/export. Do not claim cloud backup without evidence.

Done when: a player creates a layout, changes a recognizable binding, uses it in
the running game, restarts and gets the same result. Export/import preserves
behavior and unknown fields. Editing a community copy leaves the original intact.

## Milestone 5 — Complete controller behavior and session lifecycle

- [ ] Verify keyboard/mouse delivery, mixed Xbox/key output and native actions.
  Investigate any cross-process input restrictions with focused runtime tests.
- [ ] Verify rumble and supported controller feedback through Valve to the physical
  pad; stop feedback on disconnect, game exit and session interruption. Expose
  unsupported feedback capabilities honestly.
- [ ] Verify gyro/touchpad samples, orientation, timestamps, enable conditions and
  menus. Where Valve's menus require overlay rendering that Madeira cannot yet
  provide, implement that integration before marking those layout features complete.
- [ ] Handle additional controllers and stable player assignment. Extend the current
  index-0 design so selections, reconnects and outputs target the correct device.
- [ ] Define and test on-screen controller behavior with Steam Input, including
  coexistence with a physical pad and whether they share or occupy separate slots.
- [ ] Test focus loss, background/foreground, suspend/resume, hot unplug/replug,
  late connection, repeated launches and rapid layout changes; release held keys,
  buttons and feedback without duplicate events or stuck input.
- [ ] Make ordinary Steam Input selections available from Game details and the
  session menu. Keep user-facing states understandable: active layout, pending
  download, retry, incompatibility and apply failure.
- [ ] Route Steam Input editing to the native path. If migration from layouts
  created with the separate emulation solution is offered, make it explicit and
  preserve saved work; do not pull that solution into main as an implicit fallback.

Done when: the supported controller/output matrix passes device testing, per-player
layouts remain correct, and switching/reconnecting causes no stuck input, duplicate
pads or regression to ordinary XInput/DirectInput controller modes.

## Milestone 6 — Release validation and reproducible delivery

- [ ] Add focused parser/writer round-trip, source-resolution, command-lifecycle,
  download/cache, account-isolation, migration and rollback tests. Use synthetic or
  redistributable fixtures rather than personal account files or captured credentials.
- [ ] Check every new private API pin against the real supported client binary;
  cover mismatches and unknown builds. Test async failure paths under sanitizers.
- [ ] Run device acceptance tests for fresh setup, a recommendation, no recommendation,
  a community layout, a custom layout, native actions, offline cache and failed update.
- [ ] Test several games and available controller families. Record exactly which
  inputs, outputs, controller counts and layout features are supported or untested.
- [ ] Verify a clean source/runtime build and fresh-device setup, including public
  controller files, x64 SDL, Wine and Dock components and notices. Rebuild archived
  runtime components from source rather than depending on copied development files.
- [ ] Compare audio, frame pacing, memory and startup time with the verified baseline.
  Avoid frequent full controller enumeration, which previously interrupted audio.
- [ ] Reduce temporary diagnostics to bounded, useful support reporting. Update
  `STEAM_INPUT.md`, controller documentation and Dock's README/handoff to agree.
- [ ] Commit component changes and parent repository references together; verify
  required commits/artifacts are obtainable before distributing a release.

Done when: the three requested user journeys work end to end from a clean install,
their selections persist and can be reversed, and the release has an explicit tested
support matrix. A passing generic Gamepad test alone does not close this plan.

## Order and completion boundary

Implement milestones 1 → 2 → 3 → 4, then finish the cross-cutting work in 5 and
the release checks in 6. Validate each milestone on device before building on it.
The next implementation task is the selection model and acknowledged Dock service,
followed immediately by resolving a real game recommendation from fresh metadata.

Local custom layout creation and VDF sharing are required here. Public Workshop
publishing, new client-build adapters and hardware-specific features absent from
the physical controller are separate extensions; publishing is not required to
download community layouts or create personal layouts. Any selected layout feature
that the supported hardware can supply must either work or be shown as unsupported
before the user applies that layout.

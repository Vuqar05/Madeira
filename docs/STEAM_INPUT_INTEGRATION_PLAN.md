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

Implementation progress (2026-11-02, partial):

- `DockSteamInputSelection` provides a versioned atomic store scoped by account,
  App ID and controller UUID, keeping the explicit Madeira request, original
  observed Steam selection and last acknowledged content revision separate.
  Unknown schemas/mismatched scopes fail without replacing saved bytes.
- The app now creates a launch nonce with the authenticated handoff, queries the
  new Dock service once per observed connection (bounded retries), and retains
  the Steam selection without replacing an explicit Madeira choice. Dock's
  own startup generic fallback is flagged and excluded from migration.
- `steam_input_service.{c,h}` defines a bounded LE command/feed protocol with
  session, game, index, connection epoch, monotonic sequence and result. Query
  and existing-source discovery work; apply/reset return an explicit no-ACK
  result without mutating the layout. Commands accept no paths. Atomic feed
  installation, command claiming, cleanup and publication retry are implemented.
- Reports distinguish queued, generic cache presence and activation requested;
  no observation is labelled an active revision. The transport input inventory
  exposes buttons, sticks, triggers and optional Sony touch click, with motion,
  touch positions and extra Deck/Steam Controller inputs absent.
- The stable UUID currently identifies Madeira's single virtual DualSense bridge,
  not a physical pad. Physical identity, additional controllers, source browsing,
  UI and applying/restoring revisions through one service remain outstanding.

Validation: Dock ASan/UBSan suites, C/Swift interoperability, selection and
settings tests, normal x64/x86 cross-builds and the pinned January checker pass.
R3 restored the verified Steam-to-game route after rebuilding stale native
archives; Xbox glyphs/input and nine successful overlay hooks were confirmed.
R4's device experiment passed: the owner observed the synthetic revision-731
A/B mapping swap and its automatic restoration after the observation window.
Private completed callbacks reported revision 731 and then baseline revision 0;
the original selected VDF was byte-for-byte unchanged. The first run verified
restoration/file preservation but lacked physical observation; a fresh-session
retry supplied the distinctive mapping confirmation. This validates the pinned
callback as evidence for this serialized queue/restore experiment, independently
of public manifest revisions. It does not establish general callback ordering,
held-input release, crash recovery or arbitrary layout persistence. Normal builds
cannot run the diagnostic, and ordinary apply/default remain disabled.
`madeira-dock/docs/CLIENT_LAYOUTS.md` records the pinned binary evidence.
Milestone 1 remains incomplete: production application must bind unique document
revisions to validated immutable content, serialize transactions, and implement
acknowledged persistence, default restoration and rollback.

Revision-tagged queue copies (R5, device validated): bounded native VDF
materialization changes only root document revision metadata in private queue
copies, preserving unknown bindings and source bytes. The one-shot diagnostic
now reserves distinct apply and restore revisions above both source revisions,
fails on exhaustion, and rejects a delayed startup completion during restore.
This removes the baseline-revision reuse in the R4 experiment; it does not yet
provide persistent revision allocation, content-hash binding or production apply.
The owner confirmed the live swap and automatic restoration. Completed callbacks
reported apply revision 732 and restore revision 733, probe phase reached 4,
and the original selected VDF was byte-for-byte unchanged. This verifies native
acceptance of both metadata-tagged copies; persistent transaction/content binding
and ordinary apply/default remain outstanding.

Production transaction preparation now has a portable coordinator and an app-side
journal/content store. The coordinator reserves non-reused apply/rollback
revisions, serializes changes, requires matching completion plus activation
request, bounds rollback, invalidates old connections and retains historical
working receipts without calling them current after failure. The journal scopes
atomic, synchronized records by account/game/controller, preserves source and
baseline bytes separately from tagged queue copies, rehashes immutable objects,
and binds receipts to reservation, launch nonce, epoch, sequence, revision and
hash. The same C metadata implementation is compiled into iOS, avoiding a second
VDF transformer. Local preparation persists an explicit requested source but
sends no apply command and never sets lastActivated. Launch/end/reconnect mark
unfinished work interrupted; recovery requires an explicit later decision.
The local submission/receipt bridge is implemented and host-tested behind the
explicit `DOCK_LOCAL_APPLY=1` build gate. It consumes scoped, bounded payloads,
verifies exact SHA-256 digests and the working rollback baseline, serializes
native submission, and waits for matching completion before activation. Swift
journals the command before sending and only updates lastActivated after a
matching session/epoch/sequence/revision/hash receipt. Native rollback and late
callbacks have lifecycle coverage. R6 device validation of the native endpoint
passed: a scoped apply confirmed revision 732 with the expected SHA-256, and a
separate restore confirmed revision 734 with its expected SHA-256. The owner
observed the A/B swap and restoration, and the original selected VDF was
byte-for-byte unchanged. This external-sender test validates the native command
and receipt path, not app-side journal persistence or startup reapplication.
Normal/probe/local sanitizers, C/Swift submission/receipt and journal/selection
regressions, ordinary x64/i386 and gated x64 builds, pinned client/runtime checks
and the iOS Debug build pass. App persistence/restart validation, held-output handling,
failure recovery on device and enabling ordinary builds remain outstanding.

Restart implementation (R7, app persistence/relaunch device-validated): the gated host
publishes a nonce/game/epoch-bound exact working-layout snapshot only after it is
settled (capability 32). The app validates that snapshot, proves cached source
bytes reproduce a prior confirmed queue, and reapplies the last confirmed choice
through the live transaction path with fresh revisions. Newer unconfirmed intent
is preserved. A bounded confirmation history survives rollback to Steam's initial
baseline. Interrupted old-launch work is retired without replay only after a
new scoped native baseline, and same-launch/connection recovery stays blocked.
Clearing an explicit request retains historical acknowledgement but delegates
future startup to Steam's existing selection. A scoped Debug-only fixture trigger
allows the next device check to exercise the real app journal, relaunch and
baseline restoration without a layout UI; it is absent in Release builds.

R7 is built and signed for that app-mediated persistence/relaunch test. Host
sanitizers, C/Swift service/journal/selection checks, runtime component/settings
regressions, ordinary and gated cross-builds, pinned client/runtime preflight and
the iOS Debug build pass. R7 device testing confirmed app-mediated selection and persisted acknowledgement
at revision 732, automatic reapplication after a normal game relaunch at revision
734 with a fresh launch nonce, and app-mediated restoration at revision 736. The
owner observed swapped buttons after relaunch and normal buttons after restore.
The app persisted cleared explicit intent; the original selected VDF remained
byte-for-byte unchanged. A further fresh launch kept explicit intent cleared, issued only the startup
query, loaded the exact original native baseline and left the selected source
unchanged; the owner confirmed normal buttons. Fault/reconnect and held-output
cases remain to be verified.

Fault/reconnect, interrupted-transaction and held-output implementation (R8,
device-validated): same-session virtual controller lease changes clear the
previous epoch's load completion, reload the new epoch's baseline when no active
transaction is in flight (including after `.cancelled`), republish a fresh
`MSIBAS02` working snapshot once the new epoch settles, and allow
`abandonInterrupted` across a newer epoch in the same launch (`newEpoch > request.epoch`)
while still rejecting same-session same-epoch retirement. Physical controller
disconnect/reconnect on iOS updates the neutral/live report state of the permanent
virtual DualSense (`\Device\MadeiraHidPad0`) without a virtual lease change; the owner
physically disconnected and reconnected the controller in-game and confirmed the swapped
mapping and normal operation survived without stuck buttons. App-side baseline
restoration uses `prepareBaselineRestore`, leaving `selection.requested` untouched
until a matching confirmed receipt arrives so an interrupted or rejected restore
never replaces saved user intent. Exhausting the five `HasGameMapping` cache-wait
retries during an applying or rolling-back transaction immediately invokes
`sh_input_tx_fail` rollback or terminal failure rather than waiting out the 15-second
completion deadline. Held inputs and outputs are gated on both sides:
`DockSteamInputService` exposes `inputQuiesced` while a layout change is prepared or
in flight so `GamepadInput.sample()` publishes a connected DualSense at rest and
latches held buttons until physical release after confirmation, rollback or failure;
natively, `observe_output` tracks live `SteamXInput_mem-IPCWrapper` button and axis
values beyond standard XInput deadzones (`output_held`) and defers transaction
`ActivateConfig` until XInput output returns to rest, bounded by the 15-second
transaction deadline. In `#if DEBUG`, the diagnostic mailbox exercises action 1
(apply probe fixture), action 2 (restore baseline), action 3 (deliberate baseline-mismatch
rejection) and action 4 (interrupted local preparation).

R8 device verification passed on the connected iPad. Applying the revision probe
confirmed at revision 738 (native sequence 2, epoch 1) with the owner confirming
swapped buttons and no stuck inputs. Action 3 verified fault recovery: Dock returned
`SH_INPUT_BAD_COMMAND` (feed result 6), the journal transitioned to `.failed` at
revision 746, and `activeChoice` and saved requested intent were strictly preserved.
Action 4 verified interrupted-preparation recovery: the interrupted reservation was
automatically retired and reapplied at higher revision 750 (native sequence 4, epoch 1)
on the next settled poll. Held-output deferral was verified when holding button A
deferred `ActivateConfig` and safely triggered timeout rollback to revision 755 without
corrupting intent. Calibrating `observe_output` to check true button presses, triggers
and analog stick axes outside standard XInput deadzones (7849/8689) resolved false
held-state on resting analog sticks for full templates (`controller_ps5.vdf`). Action 2
baseline restoration confirmed on device at revision 762 (native sequence 3, epoch 1),
cleared `selection.requested`, confirmed `lastActivated` as the baseline restore identity,
republished working baseline `MSIBAS02` at revision 762, and verified byte-for-byte
identity of the original VDF on disk (`original_unchanged: true`). Ordinary builds in
`build/madeira-dock/build.sh` and `madeira-dock/tools/build.sh` now enable
`SH_STEAM_INPUT_LOCAL_APPLY=1` by default. Host sanitizers, C/Swift regressions,
`build/madeira-dock/build.sh --check` and `tools/check-steam-input-runtime.py` pass.
Milestone 1 is complete.

- [x] Add a versioned per-game selection model: Game default, Community item,
  Personal layout, or explicitly selected template. Record controller identity,
  source, revision/content hash and last successfully activated revision.
- [x] Distinguish an explicit choice in Madeira from an existing Steam selection.
  On migration, retain both and avoid replacing either without an explicit choice.
- [x] Define the bridge between Madeira and Dock for querying the current layout,
  listing available sources, applying a revision and restoring the game default.
  Reuse the existing session-command transport where suitable after inspecting it.
- [x] Bind each command to the current session, game and controller; include a
  sequence ID and structured result. Reject stale commands and unsafe file paths.
- [x] Separate requested, downloading, validated, queued, cached and active states.
  An activation request or generic cache presence is not an acknowledgement that
  the requested layout revision became active.
  - [x] Determine the pinned native document-revision completion and verify it
    through a distinctive changed mapping and automatic restoration on device.
  - [x] Implement and host-test serialized transaction/content binding and a
    persistent revision journal with immutable source/queue objects.
  - [x] Connect coordinator/journal to scoped local submission and hash-bound
    receipts; host-test acceptance versus activation, rejection and rollback.
  - [x] Device-validate native local apply/restore commands and matching
    hash-bound receipts through a distinctive changed mapping.
  - [x] Device-validate app submission, persisted acknowledgement, fresh-launch
    reapplication and baseline restoration with override clear.
  - [x] Device-validate fault/rejection, interrupted-transaction and held-output
    recovery, then enable ordinary builds before publishing production active state.
- [x] Route startup selection and live changes through the same service. Preserve
  the last working revision on failure and serialize conflicting apply requests.
  - [x] Implement fresh-launch reapplication through the same preparation,
    journal, submission and receipt path, without replacing newer unconfirmed intent.
  - [x] Preserve bounded confirmed-source history across restart rollback and
    retire interrupted old-launch reservations only after a fresh native baseline.
  - [x] Verify app-side selection, persisted acknowledgement, fresh-launch
    automatic reapplication, restoration and persisted override clear on iPad.
  - [x] Verify cleared-intent relaunch delegates to the unchanged original Steam
    selection without an app layout submission.
  - [x] Implement and host-test same-session virtual reconnect recovery,
    non-mutating baseline restore preparation, cache-timeout rollback and
    held-button/output quiescing across layout transitions.
  - [x] Verify fault/reconnect, interrupted-transaction and held-output behavior
    on device.
- [x] Inventory physical inputs that Madeira actually forwards to the virtual
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


## Milestone 1 device evidence — R2 (2026-11-02)

The corrected iPad build initializes SDL3, sees one controller, resolves the
existing account-local autosave, queues it, observes the game cache and requests
activation. Valve's output stream is connected and changing. Public callback
2803 reaches Dock with manifest major/minor 0/0 and gamepad-output flag 2.
The feed reports connection epoch 1 and a completed query (sequence/result 1/1).
The app's stored version-1 record has the same game/key/Workshop selection as
the feed, no manufactured explicit choice and no claimed active revision.

Live nonmutating command checks passed with a valid source query as the positive
delivery control: wrong nonce, old connection epoch, replayed sequence and
oversized path-bearing payload are rejected. Reserved apply/default operations
return result 7 while preserving the observed layout, connected state and cache.
An earlier inconclusive probe used an older launch scope; it is not counted as
rejection evidence. No personal selection keys, account identifiers or raw
callback payloads are recorded in this plan.

Persistence across a normal relaunch and controller reconnect is the next
physical check. This evidence does not close fixture application, exact-revision
acknowledgement, restoration or rollback. The next implementation investigation
is the pinned client's private load-completion callback 1060003, including its
payload semantics and correlation to binding objects; it is not decoded or
used as an acknowledgement yet. See Dock CLIENT_LAYOUTS.md.


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

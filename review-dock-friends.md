# Review: `dock-friends` branch (Steam friends, invites, hosting)

**Date:** 2026-10-31
**Scope:**

| Repo | Range |
|---|---|
| Madeira (main repo) | `main...dock-friends`, 26 commits, binaries excluded |
| `madeira-dock` | `8c98616..ff1607b`, 15 commits (friends feed, commands, sign-in, invites) |
| `wine` | `df1c5ea..6a1230f`, 1 commit (opengl32: 32-bit WoW64 callers on iOS) |
| `dxmt` | `05876bb..3458859`, 1 commit (airconv threadgroup atomic memory flags) |

**How the review ran:** 8 parallel reviewers each covered one area:

- Dock friends core: threading and lifetimes
- Dock error handling
- Feed and command formats
- Swift app
- Cross-repo protocol
- Build changes
- wine opengl32 WoW64
- Generated thunks and dxmt

Two independent skeptics then tried to refute each finding: one traced the code path, and one looked for intent or code elsewhere that handles the case. **CONFIRMED** means both judged the finding real. **PLAUSIBLE** means one did. 39 candidates went through this check. After merging duplicates, 19 issues remain, listed below, and 5 were refuted (see the end). The final "what did we miss" pass did not run because of a usage limit, so the coverage is the 8 reviewer areas only.

No issues were found in the dxmt change.

---

## Summary

| # | Sev | Status | Where | Issue |
|---|---|---|---|---|
| 1 | Medium | Confirmed | `madeira-dock/src/friends.c:235` and `app/Madeira/MadeiraDock.swift:382` | Friends events grow the report without bound; past 32 KB the app stops seeing `probe-result` at game end |
| 2 | Medium | Confirmed | `madeira-dock/src/friends.c:348` | Friends sign-in and status subscription are sent once and never retried, after a failed send or a Steam reconnect |
| 3 | Medium | Confirmed | `tools/build/package-ipa.sh:60` | Removing `allow-jit` from the entitlements makes IPA packaging fail every time |
| 4 | Medium | Confirmed | `wine/dlls/opengl32/unix_wgl.c:2246` | The WoW64 string cache hands one pseudo-process's guest address to another |
| 5 | Medium | Confirmed | `wine/dlls/opengl32/unix_private.h:87` | `copy_wow64_ptr32s` adds the guest base to GLintptr/GLsizeiptr offset and size arrays |
| 6 | Medium | Confirmed | `wine/dlls/opengl32/Makefile.in:9` | The fork already contains `patches/wine-opengl-winios.patch` except its Makefile hunk, so `git apply` fails and the ARM64EC image-base fix is lost |
| 7 | Low | Confirmed | `madeira-dock/src/friends.c:336` and `app/Madeira/DockFriends.swift:125` | `friends-cmd-seq` is printed as signed int32; the app matches it as UInt32 |
| 8 | Low | Confirmed | `app/Madeira/DockFriends.swift:88-92` | An in-game status change is saved and shown before Dock answers; failures are never shown |
| 9 | Low | Confirmed | `app/Madeira/MadeiraDock.swift:421` and `app/Madeira/DockFriends.swift:69` | A stale friends feed from a killed session shows up in the next session |
| 10 | Low | Confirmed | `madeira-dock/src/friends.c:303-308` | Accept removes the stored invite before the join call is known to have succeeded |
| 11 | Low | Confirmed | `madeira-dock/src/friends.c:180` | The 250-friend cap is applied in raw index order, so online, joinable and inviting friends past index 250 are dropped |
| 12 | Low | Confirmed | `madeira-dock/src/friends.c:224` | A name that sanitizes to empty is re-requested every minute, which knocks that friend offline |
| 13 | Low | Confirmed | `madeira-dock/src/friends_format.c:32` | The name sanitizer keeps C1 control characters (U+0080 to U+009F) |
| 14 | Low | Confirmed | `app/Madeira/MadeiraDock.swift:335` | The report allowlist drops 9 friends diagnostic keys that Dock writes |
| 15 | Low | Confirmed | `madeira-dock/tools/check-client-layout.py:19-20` | The layout checker always fails on the September (202609) client |
| 16 | Low | Confirmed | `tests/host/check-dock-contract.py:108` | The Dock contract check no longer compiles (`SteamOnlineStatus` has no stub) |
| 17 | Low | Confirmed | `madeira-dock/docs/INVITE_TESTING.md:21,24` | Two expected results in the invite test plan disagree with the code |
| 18 | Low | Confirmed | `wine/dlls/opengl32/unix_wgl.c:2561` | The pointer-or-offset probe can leave a spurious `GL_INVALID_ENUM` for the app |
| 19 | Low | Confirmed | `wine/dlls/opengl32/make_opengl:381` | The pack-buffer and element tables miss the EXT_dsa, EXT imaging and IBM multimode entry points |

---

## Medium

### 1. Friends events make the Dock report unbounded; the app misses the end of the game
**`madeira-dock/src/friends.c:235-241`, `:229`, `:405`; `app/Madeira/MadeiraDock.swift:348,382`**

The launch loop used to write only a few events, each written once when something changed. The friends code now writes for the whole session:

- 4 lines whenever the online, named, playing or listed count changes (checked every 3 s)
- `friends-requested` once a minute
- `friends-persona-updates` every 64 callbacks

`MadeiraDock.pollReport`/`parseReport` refuse a report over 32,768 bytes and keep returning the last report they parsed.

- **Failure:** Someone with many friends plays for a few hours and the report passes 32 KB. When the game exits, Dock writes `launch-game-ended` and `probe-result=0`, but `pollReport` returns the stale report. `Library.swift:1414` (`pollReport().result == 0`) never fires, so the app does not return to the library. The watch loop in `MadeiraDockView` never sees `report.result` either.
- **Fix:**
  - **App:** read the tail of the report, not the whole file. For example, parse the first 32 KB plus the last 4 KB, or read up to 1 MB as `DockFriends.checkResult` does.
  - **Dock:** limit the friends output. Write the count lines only on real change, at most once every N seconds, or write the counts to the feed or a separate stats file rather than the report.

### 2. Friends sign-in and subscription are sent once, with no retry and no re-send after a reconnect
**`madeira-dock/src/friends.c:348-358`**

`ClientChangeStatus` and `Chat.RequestFriendPersonaStates#1` are sent once, 2 s after init. `announce_pending = false` runs whatever `sent` was, and nothing handles `SteamServersConnected_t` (101). The branch's own HANDOFF.md says that in web-UI mode the client never signs in to Friends by itself.

- **Failure:** Wi-Fi drops briefly, or Steam moves the session to another server, so the client logs on again. Friends now see the player as offline, friend updates stop, and `LobbyInvite_t` (503) stops arriving. The same happens for the rest of the session if the single send fails (`friends-signin=-1`).
- **Fix:**
  - In `sh_friends_callback`, on id 101 with `f->shared` set, re-arm the announce: set `announce_pending = true` and `announce_ms = now + 2000`.
  - Clear `announce_pending` only after a successful send. Otherwise retry after a delay, with a limited number of attempts.

### 3. IPA packaging now always fails
**`tools/build/package-ipa.sh:60-63`; the change is in `app/Madeira/Madeira.entitlements`**

Commit e6490e3 removed `com.apple.security.cs.allow-jit`. The packager signs with that entitlements file, then runs `grep -q 'com.apple.security.cs.allow-jit'` and exits 1 when the key is missing.

- **Failure:** `./tools/build-ipa.sh` builds everything, then prints `ERROR: packaged app is missing the allow-jit entitlement` and produces no `dist/Madeira.ipa`.
- **Related:**
  - `EntitlementChecker.swift` still checks for the key and logs `allow-jit: false` as an error.
  - `app/source.json` still lists the key.
- **Fix:** delete the check, or check for a key that is still in the file, such as `increased-memory-limit`. Update the other two places as well.

### 4. The WoW64 string cache is shared across pseudo-processes
**`wine/dlls/opengl32/unix_wgl.c:2220-2252`** (one skeptic rated it high, the other refuted it, the second verification of the same issue confirmed it at medium)

On iOS, the opengl32 unix side is linked once into `libntdll_unix` and serves every pseudo-process. `wow64_strings` maps a host string pointer to a 32-bit guest address that belongs to one process's 4 GB window. The cache does not record which process an entry belongs to, and nothing clears it when a process exits. `wgl.c:2176` skips detach.

- **Failure:** 32-bit GL program A calls `glGetString` or `glGetStringi`, then exits. Program B, in the same app session, makes the same call, hits the cache, and gets A's guest address. In B's window that address is unmapped or holds unrelated data, so B crashes in `strlen`/`strstr` or reads garbage extension names.
- **Fix:** add the window base (`ios_wow_host_base()`) to the cache entry and match on it. Clear a window's entries when it is torn down; there is already a teardown hook next to `d3d9_native_window_teardown(B)`.

### 5. `copy_wow64_ptr32s` adds the guest base to integer offset and size arrays
**`wine/dlls/opengl32/unix_private.h:87`, `make_opengl:635`**

This helper now runs every element through `ios_wow_host_ptr()`. The generator still uses it for `GLintptr*` and `GLsizeiptr*` arrays, which hold integer offsets and sizes, not pointers.

- **Failure:** `glBindVertexBuffers` or `glBindBuffersRange` from a 32-bit app passes offsets and sizes of B+value to the driver. Zink/MoltenVK then reads far beyond the buffer, which gives garbage geometry or uniforms, or a GPU fault.
- **Fix:** add `copy_wow64_intptr32s()`. It still converts the array address, but widens each element with `ULongToPtr` instead of adding the base. Have `make_opengl` emit it for `(sizei|int)ptr*` arrays.

### 6. The wine patch no longer applies, and its last hunk was never committed to the fork
**`wine/dlls/opengl32/Makefile.in:9`, `patches/wine-opengl-winios.patch`, `docs/BUILDING.md:93,100`**

Wine commit 6a1230f contains every hunk of the patch except the one for `Makefile.in`. `git apply` is all-or-nothing, so the documented step fails and the Makefile hunk is never applied. The fork's `Makefile.in` still sets the low image base (`0x7a800000`) for every architecture.

- **Failure:** A developer who follows BUILDING.md and rebuilds `opengl32.dll` gets an ARM64EC DLL at the wrong base. The DLL currently committed is at `0x180000000`. Every wgl call from the rebuilt DLL then runs with a NULL TEB.
- **Fix:**
  - Commit the `i386_`/`x86_64_EXTRADLLFLAGS` split to the Vuqar05 wine fork and bump the submodule.
  - Remove the patch and its steps in BUILDING.md, and update the related wording in LICENSING.md.

---

## Low

### 7. `friends-cmd-seq` is signed on one side and unsigned on the other
**`madeira-dock/src/friends.c:336` (and `main.c` prints it with `%ld`); `app/Madeira/DockFriends.swift:59,98-99,125`**

The app seeds the sequence as `UInt32(unixTime) | 1`. Dock casts it to `int32_t` before printing.

- **Failure:** The problem stays dormant until 2038, or until the device clock is set past it. From then on every value is ≥ 2³¹, Dock prints a negative number, and every Friends command shows "No answer from Steam" even though Dock carried it out.
- **Fix:** keep the sequence within 31 bits on the app side. Alternatively, print it as unsigned in Dock, or match `Int32(bitPattern:)` in the app.

### 8. An in-game status change is shown as done before Dock answers
**`app/Madeira/DockFriends.swift:88-92`, `Library.swift:5154`, `DockFriends.swift:194`**

`setStatus` saves `SteamOnlineStatus.current` immediately. The result is stored with `steamID = 1/3/7`, so it never matches a friend row and is never shown. `SET_STATE` returns `CALL_FAILED` whenever `f->shared` is NULL.

- **Failure:** The user picks Invisible. The picker shows it and Settings saves it, but friends still see the player Online and no error is shown. The same happens on a timeout or a failed write.
- **Fix:** treat the change as pending. Save and show the new status only when the result is 1, and show failures near the picker.

### 9. A stale friends feed from a killed session shows up in the next one
**`app/Madeira/MadeiraDock.swift:421-422`, `app/Madeira/DockFriends.swift:69`, `madeira-dock/src/friends.c:65-66`**

The feed and command files are deleted only in `sh_friends_init`, which runs after sign-in and LaunchApp, and in `sh_friends_end`. A force-closed session or a crashed Wine/FEX process leaves `madeira-friends.bin` on disk. `refresh()` decides whether the Friends page is available from the file alone, and it never clears `friends` when the file is missing.

- **Failure:** During the next session's sign-in or launch, the Friends page shows the old list. That can be another account's list, or appear in a non-Dock session. A Join pressed then lapses with "No answer from Steam".
- **Fix:**
  - In `writeHandoff`, delete `madeira-friends.bin`, `.tmp` and `-cmd.bin`.
  - In `refresh()`, set `friends = []` when the feed is missing.

### 10. Accept removes the stored invite before the join is known to succeed
**`madeira-dock/src/friends.c:303-308`**

`forget_invite` runs before `NotifyLobbyJoinRequested` (slot 194). JOIN also does not check `game_running`.

- **Failure:** The call returns false, or the game is still starting. The invite is gone, Accept disappears from the row, and a retry falls back to the game-info path, which can return NOT_JOINABLE.
- **Fix:** return NOT_JOINABLE while no game is running, and call `forget_invite` only after slot 194 succeeds.

### 11. The 250-friend cap drops friends in raw index order
**`madeira-dock/src/friends.c:180-214`**

Since commit f294bd8, offline friends are listed too, and the loop stops at `SH_FRIENDS_MAX` in `GetFriendByIndex` order. Steam allows up to 2000 friends.

- **Failure:** On a large account, a joinable friend who sent an invite can sit past index 250. That friend never appears, so the user can't Join or Accept, and the friend's name is never requested.
- **Fix:** choose the 250 by priority: invited, joinable, same app, in a game, online, then offline. A simpler option is to skip offline friends unless they invited the player.

### 12. A name that sanitizes to empty is re-requested every minute
**`madeira-dock/src/friends.c:224` (with `:187`, `:199`)**

Whether a friend still needs data is decided from the sanitized name. Line 187 counts "named" from the raw name, so the two checks disagree. HANDOFF.md says `ClientRequestFriendData` (flags 1106) resets that friend to offline.

- **Failure:** A friend's name has invalid UTF-8 or only control characters. That friend is re-requested every 60 s, keeps flipping to offline, and shows as "Unknown".
- **Fix:** decide "needs data" from the raw name (`raw && raw[0]`).

### 13. The name sanitizer keeps C1 control characters
**`madeira-dock/src/friends_format.c:32`**

Only one-byte controls are dropped, so the bytes `C2 80` to `C2 9F` (U+0080 to U+009F) get through. That breaks the header's promise of "no control characters".

- **Failure:** The name `Bob\u0085Smith` contains NEXT LINE, so `Text(...).lineLimit(1)` shows only "Bob".
- **Fix:** also drop `n == 2 && s[i] == 0xC2 && s[i+1] < 0xA0`. Optionally drop U+2028, U+2029 and bidi overrides too.

### 14. The report allowlist drops 9 friends keys
**`app/Madeira/MadeiraDock.swift:335`**

These keys are missing from `reportAllowed`:

- `friends-online`
- `friends-persona-chosen`
- `friends-state-set`
- `friends-invite-connect`
- `friends-subscribed`
- `friends-invite-received`
- `friends-persona-flags`
- `friends-persona-updates`
- `friends-callback-id`

The Dock README, HANDOFF.md and INVITE_TESTING.md use them for diagnosis, but they never reach `[dock-report]` in the app log.

- **Fix:** add them to the allowlist. Optionally, extend `check-dock-contract.py` to compare the keys Dock emits against the allowlist so the two lists stay in sync.

### 15. The layout checker always fails on the September client
**`madeira-dock/tools/check-client-layout.py:19-20`**

The tool collects RVAs with `re.findall(r'0x[0-9a-f]+')`, but the September entry's 16 new friends slots are written as bare `0`. The tool therefore finds 18 values, and `assert len(rvas) == 34` fails before the new SKIP branch can run.

- **Fix:** use the regex `0x[0-9a-f]+|\b0\b`, or write the September placeholders as `0x0`.

### 16. The Dock contract check no longer compiles
**`tests/host/check-dock-contract.py:98-113`**

`configure()` now references `SteamOnlineStatus`, which lives in `DockFriends.swift` and has no stub in the test. The check was already failing on main because `ExternalDrives` has no stub either.

- **Fix:**
  - Add stubs for `SteamOnlineStatus` and `ExternalDrives`.
  - Add an assertion that `MADEIRA_DOCK_PERSONA_STATE` is set.

### 17. Two expected results in INVITE_TESTING.md disagree with the code
**`madeira-dock/docs/INVITE_TESTING.md:21,24`**

- **Row 21** tests `+connect_lobby` with `MADEIRA_DOCK_FRIENDS_ONLINE=0`. That setting leaves no shared connection, so the player's own lobby is unknown, there is no Invite button, and a forced Invite returns result 2.
- **Row 24** (Offline) expects "no friends reports", but `sh_friends_init` writes `friends-available=0`.

### 18. The pointer-or-offset probe can leave a spurious GL error
**`wine/dlls/opengl32/unix_wgl.c:2561`** (one verifier says it is narrower than first claimed)

For pointer values ≥ 64 KB, `wow64_buffer_ptr`/`wow64_query_buffer_ptr` call `glGetIntegerv(binding)` without checking that the context supports the binding. Without ARB_query_buffer_object, `GL_QUERY_BUFFER_BINDING` is an invalid enum. That is always the case on the winios GLES 3.0 fallback, and on ES 2.0 the PACK/UNPACK bindings are invalid too.

- **Failure:** The app's next `glGetError` returns `GL_INVALID_ENUM` after a valid `glGetQueryObjectuiv` (or `glTexImage2D` on ES 2.0).
- **Fix:**
  - Cache per context whether each binding is supported, and skip the probe when it is not.
  - Alternatively, drain the error right after the probe while keeping the app's pending error.

### 19. `make_opengl` misses some buffer-offset entry points
**`wine/dlls/opengl32/make_opengl:381-454`**

`%wow64_pack_buffer_params` is missing these readbacks:

- EXT_direct_state_access: `glGetTextureImageEXT`, `glGetMultiTexImageEXT`, `glGetCompressedTextureImageEXT`, `glGetCompressedMultiTexImageEXT`
- EXT imaging: `glGetColorTableEXT`, `glGetHistogramEXT` and similar

Separately, the element-array rule misses `glMultiModeDrawElementsIBM`.

- **Failure:** With a PBO bound, these calls get B+offset, so the driver raises `GL_INVALID_OPERATION` and the readback silently does not happen.
- **Fix:**
  - Add the missing entries to the table.
  - Widen the element-array regex to `^gl(Multi)?(Mode)?Draw(Range)?Elements`.
  - Regenerate `unix_thunks.c`.

---

## Refuted (checked and dropped)

- **Stored lobby invites never expire and take priority over the friend's current lobby on Join** (`friends.c:303`): this is intended. A newer invite replaces the old one, and Join is the user's choice.
- **New submodule pointers are not on the branch `.gitmodules` names** (`.gitmodules:16`): this is true but not a defect. The pinned commits (madeira-dock ff1607b, wine 6a1230f, dxmt 3458859) are only on feature branches of the Vuqar05 forks. `git submodule update` still fetches them by SHA. **Housekeeping:** before merging to main, make sure those fork branches are pushed and never deleted, or merge them into `main`, `madeira-lgpl` and `ios-port`.
- **The GPL source offer for `dockhost.exe` names the 125hz repo** (`build/madeira-dock/build.sh:46`): the line predates this branch. Now that the submodule points at the Vuqar05 fork, it is still worth updating.
- **A per-game `MADEIRA_LUAJIT=interp` stays set for later games** (`luajit_compat.c:144`): not a real problem, because each game's config is applied fresh.
- **Changed submodule URLs need `git submodule sync`** (`tools/build-ipa.sh:22`): tested; existing clones still update.

## Not covered

- The "completeness" pass that looks for issues the reviewers missed did not run.
- The generated `wine/dlls/opengl32/unix_thunks.c` (about 15k lines of diff) was spot-checked by pattern, not read line by line.
- None of the findings were tested on a device. Findings 2, 4 and 18 depend on runtime behaviour that has not been observed live.

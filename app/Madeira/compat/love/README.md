# compat/love/ — LuaJIT for LOVE games (not tracked)

`build/luajit-x64/build.sh` builds `lua51.dll` (GC64 LuaJIT, x86-64) here; it
is git-ignored. When a game loads an x64 LuaJIT that needs memory below 2 GB
(LuaJIT 2.0, or 2.1 without GC64), the wineserver maps this build in its place;
the game's own file is not changed (`build/wineserver/luajit_compat.c`).
Without it such games keep their stock LuaJIT, which fails on iOS.

## `env.MADEIRA_LUAJIT = interp` (opt-in)

A game whose own `lua51.dll` is a GC64 LuaJIT 2.1 (Balatro) runs fine on iOS
and is left alone by default. With `env.MADEIRA_LUAJIT = interp` in
`madeira.cfg`, or better in the game's own config (Game details > This game's
config), the wineserver maps this interpreter-only build in its place too. The
log then says `[luajit-compat] x64 LuaJIT with GC64; MADEIRA_LUAJIT=interp maps
the bundled interpreter-only build`.

Why it helps: under FEX, the game's JIT costs more than it gains. FEX has to
translate every piece of x64 machine code the JIT writes, plus the JIT's own
trace compiler; a plain interpreter avoids both.

Measured on Balatro, iPhone, 2026-10-29 (averages of busy 300 ms `[xp]`
windows; stock run about 30 s, interp run about 9 min, so the scenes may
differ):

| | game's JIT | interp |
|---|---|---|
| main thread CPU | 198 ms | 123 ms (-38%) |
| process CPU | 296 ms | 232 ms |
| energy | 846 mJ | 331 mJ (-61%) |

Kept opt-in until more LOVE games are checked. A game that calls `jit.on()`
gets an error from this build, since its JIT is compiled out.

# patches/

Source-of-record for changes that live in the **`wine` submodule**
([`willfaust/wine`](https://github.com/willfaust/wine)), kept here so they are
reviewable from this repository.

**Nothing in this directory is applied by the build.** No `build/*/build.sh` and
no step in `.github/workflows/main.yml` references it. A patch here is a record
of a change that has already been made in the fork, or one that still needs to
be — it does not become part of an IPA on its own.

## Landing a patch that touches a PE DLL

The Windows-side DLLs are **committed prebuilt binaries**, in
`app/Madeira/aarch64-windows/` and `app/Madeira/arm64ec-windows/` (135 files
each). CI rebuilds exactly four of them — DXMT's `d3d11.dll`, `dxgi.dll`,
`winemetal.dll` and `d3d10core.dll`. Every other DLL ships as whatever binary
is committed here, so editing the fork's source is not enough: the affected
`.dll` has to be rebuilt and committed too.

Which slot matters depends on the guest. `WineProcessBridge.m` maps
`C:\windows\system32` to the bundle subdir for the session's architecture and
`C:\windows\sysx64` to `arm64ec-windows` — so an **x86-64 game loads the
`arm64ec-windows` copy**, and only that copy. An aarch64 guest and explorer
itself use `aarch64-windows`.

CI cannot currently produce the arm64ec slot. The Wine build step runs

```
../configure --enable-win64 --disable-tests --without-x --without-freetype
```

with no `--enable-archs`, and wine's `configure.ac` then defaults
`cross_archs` to `$HOST_ARCH` — `aarch64` on the macOS arm64 runner. Building
the arm64ec PE DLLs needs `--enable-archs=aarch64,arm64ec` and an
`arm64ec-w64-mingw32-clang` in the toolchain, which also invalidates the
`wine-<sha>` build cache and adds a full Wine rebuild to the job.

So landing one of these is three steps:

1. Apply the patch to the `wine` submodule and push it to the fork.
2. Rebuild the affected DLL for **both** `aarch64-windows` and
   `arm64ec-windows`.
3. Commit the rebuilt binaries, and bump the submodule pointer.

## Contents

Statuses below are against the pinned submodule commit (`7817e22`), checked with
`git apply --check` / `--check --reverse` from a clone of the fork.

| Patch | Status |
|---|---|
| `wine-rpcss-scm-bootstrap.patch` | reverse-applies — in the fork |
| `wine-s0-schannel-ws2_32-ios.patch` | reverse-applies — in the fork |
| `wine-server-s2-desktop-input.patch` | reverse-applies — in the fork |
| `wine-ios-ml435-ml482.patch` | neither direction applies; surrounding code has moved on, so whether it is in the fork was not determined here |
| `wine-ios-ml483-ml488.patch` | as above |
| `wine-ios-ml489-ml504.patch` | as above |
| `wine-ios-ml505-ml518.patch` | as above |
| `wine-ntdll-ios-xlate-rev.patch` | as above |
| `wine-sechost-no-plugplay-ios.patch` | **applies cleanly — NOT in the fork, and not in any shipped `sechost.dll`** |

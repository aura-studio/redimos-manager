# redimos-manager

A small desktop app to run and manage multiple **redimos** server instances —
each pointed at a DynamoDB table (local DynamoDB Local *or* online AWS), pinned
to a redimo line (**v1** or **v2**), on its own port, with one-click start/stop.

- **UI:** Flutter (desktop).
- **Core:** a Go **dynamic library** (`redimos_core.dll` / `.so` / `.dylib`),
  called from the UI via `dart:ffi`. The Go core owns everything stateful:
  it persists the configurations and launches / monitors / stops one redimos
  child process per configuration.

```
Flutter UI  ──dart:ffi──▶  redimos_core.dll (Go)  ──os/exec──▶  redimos.exe ──▶ DynamoDB
```

## Features

- **Multiple configs.** Create as many named configs as you want.
- **One schema for local & online.** Each config has a DynamoDB *endpoint*:
  leave it **empty** for online AWS (the SDK's default credential/region chain),
  or set it to e.g. `http://localhost:8000` for a local **DynamoDB Local**
  container. Same fields cover both; optional access-key/secret and region are
  passed through as env when set.
- **redimo version dropdown (v1 / v2).** A config declares which line it runs:
  `v1` launches the redimos **v1** binary (redimo v1), `v2` launches redimos
  **v2** (redimo v2). The two binary paths are set once in **Settings**.
- **Per-config port** (`-addr :PORT`).
- **Start / stop the child process** from the list, with live status (running /
  pid / uptime / exit) and streamed stdout/stderr **logs**.
- Extra passthrough flags, `multi-db`, and `requirepass` per config.

Configs persist to `~/.redimos/store.json`
(`%USERPROFILE%\.redimos\store.json` on Windows).

## Prerequisites

- **Flutter** (desktop enabled). Windows desktop also needs Visual Studio with
  the "Desktop development with C++" workload.
- **Docker Desktop** — used only to *build* the Go core `.dll` (there is no
  local gcc/mingw; the build cross-compiles inside a golang+mingw container).
  If you have a native C toolchain you can build the core directly instead
  (see `native/`).
- One or two **redimos** executables (Windows `redimos.exe`) — build them from
  the `redimos` repo: `go build -o redimos.exe ./cmd/redimos` on the `v2`
  branch (and the `v1` branch once its re-backend lands).

## Package a release (one click)

Double-click **`build.cmd`** in the project root. It builds the three parts and
bundles them into a single self-contained archive:

```
dist\redimos-manager-<version>-windows-x64.zip
├─ redimos_manager.exe + redimos_core.dll + data\  (the desktop app + runtime)
├─ bin\redimos-v1.exe                              (redimos server, redimo v1 line)
└─ bin\redimos-v2.exe                              (redimos server, redimo v2 line)
```

The version comes from `pubspec.yaml`. Options (run from a terminal):

```powershell
scripts\build.ps1                  # default: rebuild DLL (Docker) + app, bundle existing bin\*.exe
scripts\build.ps1 -SkipDll         # reuse native\redimos_core.dll (no Docker)
scripts\build.ps1 -RebuildServers  # also recompile redimos-v1/v2.exe from the sibling redimos repos
scripts\build.ps1 -Version 0.2.0   # override the package version
```

## Build & run (dev)

```powershell
# 1. Build the Go core dynamic library (redimos_core.dll)
powershell -ExecutionPolicy Bypass -File scripts\build_native.ps1

# 2. Generate the Flutter desktop scaffolding (one time; keeps this repo's
#    lib/ and pubspec.yaml — only adds the missing platform runner dirs)
flutter create --platforms=windows,macos,linux --project-name redimos_manager .

# 3. Fetch packages and run
flutter pub get
flutter run -d windows
```

`scripts\build_native.ps1` copies `redimos_core.dll` next to the built runner so
FFI can load it. For a `flutter run` dev loop you can instead point the app at
the library explicitly:

```powershell
$env:REDIMOS_CORE_LIB = "$PWD\native\redimos_core.dll"
flutter run -d windows
```

## Typical setup (local, matching a DynamoDB Local container)

1. **Settings** → set the **redimos v2 binary** path to your `redimos.exe`.
2. **New config**:
   - Name: `local-v2`
   - redimo version: `v2`
   - Port: `6379`
   - DynamoDB table: `redis-data`
   - DynamoDB endpoint: `http://localhost:8000`  ← local DynamoDB Local
   - Region: `us-east-1` · multi-db: on
3. **Save**, then hit ▶. Connect any Redis client to `127.0.0.1:6379`.

For an **online** config, use the same form but leave *endpoint* empty and set a
real region (credentials come from the AWS default chain, or fill in the
access-key/secret fields).

## FFI surface (Go core → C ABI)

All functions take/return a UTF‑8 JSON `char*`; returned strings are freed with
`rm_free`.

| function | purpose |
|---|---|
| `rm_load` | configs + settings |
| `rm_save_config` / `rm_delete_config` | upsert / remove a config |
| `rm_set_settings` | binary paths |
| `rm_start` / `rm_stop` / `rm_stop_all` | process lifecycle |
| `rm_status` | per-config running state |
| `rm_logs` | recent stdout/stderr lines |
| `rm_version`, `rm_free` | version / free a returned string |

## Layout

```
native/          Go c-shared core (redimos_core.go)
lib/             Flutter app (main.dart, src/native.dart, src/models.dart)
scripts/         build_native.ps1
```

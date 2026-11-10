# iOS 27 (OneiOS)

A system kind of its own in this fork (`akshaynexus/OneOS`, branch `oneios`): Apple's iOS 27 as a OneOS-style
session on the Galaxy S24 Ultra. One UI's framework stops, and instead of another Android framework the session
starts **xnuhost**, OneiOS's source-built XNU running as a process on One UI's kernel, with an iOS image set the
owner built. Volume Up + Volume Down for 3 s brings One UI back, in place when every check holds, else by a
restart.

OneiOS is https://github.com/akshaynexus/OneiOS. Its plan is `docs/plan.md` there; the contract between this fork
and its runtime is `oneos/interface.md` there ("session ABI 1"). This page is the fork's side.

**Nothing here has run on a phone.** The app model, the root script and the stage checks are unit tested
(below); the session past its preflight has never started, because no runtime with a working xnuhost exists yet.

## Where its pieces come from

| Piece | Where from | In git or a release? |
|---|---|---|
| OneOS app, `oneios_root.sh`, `oneios_switch.sh`, `oneios_return.sh` | this fork | yes |
| **Runtime**: xnuhost and what it needs to run (OneiOS's own code only) | OneiOS's GitHub releases, asset `oneios-runtime-<version>-arm64.tar.zst` with `<name>.sha256` beside it; the latest release or a tag you name. Or the same file from the phone ("I have the file"), for a build of your own | OneiOS's releases |
| **Image set**: the iOS volumes, the kernel collection with Apple's kexts, the overlay | built by you from Apple's IPSW with OneiOS's scripts, imported from a `.tar.zst` file on the phone | **never**: it is made from Apple's firmware. The app has no download for it |

Both are a zstd-compressed tar with a manifest at the top: `runtime.json` or `manifest.json`, with `format` (1),
`version` and `files` (`path`, `size`, `sha256`; the runtime also `mode`). A runtime also names `session_abi`,
`xnuhost` (its path) and `image_formats` (the image formats it boots). The exact schema is in OneiOS's
`oneos/interface.md`; the image side follows OneiOS's `docs/image-format.md` once that exists.

## Scope: the Galaxy S24 Ultra only

`OneiosSystem.offeredOn` (`core/model/.../Oneios.kt`) is true for one profile, `s-ultra-8650` (SM-S928, e3q,
SM8650), and `oneios_switch.sh` checks the same three properties itself before anything else. On every other
phone there is no iOS card. On the S24 Ultra the card is last in Choose a system, marked Experimental, and the
switch needs a tick every time ("I understand that iOS 27 (OneiOS) is experimental..."), like an untested profile.

It is not an `ImageRef`: it has no Android SDK, no `system.raw`, no package set and no guard jars, so none of the
Android guests' tables, pins or tests know it.

## In the app

Choose a system → **iOS 27 (OneiOS)** → Open (`OneiosActivity`, `OneiosJob`):

- **OneiOS runtime**: what is staged; *Download from OneiOS's releases* (GitHub's API for the latest release or
  a tag, the `.sha256` asset, then the package, checked by size and SHA-256); *I have the file*. With no release
  published it says so in one line and changes nothing.
- **iOS image set**: what is staged; *I have the file* (the system file picker). No download.
- **Session**: *Ready to switch*, or the one line root's preflight gave (for example "no OneiOS runtime is staged:
  xnuhost, the program that runs iOS, comes with it"). How the last session returned.
- The experimental tick and **Switch to iOS 27**, enabled only with the tick and a passing preflight.
- *Remove the iOS files*.

Importing either package: the app reads the tar twice. First for the manifest, which it parses and checks
(`OneiosManifests.parse`: format version, plain relative paths, sizes, SHA-256s, no duplicates; a runtime must
name an xnuhost that is one of its files with mode 0755). Then every member is handed to root's `receive` while
the app hashes it (`OneiosPackage.unpack`): a member the manifest does not list, a wrong size, a wrong SHA-256, a
missing file, a link or a device ends the import. Root checks each file's size and SHA-256 again as it writes it
into `<kind>.new`, and only `finish` puts the new runtime or image in place of the old one. A failed import leaves
what was staged before untouched.

## Stage

`/data/local/tmp/oneios`, root:root, mode 0700. It is not the Android guests' stage (`/data/local/tmp/oneos`),
and neither kind of session starts while the other's stage has anything mounted.

| Path | What |
|---|---|
| `bin/oneios_root.sh` | the app's root script; the launcher runs it only with the SHA-256 pinned in BuildConfig |
| `oneios_switch.sh`, `oneios_return.sh` | the session scripts, pinned the same way, staged with every import |
| `runtime/`, `runtime.conf`, `runtime.sha256`, `runtime.ids` | the unpacked runtime; its version, session ABI, xnuhost path and image formats; every file's SHA-256; every file's `dev:inode:size:mtime` |
| `image/`, `image.conf`, `image.sha256`, `image.ids` | the same for the image set |
| `data/` | iOS's own writable state. A new runtime or image keeps it; Remove deletes it |
| `session/` | the running or last session: baseline, pids, `xnuhost.log`, `ready`, `return.request` |
| `logs/` | the last five sessions' xnuhost logs |
| `switch.log`, `return.log`, `return.outcome` | the switch's and the return's own output; how the last return ended |

## Session flow

`oneios_root.sh switch` runs the preflight (`oneios_switch.sh --check`) and returns its refusal to the app as one
line. Only when it passes does it start `oneios_switch.sh`, detached, in init's mount namespace.

**Preflight, before any change.** Root; the S24 Ultra; the stage and both session scripts root's own; a runtime
whose session ABI is this build's, with an xnuhost that is root's, executable and an arm64 ELF; every runtime
file's SHA-256 again; an image set of a format the runtime boots, every file the one root hashed at staging
(files under 64 MiB are hashed again; `ONEIOS_VERIFY_IMAGE=1` hashes all); nothing in either folder that its list
does not name; the root manager's busybox and resetprop; init's mount namespace; One UI fully up; no session of
either kind open; the volume keys readable; battery at 30 % or charging and not hot; 2 GiB free; the tick. Any
failure prints `PREFLIGHT REFUSED: <reason>` and exits: nothing was changed, One UI keeps running. **Until a
runtime with xnuhost is staged, this is where every switch ends.**

**Then:**

1. Session folder and baseline: boot id, SELinux mode, properties, the pids of vold, keystore2, surfaceflinger
   and servicemanager, init's mount points.
2. The way back is armed first: the watcher, and a `getevent` reader per volume-key device. A kernel wakelock
   (`oneios_session`) keeps the phone awake without One UI's power manager.
3. One UI's zygote and zygote_secondary are stopped, so system_server and every app end; a loop keeps them
   stopped. surfaceflinger, the vendor composer, audioserver, netd, vold, keystore2 and the radio keep running.
   Samsung's software watchdog gets its magic close and a feeder, as in an Android session.
4. xnuhost starts in a **new mount namespace** in which the stage is bound over `/data` and `runtime` and
   `image` are read-only:
   `/data/runtime/<xnuhost> --session-abi 1 --mode takeover --runtime /data/runtime --image /data/image --data /data/data --session /data/session`.
   If One UI's `/data` is still visible there, it does not start.
5. The watcher returns to One UI when xnuhost ends, when `session/return.request` appears (the volume keys write
   it; xnuhost or a guest app can), or when xnuhost has not created `session/ready` within 600 s.

**Return** (`oneios_return.sh`): SIGTERM to xnuhost, 20 s, SIGKILL to whatever is left in its namespace. Gate A:
no process in that namespace, nothing mounted under the stage or added on One UI's partitions, the same boot,
vold, keystore2, surfaceflinger and servicemanager with their pids of the switch, SELinux as it was. Gate B: the
stop loop gone, One UI's boot-loop counters back to the switch's (in memory), zygote started. Gate C:
system_server keeps its pid until user 0 is unlocked and 20 s more. A failed check is the failsafe: a reboot.
`oneios_return.sh reboot` goes straight there. A return with no open session does nothing, and a switch that
ended before it stopped One UI's zygote (the stop is marked in `session/stopped`) only has its helpers ended:
neither restarts anything.

## One UI's data guards

- xnuhost and every iOS process run in a mount namespace where `/data` is the stage. One UI's app data,
  `/data/system`, `/data/misc` (keystore, gatekeeper, lock-screen files) do not exist there, and the session
  aborts if they do.
- The session scripts and the root script write only under the stage. They never call setenforce, never set a
  `persist.*` property, never talk to vold, keystore2, gatekeeper, weaver or locksettings, and mount nothing in
  init's namespace. `OneiosScriptTest` checks this on their text.
- The Android guests' guard jars are not involved: an iOS guest has no binder client.

## Tests and build

- `core/model` `OneiosTest`: the S24 Ultra-only gating and the tick; manifest parsing (format version, paths,
  sizes, hashes, a runtime without xnuhost); verification against a manifest; unpacking a tar with the manifest
  first, last or under a top folder; damaged, padded and truncated packages; the release JSON and `.sha256` file.
- `core/root` `OneiosScriptTest`: the launcher, `oneios_root.sh` and `oneios_switch.sh`'s stage checks run under
  the machine's shells against a fake root (`ONEIOS_TEST_ROOT`; the scripts refuse it as uid 0 and start nothing
  there): the refusal without a runtime, a runtime without xnuhost, changed files, mismatched pairs; and the
  guards on the scripts' text.
- `./gradlew :core:model:test :core:root:testDebugUnitTest`. The app itself needs the SESL9 libraries from
  GitHub Packages (a token in `~/.config/twidget/github.properties`), as before this change.

## Not done yet

- **xnuhost does not exist yet.** The switch starts whatever the runtime package names, by the contract above;
  the booter's own interface on OneiOS's board (`docs/agents.md`) replaces that command line if it differs.
- Nothing past the preflight has run on a phone: the zygote stop without a guest framework, the watchdog feeder,
  the wakelock, and the in-place return are written from OneOS's Android session and need their first run over
  adb with the owner watching.
- No boot or return splash for iOS, no log collection in the app (the logs are in the stage), no Quick switch.
- Wi-Fi: One UI's supplicant leaves with its framework. Networking in the guest is xnuhost's to solve.
- The image format follows `oneos/interface.md` until OneiOS's `docs/image-format.md` is written.
- The app update, release scripts and the Probe edition know nothing of iOS.

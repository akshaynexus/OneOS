# iOS 27 (OneiOS)

A system kind of its own in this fork (`akshaynexus/OneOS`, branch `oneios`): Apple's iOS 27 as a OneOS-style
session on the Galaxy S24 Ultra. One UI's framework stops, and instead of another Android framework the session
starts **xnuhost**, OneiOS's source-built XNU running as a process on One UI's kernel, with an iOS image set the
owner built. Volume Up + Volume Down for 3 s brings One UI back, in place when every check holds, else by a
restart. If that ever does nothing, **Power + Volume Down held until the phone restarts** always does: see
"Getting back to One UI".

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
- *Back to One UI*, shown while a session is still open and the app runs (root's `return` verb starts
  `oneios_return.sh`; with no open session it does nothing).
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
| `session/` | what xnuhost and the switch share in the running or last session: `xnuhost.log`, `xnuhost.pid`, `ready`, `return.request`, `display.sock`, `tmp/` |
| `control/` | the way back's own: the session's state, the baseline, xnuhost's pid and namespace as the switch recorded them, the watcher's and key readers' pids, the return's lock and guard. Read-only in xnuhost's namespace, like the two session scripts and `bin/` |
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

1. Session folder, control folder and baseline: boot id, SELinux mode, properties, the pids of vold, keystore2,
   surfaceflinger and servicemanager, init's mount points.
2. The way back is armed first, each part in a session of its own (`setsid`) in init's mount namespace: the
   watcher, a `getevent` reader per volume-key device, and a poll of the keys' state. A kernel wakelock
   (`oneios_session`) keeps the phone awake without One UI's power manager. **One UI is not stopped unless all
   of them run and the wakelock is held**; if not, the switch ends there.
3. One UI's zygote and zygote_secondary are stopped, so system_server and every app end; a loop keeps them
   stopped. surfaceflinger, the vendor composer, audioserver, netd, vold, keystore2 and the radio keep running.
   Samsung's software watchdog gets its magic close and a feeder, as in an Android session.
4. xnuhost starts in a **new mount namespace** in which the stage is bound over `/data`; `runtime`, `image`,
   `control`, `bin` and the two session scripts are read-only there. It gets a cgroup of its own
   (`/sys/fs/cgroup/oneios_session`) and `oom_score_adj` 500, so that it, not One UI's daemons or the way back,
   is what the kernel ends when memory runs out:
   `/data/runtime/<xnuhost> --session-abi 1 --mode takeover --runtime /data/runtime --image /data/image --data /data/data --session /data/session`.
   If One UI's `/data` is still visible there, or `control` is writable there, it does not start.
5. The watcher returns to One UI when xnuhost ends, when `session/return.request` appears (the volume keys write
   it; xnuhost does when the guest asks; `adb` can), or when xnuhost has not created `session/ready` within
   600 s of its start (`ONEIOS_RETURN_MAX`; iOS never came up).

**Return** (`oneios_return.sh`), five steps, each logged to `return.log`:

1. **The session ends.** SIGTERM to xnuhost, 20 s; then everything that is left is killed: the cgroup at once
   (`cgroup.kill`), every process in xnuhost's mount namespace, and every process outside init's namespace whose
   mount table still shows the stage. The key readers and the watcher end.
2. **Gate A.** No such process is left; the stage is mounted in no process's mount table (every namespace, not
   only init's: OneOS's run 45); nothing was mounted on One UI's partitions; the same boot; vold, keystore2 and
   servicemanager have their pids of the switch; the daemons One UI cannot restart are running; SELinux is as
   it was. Persist properties that differ from the switch are logged by name (the scripts set none).
3. **Gate B: display and services.** The stop loop is gone; One UI's boot-loop counters go back to the switch's
   (in memory). Then the display, as in OneOS's return: **the vendor composer is restarted, surfaceflinger with
   it** (restarted by name if it outlived the composer, started if it had died), and the boot animation starts.
   Then audioserver and the rest of zygote's restart list (cameraserver, media, wificond, and perfmond and
   media.tuner if they ran). Each must come back and register.
4. **One UI's framework.** `vdc volume abort_fuse`, a fresh zygote_next, `ctl.restart netd` (whose own restart
   list starts zygote; `ctl.start zygote` otherwise).
5. **Gate C.** system_server keeps its pid until user 0 is unlocked and 20 s more, within 180 s.

A failed check anywhere is the failsafe: `sys.powerctl reboot,oneios-inplace-failsafe`, then busybox's
`reboot -f`, then sysrq. `oneios_return.sh reboot` goes straight there. A return with no open session does
nothing, and a switch that ended before it stopped One UI's zygote (the stop is marked in `control/stopped`)
only has its helpers ended: neither restarts anything.

## Getting back to One UI

The way back is entirely on One UI's side. Nothing in it needs the guest to cooperate, to be responsive, or to
have started at all. From the fastest to the one that cannot fail:

| # | What | Works when |
|---|---|---|
| 1 | **Volume Up + Volume Down, 3 s.** One `getevent -lq` reader per key device (on this phone Volume Up is on `gpio-keys`, Volume Down on the PMIC's `pmic_resin`) | always, unless a program grabs the key device |
| 2 | The same chord from the keys' **state**: `getevent -pl` asks each device twice a second (EVIOCGKEY; a key that is down is marked `*`) | also when a program has grabbed the keys: a grab takes the events from other readers, not the state |
| 3 | **The watcher**: returns on `session/return.request`, when xnuhost ends, when the switch never started it (60 s), when the guest never reported `ready` (600 s) | iOS crashed, never started, or asked to leave |
| 4 | The key readers start the return themselves if the session is still not returning 5 s after their request | the watcher is gone or stuck |
| 5 | **The return's guard**: a process of its own that reboots the phone if the return has not finished after 600 s; the watcher reboots at once if the return script cannot run or ends with an error | a step of the return hangs or the script is damaged |
| 6 | **The failsafe reboot** on any failed check of the return | anything about One UI's state is in doubt |
| 7 | **Power + Volume Down, held until the phone restarts (about 7 s)** | always |

**What the guest cannot do to 1 to 6.** The watcher, the readers and the poll are One UI-side processes: started
before xnuhost exists, in init's mount namespace, each its own session, in the root cgroup (which cannot be
frozen and is not xnuhost's), `oom_score_adj` -1000, at a higher priority than ordinary processes, and they run
on One UI's kernel, not on anything the guest schedules. A guest that hangs, spins on every core or runs out of
memory does not stop them. What they read is in `control/`, which xnuhost's namespace has read-only: a guest
that empties its `session/` folder is still returned from. The watcher keeps the wakelock up every 10 s.
What xnuhost must not do, by its contract on OneiOS's board (`docs/agents.md`, "booter -> oneos"): grab an input
device, run its threads in a realtime scheduling class (on every core that would leave the way back 5 % of
the CPU), leave its cgroup or mount namespace, or write to `/sys/power`. Path 2 covers a grab all the same.

**The display and the GPU.** xnuhost draws the guest with the Adreno (KGSL) and, in a session without One UI's
compositor, on the panel itself (DRM). The kernel takes all of that back when the process ends, however it
ends: its KGSL contexts and memory are freed and its DRM master and framebuffers are dropped on SIGKILL exactly
as on a clean exit, so nothing has to be released by xnuhost. What can be left is on One UI's side (a composer
that last saw another DRM master, a surfaceflinger whose GPU context a guest fault reset or that is stuck in a
call), which is why the return never trusts the old display state: it always restarts the composer and
surfaceflinger and requires both back. A GPU that does not recover fails those checks, or Gate C, and ends in
the reboot. A process the kernel cannot end (stuck in a driver) fails Gate A: reboot.

Not ported from OneOS's return: holding the composer (`oneos_boot_hold_display`). It keeps the return splash's
last frame on the panel while no surfaceflinger exists; an iOS session has no return splash, and the composer's
client here is One UI's own surfaceflinger, which a stopped composer would only block.

**The hardware restart (7).** Holding the Side (Power) key and Volume Down together for about 7 seconds is the
phone's forced restart. It is done by the PMIC, below Android's kernel and everything in this session: the two
keys are the PMIC's own inputs on this phone (`pmic_pwrkey`, `pmic_resin`), the reset is set up once at boot,
and neither a grab of the keys, a hung kernel nor anything this session runs changes it (the scripts and
xnuhost never touch the PMIC's reset settings). **It always lands in One UI**, because a session
changes nothing that survives a restart: nothing is flashed, no partition of One UI's is written, no persist
property is set, SELinux's mode is not changed, and the reboot the scripts ask for names a reason
(`oneios-return`, `oneios-inplace-failsafe`) that the bootloader takes as an ordinary restart. The session
lives in processes, a mount namespace, a cgroup and two kernel wakelocks, and all of them end with the kernel.
The files it leaves are under the stage; the next switch clears `session/` and `control/`.

This is true by construction and is Samsung's documented forced restart for this phone; it has **not been
pressed during an iOS session**, because no session has run (below). On the first run over adb: start a
session, hold the two keys, and check that One UI boots and `oneios_root.sh status` reports no open session.

**From inside a working iOS.** xnuhost's host call `XH_HALT_RETURN` writes `session/return.request` and exits,
which is a return (3). What calls it from iOS (a Settings row, an AssistiveTouch action) is OneiOS's userland's
to add and is not needed for any of the above. The OneOS app's own *Back to One UI* does not go through
`return.request`: it runs `oneios_return.sh` directly (root's `return` verb), so it works without a watcher;
the two meet at the return's lock.

## One UI's data guards

- xnuhost and every iOS process run in a mount namespace where `/data` is the stage. One UI's app data,
  `/data/system`, `/data/misc` (keystore, gatekeeper, lock-screen files) do not exist there, and the session
  aborts if they do.
- The session scripts and the root script write only under the stage. They never call setenforce, never set a
  `persist.*` property, never talk to vold, keystore2, gatekeeper, weaver or locksettings, and mount nothing in
  init's namespace. `OneiosScriptTest` checks this on their text. The return unmounts nothing either: a
  namespace that still had the stage as its `/data` would see One UI's `/data` in its place, so its processes
  are ended instead, and what cannot be ended is a reboot.
- The Android guests' guard jars are not involved: an iOS guest has no binder client.

## Tests and build

- `core/model` `OneiosTest`: the S24 Ultra-only gating and the tick; manifest parsing (format version, paths,
  sizes, hashes, a runtime without xnuhost); verification against a manifest; unpacking a tar with the manifest
  first, last or under a top folder; damaged, padded and truncated packages; the release JSON and `.sha256` file.
- `core/root` `OneiosScriptTest`: the launcher, `oneios_root.sh` and `oneios_switch.sh`'s stage checks run under
  the machine's shells against a fake root (`ONEIOS_TEST_ROOT`; the scripts refuse it as uid 0 and start nothing
  there): the refusal without a runtime, a runtime without xnuhost, changed files, mismatched pairs; and the
  guards on the scripts' text.
- The same class runs **the way back** against a fake phone: the key readers, the poll, the watcher and
  `oneios_return.sh` themselves, with stand-ins for Android's tools
  (`core/root/src/test/resources/oneios/phone-tools.sh`), processes as folders, and a clock that runs faster.
  No real process is signalled. Covered: the chord on two devices, a short hold, one key, auto-repeat, an old
  session's reader, the poll with no event at all, the keys starting the return without a watcher; the watcher
  on xnuhost's end, on a request, on a missing `ready`, with a wiped `session/` folder, and with a return
  script that cannot run; the return in place after SIGTERM and after SIGKILL of tasks in other namespaces,
  with a surfaceflinger that died or outlived the composer; and a reboot for each failed check (a process that
  cannot be killed, a stage mount left anywhere, a mount on One UI's partitions, another vold, another SELinux
  mode, another boot, a zygote that started by itself, a composer, surfaceflinger or audioserver that does not
  come back, no system_server, a user that never unlocks), for a return that hangs (the guard) and for a
  return whose lock holder is gone. These are the scripts' logic, not the phone: `getevent`'s `*` mark, cgroup
  v2, the composer restart and the forced restart are still to be seen on the S24 Ultra.
- `./gradlew :core:model:test :core:root:testDebugUnitTest`. The app itself needs the SESL9 libraries from
  GitHub Packages (a token in `~/.config/twidget/github.properties`), as before this change.

## CI: the APK without a personal token

`.github/workflows/oneios-apk.yml`, on every push to `oneios` and by hand (`gh workflow run oneios-apk.yml -R
akshaynexus/OneOS --ref oneios`):

1. Reads tribalfs' SESL9 and oneui-design packages with the run's own `GITHUB_TOKEN` (`permissions: packages:
   read`), passed as `GH_PACKAGES_USER` / `GH_PACKAGES_TOKEN`, which `settings.gradle.kts` already takes. The first
   step tries it on one file and prints GitHub's answer; if that is a refusal, it uses the optional repository
   secret `GH_PACKAGES_TOKEN` (a token with `read:packages`) and says which one it used.
2. Builds the in-guest app (`scripts/build-guest-manager.sh --debug`), runs the unit tests, and builds the normal
   full edition: `:app:assembleFullDebug` with the default `oneos.packSets` (unset). That packs no package set:
   the build records each set file's size and download source from `packages/remote.txt` and `sizes.txt`, and the
   app downloads them by SHA-256. So upstream's `out/overlays*` folders are not needed, and the APK holds no OEM
   file and no image.
3. Uploads `OneOS-oneios-<version>-debug.apk` as an artifact and attaches it to the prerelease `oneios-<version>`
   on the fork, recreated at the built commit each time.

Each run signs with a debug key of its own unless the secret `ONEIOS_DEBUG_KEYSTORE_B64` (a base64 debug keystore)
is set, so without it an earlier build has to be uninstalled before a new one installs. The in-guest app is a
debug build too: Android guests that already hold upstream's release-signed one cannot take it as an update.

## Not done yet

- **xnuhost does not exist yet.** The switch starts whatever the runtime package names, by the contract above;
  the booter's own interface on OneiOS's board (`docs/agents.md`) replaces that command line if it differs.
- Nothing past the preflight has run on a phone: the zygote stop without a guest framework, the watchdog feeder,
  the wakelock, and the in-place return are written from OneOS's Android session and need their first run over
  adb with the owner watching. For the way back, that run should check, in this order: `getevent -pl
  /dev/input/event0` with Volume Up held shows `KEY_VOLUMEUP*`; `/sys/fs/cgroup/cgroup.controllers` exists; a
  session returns on the chord; it returns with `kill -9` of xnuhost and with `kill -STOP` of it (the keys
  still work); the composer restart brings One UI's display back; Power + Volume Down restarts into One UI.
- Left undone in the way back (2026-11-10): no return splash, so nothing like OneOS's composer hold; no
  "Back to One UI" inside iOS (xnuhost's `XH_HALT_RETURN` is there, nothing in the guest calls it); the watcher
  does not restart a key reader that died (the poll and the other readers cover it); the Bluetooth, camera and
  vibrator HALs are not restarted at the return (OneiOS's bridges are to name the ones that need it); the CI
  step that installs mksh for the script tests has not run yet.
- The display helper xnuhost asks for (a root SurfaceControl layer that shows the frames of
  `session/display.sock`) is not written. When it is, it belongs to the session: started after xnuhost, in its
  cgroup, so that the return ends it with the rest.
- No boot or return splash for iOS, no log collection in the app (the logs are in the stage), no Quick switch.
- Wi-Fi: One UI's supplicant leaves with its framework. Networking in the guest is xnuhost's to solve.
- The image format follows `oneos/interface.md` until OneiOS's `docs/image-format.md` is written.
- The app update, release scripts and the Probe edition know nothing of iOS.

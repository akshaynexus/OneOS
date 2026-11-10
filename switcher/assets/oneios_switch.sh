#!/system/bin/sh
# The OneiOS session: One UI's framework stops and xnuhost (XNU as a process,
# from the OneiOS runtime package) starts with the staged iOS image set.
# docs/oneios.md; the contract with xnuhost is OneiOS's oneos/interface.md
# (session ABI 1). Modelled on oneos_switch.sh: every refusal comes before the
# first change, One UI's zygote is stopped and kept stopped, and the way back
# (oneios_return.sh: in place, else a reboot) is armed before the stop.
#
#   oneios_switch.sh            the session (preflight, stop, start xnuhost)
#   oneios_switch.sh --check    the preflight only; changes nothing
#   oneios_switch.sh --inner    (internal) inside the session's mount namespace
#   oneios_switch.sh --watch    (internal) the watcher that returns to One UI
#   oneios_switch.sh --keys D TOK        (internal) Volume Up + Volume Down, from device D's events
#   oneios_switch.sh --keys-poll TOK D.. (internal) the same chord from the keys' state (works under a grab)
#   oneios_switch.sh --feed     (internal) Samsung's software watchdog feeder
#   oneios_switch.sh --stop-loop (internal) keeps One UI's zygote stopped
#
# What a session never touches: One UI's /data beyond $STAGE (xnuhost's mount
# namespace has the stage bound over /data), vold, keystore2, gatekeeper,
# weaver, the lock-screen files, SELinux's mode, persist.* properties.
# What it changes, all undone by oneios_return.sh or a reboot: One UI's zygote
# (and zygote_secondary) stopped, the kernel wakelock oneios_session, Samsung's
# software watchdog closed and fed, the cgroup oneios_session (xnuhost's own).
#
# The ways back to One UI, none of which needs anything from the guest
# (docs/oneios.md, "Getting back to One UI"):
#   1  Volume Up + Volume Down held 3 s: one reader per key device (--keys) and
#      a poll of the keys' state (--keys-poll) that a grab cannot starve.
#   2  the watcher (--watch): on a request, when xnuhost ends, when the guest
#      never reports ready. If it does not act on the keys, the key readers
#      start the return themselves.
#   3  oneios_return.sh: in place, a reboot on any doubt, and a reboot by its
#      own guard if it does not finish.
#   4  Power + Volume Down held: the phone's own forced restart, below all of this.

# Tests (OneiosScriptTest) set ONEIOS_TEST_ROOT to a folder that stands for /:
# then only the stage checks run, never as root, and no session is started.
# The watcher and the key readers (--watch, --keys, --keys-poll) can be run
# there by themselves: against that folder's proc, sys and stage, with its
# bin/ first on PATH (stand-ins for getevent, getprop, setprop, ...), and with
# its bin/kill and bin/sleep in place of the shell's, so a test never signals
# a real process.
T="${ONEIOS_TEST_ROOT:-}"
if [ -n "$T" ]; then
    [ "$(id -u)" != 0 ] || { echo "PREFLIGHT REFUSED: ONEIOS_TEST_ROOT is for tests, never as root"; exit 3; }
    PATH="$T/bin:$PATH"; export PATH
    kill() { "$T/bin/kill" "$@"; }
    sleep() { "$T/bin/sleep" "$@"; }
fi
SH=/system/bin/sh
[ -z "$T" ] || SH="${ONEIOS_TEST_SH:-/bin/sh}"
P="$T/proc"
STAGE="$T/data/local/tmp/oneios"
ANDROID_STAGE="$T/data/local/tmp/oneos"
# session/ is what xnuhost and the switch share (its log, its pid, ready,
# return.request, display.sock). control/ is the way back's own: the state,
# the baseline, the pids, the keys. xnuhost's namespace has it read-only, so
# nothing the guest does to its /data can change what the watcher, the key
# readers and the return read.
SESSION="$STAGE/session"
CTL="$STAGE/control"
SELF="$STAGE/oneios_switch.sh"
ABI=1
APP="${ONEIOS_APP:-0}"
[ "$APP" = 1 ] || APP=0
MODE="${1:-session}"
OWNER=0
[ -z "$T" ] || OWNER=$(id -u)

refuse() {
    echo "PREFLIGHT REFUSED: $*"
    echo "Nothing on the phone was changed; One UI keeps running."
    exit 2
}
# Owned by root and writable by root only (stat %A: group w is the 6th
# character, other w the 9th), and not a link.
root_only() {
    [ ! -L "$1" ] || return 1
    case "$(stat -c '%u %A' "$1" 2>/dev/null)" in
        "$OWNER "?????w*|"$OWNER "????????w*) return 1 ;;
        "$OWNER "*) return 0 ;;
    esac
    return 1
}
conf() { # <file> <key>: the value of key=value, first match
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}
boot_id() { cat "$T/proc/sys/kernel/random/boot_id" 2>/dev/null; }
# "dev:inode:size:mtime" of a file: what root recorded when it staged it.
file_id() { stat -c '%d:%i:%s:%Y' "$1" 2>/dev/null; }

# --- THE WAY BACK'S OWN HELPERS ---------------------------------------------
# The watcher and the key readers must run whatever the guest does. They are
# One UI-side processes in init's mount namespace; this puts the calling shell
# in the root cgroup (which cannot be frozen, has no limits and is not killed
# with the app's group; xnuhost gets a cgroup of its own, see --inner), on
# every core, ahead of ordinary processes and out of the OOM killer's reach.
out_of_the_way() {
    # (2>/dev/null first: a path that is not there is not worth a line.)
    echo $$ 2>/dev/null > "$T/sys/fs/cgroup/cgroup.procs"
    echo -1000 2>/dev/null > "$P/$$/oom_score_adj"
    for g in /dev/cpuset /dev/cpuctl; do
        [ -w "$T$g/cgroup.procs" ] && echo $$ 2>/dev/null > "$T$g/cgroup.procs"
    done
    renice -n -10 -p $$ >/dev/null 2>&1
    return 0
}
# The keys ask the watcher, which acts within a second. A session that is
# still not returning 5 s later has no working watcher (killed, or stuck): the
# return then starts from the key reader itself. oneios_return.sh takes one
# caller at a time, so the two can meet.
ask_return() { # <why>
    [ -e "$SESSION/return.request" ] || echo "$1 at $(date '+%F %T')" > "$SESSION/return.request"
    sleep 5
    case "$(cat "$CTL/state" 2>/dev/null)" in
        starting|running)
            echo "$(date '+%F %T') keys: the watcher did not start the return within 5 s of '$1'; starting it from the key reader" >> "$STAGE/return.log"
            # In a session of its own: the return ends the key readers by
            # their process groups, and this is one of them.
            if [ -n "$BB" ]; then exec "$BB" setsid $SH "$STAGE/oneios_return.sh" keys-direct >> "$STAGE/return.log" 2>&1
            else exec $SH "$STAGE/oneios_return.sh" keys-direct >> "$STAGE/return.log" 2>&1; fi ;;
    esac
    return 0
}
# A key reader is started in a session of its own (setsid), so it leads a
# process group that holds only itself, its getevent and its timers: the
# return, and a reader that finds it is no longer this session's, end the
# whole group at once. The reader lists itself for the return.
reader_start() {
    echo $$ >> "$CTL/keys/pids"
    OWN_GROUP=0
    [ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" = "$$" ] && OWN_GROUP=1
    out_of_the_way
}
reader_end() {
    [ "$OWN_GROUP" = 1 ] && kill -9 -- "-$$" 2>/dev/null
    exit 0
}
# The display helper (OneiOS's runtime/display, bin/oneios-display): a One
# UI-side process that shows the guest's frames (session/display.sock) on a
# surfaceflinger layer. Ended by its pid, never waited for: surfaceflinger
# drops a dead client's layers, and the return restarts the composer anyway.
end_display() {
    for dp in $(cat "$CTL/display.pid" 2>/dev/null); do
        case "$(tr '\0' ' ' 2>/dev/null < "$P/$dp/cmdline")" in
            *OneiOSDisplay*|*oneios-display*) kill -9 "$dp" 2>/dev/null ;;
        esac
    done
    return 0
}
# The reboot return without oneios_return.sh, for the watcher when that script
# cannot be run or ends with an error: the same three steps as its failsafe.
hard_reboot() { # <reason word> <why>
    echo "$(date '+%F %T') watcher: $2 - rebooting into One UI"
    echo "failsafe $(date +%s) $2" > "$STAGE/return.outcome"
    sync
    setprop sys.powerctl "reboot,$1"
    sleep 20
    sync
    [ -n "$BB" ] && "$BB" reboot -f
    sleep 5
    echo 1 > "$P/sys/kernel/sysrq" 2>/dev/null
    echo s > "$P/sysrq-trigger" 2>/dev/null
    sleep 2
    echo b > "$P/sysrq-trigger" 2>/dev/null
    exit 1
}

# --- THE STAGE (no root tools needed; also what the tests run) -------------
# The runtime package and the image set as oneios_root.sh staged them. A
# missing runtime or image is the usual refusal: one line that says which.
stage_checks() {
    [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || refuse "OneiOS is not set up on this phone ($STAGE is missing)"
    root_only "$STAGE" || refuse "$STAGE is not root's or is writable by others"
    for f in oneios_switch.sh oneios_return.sh; do
        [ -f "$STAGE/$f" ] && root_only "$STAGE/$f" || refuse "$STAGE/$f is missing or not root's"
    done

    # The runtime: runtime.conf (written by root from the checked runtime.json),
    # runtime.sha256 (every file root wrote), and xnuhost itself.
    RC="$STAGE/runtime.conf"
    [ -f "$RC" ] && [ -d "$STAGE/runtime" ] && [ ! -L "$STAGE/runtime" ] ||
        refuse "no OneiOS runtime is staged: xnuhost, the program that runs iOS, comes with it (download or import the runtime in the OneOS app)"
    root_only "$RC" && root_only "$STAGE/runtime" || refuse "the staged runtime is not root's"
    R_VERSION=$(conf "$RC" version)
    R_ABI=$(conf "$RC" session_abi)
    R_XNUHOST=$(conf "$RC" xnuhost)
    R_FORMATS=$(conf "$RC" image_formats)
    case "$R_XNUHOST" in
        ''|/*|*..*|*[!A-Za-z0-9._/+-]*) refuse "the runtime ${R_VERSION:-?} names no xnuhost (runtime.conf: '${R_XNUHOST}')" ;;
    esac
    [ "$R_ABI" = "$ABI" ] ||
        refuse "the runtime ${R_VERSION:-?} speaks session ABI ${R_ABI:-none}, this OneOS speaks $ABI: update the OneOS app or the runtime"
    X="$STAGE/runtime/$R_XNUHOST"
    [ -f "$X" ] && [ ! -L "$X" ] ||
        refuse "the runtime ${R_VERSION:-?} has no xnuhost ($R_XNUHOST): it cannot start iOS yet"
    root_only "$X" && [ -x "$X" ] || refuse "xnuhost is not root's, or not executable"
    # OneiOS's packages carry a stand-in that only prints "not built yet" until
    # xnuhost is built (runtime.json "placeholder": true). One UI is not stopped for it.
    [ "$(conf "$RC" placeholder)" != 1 ] ||
        refuse "the runtime ${R_VERSION:-?} carries a placeholder instead of xnuhost (OneiOS has not built xnuhost yet): it cannot start iOS"
    # An arm64 ELF executable: "\177ELF", class 2 (64-bit), e_machine 0xb7.
    [ "$(od -An -tx1 -N5 "$X" 2>/dev/null | tr -d ' \n')" = 7f454c4602 ] &&
        [ "$(od -An -tx1 -j18 -N2 "$X" 2>/dev/null | tr -d ' \n')" = b700 ] ||
        refuse "xnuhost is not an arm64 program"
    check_list runtime full

    # The image set: its format must be one this runtime boots.
    IC="$STAGE/image.conf"
    [ -f "$IC" ] && [ -d "$STAGE/image" ] && [ ! -L "$STAGE/image" ] ||
        refuse "no iOS image set is staged: import the one you built with OneiOS's scripts in the OneOS app"
    root_only "$IC" && root_only "$STAGE/image" || refuse "the staged image set is not root's"
    I_FORMAT=$(conf "$IC" format)
    I_VERSION=$(conf "$IC" version)
    I_BUILD=$(conf "$IC" build)
    case "$I_FORMAT" in ''|*[!0-9]*) refuse "the image set has no format number (image.conf)" ;; esac
    case ",$R_FORMATS," in
        *",$I_FORMAT,"*) ;;
        *) refuse "the image set is format $I_FORMAT, the runtime ${R_VERSION:-?} boots format(s) ${R_FORMATS:-none}: build the image again or take a matching runtime" ;;
    esac
    check_list image ids
}
# <runtime|image> <full|ids>: $STAGE/<kind>.sha256 lists exactly the files of
# $STAGE/<kind>, each root's. full: every SHA-256 again (the runtime is small).
# ids: each file is the one root hashed at staging (dev:inode:size:mtime in
# <kind>.ids); files under 64 MiB are hashed again, and all of them with
# ONEIOS_VERIFY_IMAGE=1 (minutes for an image of several GB).
check_list() {
    kind=$1 how=$2
    SUMS="$STAGE/$kind.sha256"
    [ -f "$SUMS" ] && root_only "$SUMS" || refuse "$kind.sha256 is missing or not root's: stage the $kind again"
    bad=$(awk 'NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 !~ /^[A-Za-z0-9_][A-Za-z0-9._+\/-]*$/ || $2 ~ /\.\./ ||
               seen[$2]++ { print NR ": " $0 }' "$SUMS" | head -n 3)
    [ -z "$bad" ] || refuse "$kind.sha256 has malformed lines: $bad"
    [ -s "$SUMS" ] || refuse "$kind.sha256 is empty"
    if [ "$how" = ids ]; then
        IDS="$STAGE/$kind.ids"
        [ -f "$IDS" ] && root_only "$IDS" || refuse "$kind.ids is missing or not root's: stage the $kind again"
    fi
    while read -r sum name || [ -n "$sum" ]; do
        f="$STAGE/$kind/$name"
        [ -f "$f" ] && [ ! -L "$f" ] || refuse "$kind/$name is missing or a link: stage the $kind again"
        root_only "$f" || refuse "$kind/$name is not root's or is writable by others"
        hash=1
        if [ "$how" = ids ]; then
            want=$(awk -v n="$name" '$2 == n { print $1 }' "$IDS")
            [ -n "$want" ] && [ "$(file_id "$f")" = "$want" ] ||
                refuse "$kind/$name changed since it was staged: stage the $kind again"
            # (awk, not the shell: Android's sh counts in 32 bits, and an image of several GB wraps.)
            [ "${ONEIOS_VERIFY_IMAGE:-0}" = 1 ] || awk -v b="$(stat -c %s "$f" 2>/dev/null)" 'BEGIN { exit !(b + 0 < 67108864) }' || hash=0
        fi
        if [ $hash = 1 ]; then
            [ "$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" = "$sum" ] ||
                refuse "$kind/$name does not match its SHA-256: stage the $kind again"
        fi
    done < "$SUMS"
    # Nothing the list does not name (a leftover would be visible to xnuhost).
    extra=$(cd "$STAGE/$kind" && find . ! -type d | sed 's|^\./||' | while read -r n; do
        awk -v n="$n" '$2 == n { f = 1 } END { exit !f }' "$SUMS" || echo "$n"
    done | head -n 3 | tr '\n' ' ')
    [ -z "$extra" ] || refuse "$kind/ holds files its list does not name ($extra): stage the $kind again"
}

# --- INTERNAL MODES --------------------------------------------------------
case "$MODE" in
    --inner)
        # Inside the new mount namespace (unshare -m), still root. The stage
        # becomes /data: nothing else of One UI's /data exists in here.
        [ -z "$T" ] || exit 3
        die_inner() { echo "oneios inner: $*"; exit 70; }
        R_XNUHOST=$(conf "$STAGE/runtime.conf" xnuhost)
        [ -n "$BB" ] && [ -x "$BB" ] || die_inner "no busybox"
        [ "$(readlink /proc/$$/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ] || die_inner "still in init's mount namespace"
        "$BB" mount --make-rprivate / || die_inner "could not make the mounts private"
        "$BB" mount --bind "$STAGE" /data || die_inner "could not bind the stage over /data"
        # Read-only in here: the runtime and the image (as staged), and what
        # the way back runs and reads (its scripts, its control folder).
        for d in runtime image control bin oneios_switch.sh oneios_return.sh; do
            [ -e "/data/$d" ] || continue
            "$BB" mount --bind "/data/$d" "/data/$d" && "$BB" mount -o remount,bind,ro "/data/$d" ||
                die_inner "could not make /data/$d read-only"
        done
        if : 2>/dev/null > /data/control/.w; then
            rm -f /data/control/.w
            die_inner "the way back's control folder is writable in the session's namespace"
        fi
        # The guard this session rests on: One UI's data is not reachable here.
        [ ! -e /data/system ] && [ ! -e /data/misc ] && [ ! -e /data/user ] && [ -f /data/runtime.conf ] ||
            die_inner "One UI's /data is still visible in the session's namespace"
        cd /data || die_inner "cd /data"
        mkdir -p /data/data /data/session/tmp && chmod 0700 /data/data /data/session/tmp || die_inner "could not make /data/data"
        echo $$ > /data/session/xnuhost.pid || die_inner "could not write the pid"
        # A cgroup of its own for xnuhost and everything it starts (cgroup v2,
        # no controller needed): the watcher, the key readers and the return
        # are in the root group, never in the guest's, and the return ends the
        # whole group at once (cgroup.kill) wherever a task of it went. Without
        # cgroup v2 (its root has cgroup.controllers) the return has the mount
        # namespace alone, as before.
        CG=/sys/fs/cgroup/oneios_session
        if [ -f /sys/fs/cgroup/cgroup.controllers ] && mkdir -p "$CG" 2>/dev/null && echo $$ > "$CG/cgroup.procs" 2>/dev/null; then
            echo "oneios inner: cgroup $CG"
        else
            echo "oneios inner: no cgroup of its own ($CG); the return ends the session by its mount namespace"
        fi
        # The switch is exempt from the OOM killer (-1000) and xnuhost would
        # inherit that: with memory gone the kernel would then end One UI's
        # daemons, or panic. The guest is what goes first; its end is a return.
        echo 500 > /proc/$$/oom_score_adj 2>/dev/null
        export ONEIOS_SESSION_ABI=$ABI ONEIOS_MODE=takeover ONEIOS_RUNTIME=/data/runtime ONEIOS_IMAGE=/data/image \
               ONEIOS_DATA=/data/data ONEIOS_SESSION=/data/session TMPDIR=/data/session/tmp
        unset BB ONEIOS_APP ONEIOS_TEST_ROOT
        echo "oneios inner: $(date '+%F %T') starting /data/runtime/$R_XNUHOST (pid $$)"
        exec "/data/runtime/$R_XNUHOST" --session-abi $ABI --mode takeover \
            --runtime /data/runtime --image /data/image --data /data/data --session /data/session
        echo "oneios inner: could not exec xnuhost"
        exit 71
        ;;
    --stop-loop)
        # One UI's zygote must stay stopped: other services restart it
        # (onrestart), and a zygote that starts would bring system_server back
        # next to the guest. oneios_return.sh ends this loop before it starts
        # One UI ($CTL/stop-loop.off, then the pid).
        [ -z "$T" ] || exit 3
        while [ ! -e "$CTL/stop-loop.off" ]; do
            [ "$(getprop init.svc.zygote)" = running ] && setprop ctl.stop zygote
            [ "$(getprop init.svc.zygote_secondary)" = running ] && setprop ctl.stop zygote_secondary
            [ "$(getprop init.svc.bootanim)" = running ] && setprop ctl.stop bootanim
            sleep 0.2
        done
        exit 0
        ;;
    --feed)
        # One UI's system_server opened Samsung's software watchdog (100 s) and
        # kicked it; stopped, it leaves the timer running and the phone panics
        # ("Software Watchdog Timer expired 100s", oneos_switch.sh [4b/6]). "V"
        # is the magic close where the driver allows it, and a kick otherwise.
        [ -z "$T" ] || exit 3
        L="$CTL/watchdog_feeder.log"
        was=""
        while [ ! -e "$CTL/feeder.off" ]; do
            now=""
            for wd in /dev/watchdog /dev/softdog $(cat "$CTL/softdog_nodes" 2>/dev/null); do
                [ -c "$wd" ] || continue
                if e=$(printf V 2>&1 > "$wd"); then now="$now $wd:written"; else now="$now $wd:refused($e)"; fi
            done
            for w in /sys/class/watchdog/watchdog*; do
                [ "$(cat "$w/state" 2>/dev/null)" = active ] || continue
                case "$(cat "$w/identity" 2>/dev/null)" in *[Ss]oft*) ;; *) continue ;; esac
                d=/dev/${w##*/}
                [ -c "$d" ] || continue
                if e=$(printf V 2>&1 > "$d"); then now="$now $d:kicked"; else now="$now $d:refused($e)"; fi
            done
            [ "$now" = "$was" ] || { echo "$(date +%T)$now" >> "$L"; was=$now; }
            sleep 2
        done
        exit 0
        ;;
    --keys)
        # Volume Up + Volume Down held 3 s, from one key device's events.
        # getevent only reads: it never grabs (EVIOCGRAB), so the guest still
        # gets the keys, and it is a One UI-side process the guest cannot
        # block. It only asks for the return (ask_return). A later session
        # (another token) ends this reader, with its getevent, on its next event.
        [ -n "$2" ] && [ -n "$3" ] || exit 3
        kd=$2 tok=$3
        KS="$CTL/keys"
        reader_start
        getevent -lq "$kd" 2>/dev/null | while read -r typ code val rest; do
            [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ] || reader_end
            case "$code" in KEY_VOLUMEUP) k=up ;; KEY_VOLUMEDOWN) k=down ;; *) continue ;; esac
            # DOWN and UP only (getevent -l's names, or the bare values). The
            # auto-repeat of a held key (REPEAT, on a device with EV_REP) is
            # not a release: taken as one, a hold would never reach 3 s.
            case "$val" in DOWN|00000001) v=DOWN ;; UP|00000000) v=UP ;; *) continue ;; esac
            echo "$v" > "$KS/$k"
            if [ "$(cat "$KS/up" 2>/dev/null)" = DOWN ] && [ "$(cat "$KS/down" 2>/dev/null)" = DOWN ]; then
                both="$(date +%s).$$.$kd.$RANDOM"; echo "$both" > "$KS/both"
                ( sleep 3
                  [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ] && [ "$(cat "$KS/both" 2>/dev/null)" = "$both" ] &&
                      [ "$(cat "$KS/up" 2>/dev/null)" = DOWN ] && [ "$(cat "$KS/down" 2>/dev/null)" = DOWN ] &&
                      ask_return "keys: Volume Up + Volume Down held 3 s" ) &
            else
                : > "$KS/both"
            fi
        done
        exit 0
        ;;
    --keys-poll)
        # The same chord without the event stream. "getevent -pl DEVICE" asks
        # the device for its keys' state (EVIOCGKEY) and marks a key that is
        # down with "*". A program that grabs a device (EVIOCGRAB) takes its
        # events from every other reader, the one above included, but not this
        # state: so the chord works even if xnuhost grabs the keys, which its
        # contract forbids (OneiOS docs/agents.md). Twice a second; seven
        # samples in a row with both keys down are 3 s.
        [ -n "$2" ] && [ -n "$3" ] || exit 3
        tok=$2
        shift 2
        KS="$CTL/keys"
        reader_start
        TMO=""
        command -v timeout >/dev/null 2>&1 && TMO="timeout 2"
        n=0
        while [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ]; do
            st=$(for kd in "$@"; do $TMO getevent -pl "$kd" 2>/dev/null; done)
            held=0
            case "$st" in *"KEY_VOLUMEUP*"*) case "$st" in *"KEY_VOLUMEDOWN*"*) held=1 ;; esac ;; esac
            if [ $held = 1 ]; then n=$((n + 1)); else n=0; fi
            if [ $n -ge 7 ]; then
                n=0
                ask_return "keys: Volume Up + Volume Down down for 3 s (polled)"
            fi
            sleep 0.5
        done
        exit 0
        ;;
    --watch)
        # The way back, armed before One UI's zygote stops. A One UI-side
        # process: init's mount namespace, its own session (setsid), the root
        # cgroup, never the OOM killer's, so nothing the guest does can stop
        # or freeze it. It returns to One UI when: the switch did not get as
        # far as starting xnuhost (60 s), xnuhost ended, a return was asked
        # ($SESSION/return.request: the volume keys, the guest, adb), or the
        # guest never said it is up ($SESSION/ready) within ONEIOS_RETURN_MAX
        # seconds of its start (600; 0 = no limit).
        echo $$ > "$CTL/watcher.pid"
        out_of_the_way
        MAX="${ONEIOS_RETURN_MAX:-600}"
        case "$MAX" in ''|*[!0-9]*) MAX=600 ;; esac
        awake() { echo oneios_session 2>/dev/null > "$T/sys/power/wake_lock"; }
        go() {
            echo "$(date '+%F %T') watcher: $*; returning to One UI"
            # The guest's picture goes first: nothing of the return waits for it.
            end_display
            # Not exec: a return script that cannot be run (gone, damaged) or
            # that ends with an error must still end in One UI, by the reboot.
            # A return that hangs is its own guard's to end (oneios_return.sh).
            $SH "$STAGE/oneios_return.sh" watcher
            rc=$?
            [ $rc = 0 ] && exit 0
            hard_reboot oneios-watcher-failsafe "oneios_return.sh ended with $rc in state '$(cat "$CTL/state" 2>/dev/null)'"
        }
        t=0
        while [ "$(cat "$CTL/state" 2>/dev/null)" = starting ]; do
            [ -e "$SESSION/return.request" ] && go "return asked before xnuhost started ($(head -c 200 "$SESSION/return.request" 2>/dev/null))"
            [ $t -lt 60 ] || go "the switch did not start xnuhost within 60 s"
            sleep 1; t=$((t + 1))
        done
        case "$(cat "$CTL/state" 2>/dev/null)" in
            running) ;;
            # A return someone else started (the app, adb, the key readers): theirs.
            returning|returned) echo "$(date '+%F %T') watcher: a return is under way or done; nothing to do"; exit 0 ;;
            *) go "the switch ended in state '$(cat "$CTL/state" 2>/dev/null)'" ;;
        esac
        pid=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
        ns=$(cat "$CTL/mntns" 2>/dev/null)
        t=0
        while :; do
            # A return someone else started (the app, adb, the key readers) is
            # theirs, with its own guard. Any other state, an unreadable one
            # included, is still this session.
            case "$(cat "$CTL/state" 2>/dev/null)" in
                returning|returned) echo "$(date '+%F %T') watcher: a return is under way or done; nothing to do"; exit 0 ;;
            esac
            [ -e "$SESSION/return.request" ] && go "return asked ($(head -c 200 "$SESSION/return.request" 2>/dev/null))"
            [ -n "$pid" ] && [ "$(readlink "$P/$pid/ns/mnt" 2>/dev/null)" = "$ns" ] ||
                go "xnuhost $pid ended (last log lines: $(tail -n 3 "$SESSION/xnuhost.log" 2>/dev/null | tr '\n' '|' | cut -c1-300))"
            if [ "$MAX" -gt 0 ] && [ ! -e "$SESSION/ready" ] && [ $t -ge "$MAX" ]; then
                go "the guest did not report ready within ${MAX}s"
            fi
            # Nothing else keeps the phone awake with One UI's framework gone:
            # the session's wakelock again every 10 s, whoever released it.
            [ $((t % 10)) = 0 ] && awake
            sleep 1; t=$((t + 1))
        done
        ;;
    session|--check) ;;
    *) echo "usage: oneios_switch.sh [--check]"; exit 3 ;;
esac

# --- PREFLIGHT ------------------------------------------------------------
# Every refusal comes before the first change to the phone, so a refused
# switch leaves One UI exactly as it was.
if [ -n "$T" ]; then
    stage_checks
    echo "TEST ROOT: stage checks passed (runtime $R_VERSION, xnuhost $R_XNUHOST, image $I_VERSION $I_BUILD format $I_FORMAT); nothing was started"
    exit 0
fi
[ "$(id -u 2>/dev/null)" = 0 ] || refuse "not running as root"
command -v sha256sum >/dev/null 2>&1 || refuse "no sha256sum"

# This phone only: the Galaxy S24 Ultra (docs/oneios.md, "Scope").
P_MODEL=$(getprop ro.product.model)
P_DEVICE=$(getprop ro.product.device)
P_SOC=$(getprop ro.soc.model)
case "$P_MODEL" in SM-S928*) ;; *) refuse "iOS runs on the Galaxy S24 Ultra (SM-S928) only; this phone is ${P_MODEL:-unknown}" ;; esac
[ "$P_DEVICE" = e3q ] && [ "$P_SOC" = SM8650 ] ||
    refuse "iOS runs on the Galaxy S24 Ultra (e3q, SM8650) only; this phone is ${P_DEVICE:-?}, ${P_SOC:-?}"

# The stage first: without a runtime that has xnuhost, that one line is the answer.
stage_checks

# Root tools: the root manager's own busybox and resetprop, as oneos_switch.sh.
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { BB=$c; break; }
done
RP=""
for c in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /debug_ramdisk/resetprop /sbin/resetprop; do
    [ -x "$c" ] && { RP=$c; break; }
done
[ -n "$BB" ] || refuse "no busybox at the root manager's paths (/data/adb/ksu/bin, /data/adb/ap/bin, /data/adb/magisk)"
APPLETS=" $("$BB" --list 2>/dev/null | tr '\n' ' ') "
missing=""
for a in sh mount umount unshare nsenter setsid awk grep sed reboot; do
    case "$APPLETS" in *" $a "*) ;; *) missing="$missing $a" ;; esac
done
[ -z "$missing" ] || refuse "$BB lacks the applets:$missing"
[ -n "$RP" ] || refuse "no resetprop at the root manager's paths: One UI's boot counters could not be put back on the return"

# init's mount namespace: the session's own namespace is made from it, and the
# return checks init's mount table.
SELF_NS=$(readlink /proc/$$/ns/mnt 2>/dev/null)
INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
if [ -z "$SELF_NS" ] || [ "$SELF_NS" != "$INIT_NS" ]; then
    if [ "$APP" != 1 ] && [ -z "$ONEIOS_NS_REENTERED" ]; then
        echo "Not in init's mount namespace: running again in init's"
        export ONEIOS_NS_REENTERED=1
        exec "$BB" nsenter -t 1 -m -- /system/bin/sh "$SELF" "$@"
    fi
    refuse "not in init's mount namespace (this shell: ${SELF_NS:-unreadable}, init: ${INIT_NS:-unreadable})"
fi

# One UI must be whole and no session of either kind may be up.
[ "$(getprop sys.boot_completed)" = 1 ] || refuse "One UI has not finished starting"
[ "$(getprop init.svc.zygote)" = running ] && pidof system_server >/dev/null 2>&1 ||
    refuse "One UI's framework is not running (another session, or a return in progress): restart the phone first"
pidof surfaceflinger >/dev/null 2>&1 || refuse "One UI's surfaceflinger is not running"
left=$(awk -v s="$STAGE" -v o="$ANDROID_STAGE" '$5 == s || index($5, s "/") == 1 || index($5, o "/") == 1 { print $5 }' /proc/self/mountinfo | head -n 3 | tr '\n' ' ')
[ -z "$left" ] || refuse "mounted under a stage ($left): a session is running or never returned; restart the phone first"
if [ "$(cat "$CTL/boot" 2>/dev/null)" = "$(boot_id)" ]; then
    case "$(cat "$CTL/state" 2>/dev/null)" in
        starting|running|returning) refuse "an iOS session of this boot is still open ($(cat "$CTL/state")): restart the phone first" ;;
    esac
fi
op=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
on=$(cat "$CTL/mntns" 2>/dev/null)
[ -z "$op" ] || [ -z "$on" ] || [ "$(readlink "/proc/$op/ns/mnt" 2>/dev/null)" != "$on" ] ||
    refuse "xnuhost of an earlier session is still running (pid $op): restart the phone first"
old=""
for p in $(head -n 3 /sys/fs/cgroup/oneios_session/cgroup.procs 2>/dev/null); do [ -d "/proc/$p" ] && old="$old$p "; done
[ -z "$old" ] || refuse "processes of an earlier iOS session are still running (cgroup oneios_session: $old): restart the phone first"

# The ways back: the volume keys, and enough battery to get there.
command -v getevent >/dev/null 2>&1 || refuse "no getevent: Volume Up + Volume Down could not return to One UI"
command -v ps >/dev/null 2>&1 || refuse "no ps: the key readers could not be told apart"
KEYS=$(getevent -pl 2>/dev/null)
case "$KEYS" in *KEY_VOLUMEUP*) ;; *) refuse "no Volume Up key found (getevent)" ;; esac
case "$KEYS" in *KEY_VOLUMEDOWN*) ;; *) refuse "no Volume Down key found (getevent)" ;; esac
KDEVS=$(printf '%s\n' "$KEYS" | awk '/^add device/ { dev = $NF } /KEY_VOLUME(UP|DOWN)/ { print dev }' | sort -u)
BAT=/sys/class/power_supply/battery
CAP=$(cat $BAT/capacity 2>/dev/null)
BST=$(cat $BAT/status 2>/dev/null)
BTEMP=$(cat $BAT/temp 2>/dev/null)
case "$CAP" in ''|*[!0-9]*) refuse "battery not readable" ;; esac
case "${BTEMP#-}" in ''|*[!0-9]*) refuse "battery temperature not readable" ;; esac
[ "$CAP" -ge 30 ] || [ "$BST" = Charging ] || [ "$BST" = Full ] || refuse "battery at $CAP% and not charging"
[ "$BTEMP" -lt 420 ] || refuse "battery too warm ($((BTEMP / 10)) C)"
# Room for the guest's data store to grow (2 GiB).
set -- $(stat -f -c '%a %S' /data 2>/dev/null)
[ $# -eq 2 ] && [ "$(awk -v a="$1" -v s="$2" 'BEGIN { print (a * s >= 2147483648) ? 1 : 0 }')" = 1 ] ||
    refuse "less than 2 GiB free on /data"
[ -w /sys/power/wake_lock ] || refuse "no /sys/power/wake_lock: the phone would sleep with One UI's framework stopped"
# The app's experimental tick (root's switch verb passes it on).
[ "$APP" != 1 ] || [ "${ONEIOS_ACK_EXPERIMENTAL:-0}" = 1 ] || refuse "the experimental tick was not given"

echo "Preflight passed (runtime $R_VERSION, xnuhost $R_XNUHOST, image iOS $I_VERSION $I_BUILD format $I_FORMAT, busybox $BB, SELinux $(getenforce 2>/dev/null))"
if [ "$MODE" = --check ]; then
    echo "PREFLIGHT OK"
    exit 0
fi

# --- THE SESSION -----------------------------------------------------------
# From here on something changes. Out of the launching app's cgroup and away
# from the OOM killer first: ActivityManager kills an app's whole cgroup when
# the app dies, and a switch killed half way leaves One UI stopped.
echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
trap '' HUP PIPE
export BB

echo "=== [1/5] $(date +%T) Session folder and baseline ==="
# The last session's log is kept (five of them); its folder is this session's.
mkdir -p "$STAGE/logs" && chmod 0700 "$STAGE/logs"
[ -s "$SESSION/xnuhost.log" ] && mv -f "$SESSION/xnuhost.log" "$STAGE/logs/xnuhost-$(date +%s).log"
ls -1t "$STAGE/logs"/xnuhost-*.log 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done
[ ! -L "$SESSION" ] || refuse "$SESSION is a symlink"
[ ! -L "$CTL" ] || refuse "$CTL is a symlink"
rm -rf "$SESSION" "$CTL"
mkdir -p "$CTL/base" "$CTL/keys" "$SESSION/tmp" "$STAGE/data" && chown -R 0:0 "$SESSION" "$CTL" && chmod -R go-rwx "$SESSION" "$CTL" &&
    chmod 0700 "$STAGE/data" || refuse "could not make $SESSION"
: > "$SESSION/xnuhost.log"
boot_id > "$CTL/boot"
echo starting > "$CTL/state"
# What the in-place return compares against (oneios_return.sh), read while
# One UI is whole. Nothing here is changed by the session; the return only
# proves that.
B="$CTL/base"
boot_id > "$B/boot_id"
getenforce > "$B/selinux" 2>&1
getprop > "$B/props"
for n in vold keystore2 surfaceflinger servicemanager; do echo "$n $(pidof $n 2>/dev/null | tr ' ' ',')"; done > "$B/pids"
case "$(settings get global wifi_on 2>/dev/null)" in 1|2) echo 1 ;; *) echo 0 ;; esac > "$B/wifi_on"
awk '{ print $5 }' /proc/1/mountinfo | sort > "$B/mounts"
echo "Baseline: boot $(cat "$B/boot_id"), SELinux $(cat "$B/selinux"), $(tr '\n' ' ' < "$B/pids")wifi $(cat "$B/wifi_on")"

echo "=== [2/5] $(date +%T) Arming the way back ==="
# Before the stop: the watcher returns to One UI by itself if this script
# does not get as far as a running xnuhost. The watcher, the key readers and
# the poll are started here, in init's mount namespace, before xnuhost's
# namespace and cgroup exist: they are never part of either.
# Each of them writes its own pid (watcher.pid, keys/pids) once it runs.
"$BB" setsid $SH "$SELF" --watch </dev/null >>"$STAGE/return.log" 2>&1 &
KTOK="$$.$(date +%s)"
echo "$KTOK" > "$CTL/keys/session"
readers=1
for kd in $KDEVS; do
    "$BB" setsid $SH "$SELF" --keys "$kd" "$KTOK" </dev/null >/dev/null 2>&1 &
    readers=$((readers + 1))
done
"$BB" setsid $SH "$SELF" --keys-poll "$KTOK" $KDEVS </dev/null >/dev/null 2>&1 &
# With One UI's power manager gone nothing would keep the phone awake.
echo oneios_session > /sys/power/wake_lock 2>/dev/null
# One UI is stopped only with the way back in place: the watcher, a reader
# for every key device and the poll running, the wakelock held. Otherwise this
# is where the switch ends, with One UI untouched (the return only ends the
# helpers: there is no stop mark yet).
n=0
while [ $n -lt 25 ]; do
    [ -s "$CTL/watcher.pid" ] && [ "$(grep -c . "$CTL/keys/pids" 2>/dev/null)" = "$readers" ] && break
    sleep 0.2; n=$((n + 1))
done
armed=""
kill -0 "$(cat "$CTL/watcher.pid" 2>/dev/null)" 2>/dev/null || armed="the watcher is not running"
[ "$(grep -c . "$CTL/keys/pids" 2>/dev/null)" = "$readers" ] || armed="${armed:+$armed, }$(grep -c . "$CTL/keys/pids" 2>/dev/null) of $readers key readers started"
for p in $(cat "$CTL/keys/pids" 2>/dev/null); do
    kill -0 "$p" 2>/dev/null || armed="${armed:+$armed, }key reader $p is not running"
done
case " $(cat /sys/power/wake_lock 2>/dev/null) " in
    *" oneios_session "*) ;;
    *) armed="${armed:+$armed, }the wakelock oneios_session is not held" ;;
esac
if [ -n "$armed" ]; then
    echo "!!! The way back to One UI could not be armed ($armed): One UI was not stopped, nothing was changed"
    echo failed > "$CTL/state"
    $SH "$STAGE/oneios_return.sh" switch-not-armed
    exit 4
fi
echo "Return to One UI: hold Volume Up + Volume Down for 3 s (key devices: $(echo $KDEVS)); watcher $(cat "$CTL/watcher.pid"), key readers $(tr '\n' ' ' < "$CTL/keys/pids")"
echo "If that does nothing: hold Power + Volume Down until the phone restarts (about 7 s). It restarts into One UI."

echo "=== [3/5] $(date +%T) Stopping the One UI framework ==="
# The watchdog device(s) One UI's system_server keeps open, before it stops
# (oneos_switch.sh [4b/6]: recorded for the feeder).
for p in $(pidof system_server); do
    for fd in /proc/$p/fd/*; do
        t=$(readlink "$fd" 2>/dev/null)
        case "$t" in /dev/watchdog*|/dev/softdog*) echo "$t" ;; esac
    done
done 2>/dev/null | sort -u > "$CTL/softdog_nodes"
# From here One UI's framework is down: the return starts it again. Without
# this mark the return only tidies up (a switch that ended before the stop).
echo "$(date +%s)" > "$CTL/stopped"
setprop ctl.stop zygote
[ -n "$(getprop init.svc.zygote_secondary)" ] && setprop ctl.stop zygote_secondary
n=0
while [ $n -lt 50 ] && pidof system_server >/dev/null 2>&1; do sleep 0.2; n=$((n + 1)); done
kill -9 $(pidof system_server) 2>/dev/null
kill -9 $(pidof zygote64) $(pidof zygote) 2>/dev/null
"$BB" setsid /system/bin/sh "$SELF" --stop-loop </dev/null >/dev/null 2>&1 &
echo $! > "$CTL/stop-loop.pid"
# Samsung's software watchdog: its magic close now, then the feeder.
for wd in /dev/watchdog /dev/softdog $(cat "$CTL/softdog_nodes"); do
    [ -c "$wd" ] || continue
    if e=$(printf V 2>&1 > "$wd"); then echo "Softdog: $wd closed with V"; else echo "Softdog: $wd not written ($e)"; fi
done
"$BB" setsid /system/bin/sh "$SELF" --feed </dev/null >/dev/null 2>&1 &
echo $! > "$CTL/feeder.pid"
echo "One UI's zygote: $(getprop init.svc.zygote); system_server: $(pidof system_server 2>/dev/null || echo gone); surfaceflinger $(pidof surfaceflinger) kept"

echo "=== [4/5] $(date +%T) Starting xnuhost ==="
# A new mount namespace made from init's; --inner binds the stage over /data
# there and execs xnuhost, so the pid it writes is xnuhost's own.
"$BB" setsid "$BB" unshare -m /system/bin/sh "$SELF" --inner </dev/null >>"$SESSION/xnuhost.log" 2>&1 &
n=0
while [ $n -lt 50 ] && [ ! -s "$SESSION/xnuhost.pid" ]; do sleep 0.2; n=$((n + 1)); done
XP=$(cat "$SESSION/xnuhost.pid" 2>/dev/null)
XNS=$(readlink "/proc/$XP/ns/mnt" 2>/dev/null)
if [ -z "$XP" ] || [ -z "$XNS" ] || [ "$XNS" = "$INIT_NS" ]; then
    echo "!!! xnuhost did not start (pid '${XP}', namespace '${XNS}'): $(tail -n 5 "$SESSION/xnuhost.log" | tr '\n' '|')"
    echo failed > "$CTL/state"
    # The watcher sees the state and returns; nothing else to undo here.
    exit 4
fi
# The switch's own record of the two, where the guest cannot write: what the
# watcher and the return go by.
echo "$XP" > "$CTL/xnuhost.pid"
echo "$XNS" > "$CTL/mntns"
echo running > "$CTL/state"
echo "xnuhost: pid $XP in mount namespace $XNS, log $SESSION/xnuhost.log"

# The guest's screen: the runtime's display helper, when it carries one. It
# runs here, on One UI's side (it needs surfaceflinger's binder and the
# framework's classes, which xnuhost's namespace is not for), as root, from
# the runtime the preflight hashed. It waits for xnuhost's display.sock, shows
# the frames on a top layer and leaves when the socket closes. It is in the
# session's cgroup, so the return ends it with the rest, and by its pid
# (control/, where the guest cannot write; its log is there too). Nothing
# waits for it: without it the session runs with a dark screen.
DH="$STAGE/runtime/bin/oneios-display"
if [ -f "$DH" ] && [ ! -L "$DH" ] && [ -x "$DH" ] && root_only "$DH"; then
    "$BB" setsid "$DH" --session "$SESSION" --takeover --wait 60 </dev/null >>"$CTL/display.log" 2>&1 &
    DP=$!
    echo "$DP" > "$CTL/display.pid"
    echo 0 2>/dev/null > "/proc/$DP/oom_score_adj"
    echo "$DP" 2>/dev/null > /sys/fs/cgroup/oneios_session/cgroup.procs
    echo "Display helper: pid $DP, log $CTL/display.log"
else
    echo "Display helper: the runtime has none (bin/oneios-display); the guest's screen is not shown"
fi

echo "=== [5/5] $(date +%T) Session running ==="
echo "Auto-return to One UI: when xnuhost ends, on $SESSION/return.request, or without $SESSION/ready after ${ONEIOS_RETURN_MAX:-600}s"
echo "=== ONEIOS SESSION LAUNCHED ==="

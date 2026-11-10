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
#   oneios_switch.sh --keys D   (internal) Volume Up + Volume Down on device D
#   oneios_switch.sh --feed     (internal) Samsung's software watchdog feeder
#   oneios_switch.sh --stop-loop (internal) keeps One UI's zygote stopped
#
# What a session never touches: One UI's /data beyond $STAGE (xnuhost's mount
# namespace has the stage bound over /data), vold, keystore2, gatekeeper,
# weaver, the lock-screen files, SELinux's mode, persist.* properties.
# What it changes, all undone by oneios_return.sh or a reboot: One UI's zygote
# (and zygote_secondary) stopped, the kernel wakelock oneios_session, Samsung's
# software watchdog closed and fed.

# Tests (OneiosScriptTest) set ONEIOS_TEST_ROOT to a folder that stands for /:
# then only the stage checks run, never as root, and nothing is started.
T="${ONEIOS_TEST_ROOT:-}"
if [ -n "$T" ]; then
    [ "$(id -u)" != 0 ] || { echo "PREFLIGHT REFUSED: ONEIOS_TEST_ROOT is for tests, never as root"; exit 3; }
fi
STAGE="$T/data/local/tmp/oneios"
ANDROID_STAGE="$T/data/local/tmp/oneos"
SESSION="$STAGE/session"
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
            [ "${ONEIOS_VERIFY_IMAGE:-0}" = 1 ] || [ "$(stat -c %s "$f" 2>/dev/null)" -lt 67108864 ] || hash=0
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
        for d in runtime image; do
            "$BB" mount --bind "/data/$d" "/data/$d" && "$BB" mount -o remount,bind,ro "/data/$d" ||
                die_inner "could not make /data/$d read-only"
        done
        # The guard this session rests on: One UI's data is not reachable here.
        [ ! -e /data/system ] && [ ! -e /data/misc ] && [ ! -e /data/user ] && [ -f /data/runtime.conf ] ||
            die_inner "One UI's /data is still visible in the session's namespace"
        cd /data || die_inner "cd /data"
        mkdir -p /data/data /data/session/tmp && chmod 0700 /data/data /data/session/tmp || die_inner "could not make /data/data"
        echo $$ > /data/session/xnuhost.pid || die_inner "could not write the pid"
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
        # One UI ($SESSION/stop-loop.off, then the pid).
        [ -z "$T" ] || exit 3
        while [ ! -e "$SESSION/stop-loop.off" ]; do
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
        L="$SESSION/watchdog_feeder.log"
        was=""
        while [ ! -e "$SESSION/feeder.off" ]; do
            now=""
            for wd in /dev/watchdog /dev/softdog $(cat "$SESSION/softdog_nodes" 2>/dev/null); do
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
        # Volume Up + Volume Down held 3 s on one key device. getevent never
        # grabs, so the guest still gets the keys. It only writes the request
        # the watcher acts on. A later session (another token) ends this reader.
        [ -z "$T" ] || exit 3
        kd=$2 tok=$3
        KS="$SESSION/keys"
        getevent -lq "$kd" 2>/dev/null | while read -r typ code val rest; do
            [ "$(cat "$KS/session" 2>/dev/null)" = "$tok" ] || exit 0
            case "$code" in KEY_VOLUMEUP) k=up ;; KEY_VOLUMEDOWN) k=down ;; *) continue ;; esac
            echo "$val" > "$KS/$k"
            if [ "$(cat "$KS/up" 2>/dev/null)" = DOWN ] && [ "$(cat "$KS/down" 2>/dev/null)" = DOWN ]; then
                both="$(date +%s).$$.$RANDOM"; echo "$both" > "$KS/both"
                ( sleep 3
                  [ "$(cat "$KS/both" 2>/dev/null)" = "$both" ] && [ "$(cat "$KS/up")" = DOWN ] && [ "$(cat "$KS/down")" = DOWN ] &&
                      echo "keys: Volume Up + Volume Down held 3 s at $(date '+%F %T')" > "$SESSION/return.request" ) &
            else
                : > "$KS/both"
            fi
        done
        exit 0
        ;;
    --watch)
        # The way back, armed before One UI's zygote stops. It returns to One
        # UI when: the switch did not get as far as starting xnuhost (60 s),
        # xnuhost ended, a return was asked ($SESSION/return.request: the
        # volume keys, the guest, adb), or the guest never said it is up
        # ($SESSION/ready) within ONEIOS_RETURN_MAX seconds (600; 0 = no limit).
        [ -z "$T" ] || exit 3
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
        echo -1000 > /proc/$$/oom_score_adj 2>/dev/null
        MAX="${ONEIOS_RETURN_MAX:-600}"
        case "$MAX" in ''|*[!0-9]*) MAX=600 ;; esac
        go() {
            echo "$(date '+%F %T') watcher: $*; returning to One UI"
            exec /system/bin/sh "$STAGE/oneios_return.sh" watcher
        }
        t=0
        while [ "$(cat "$SESSION/state" 2>/dev/null)" = starting ]; do
            [ -e "$SESSION/return.request" ] && go "return asked before xnuhost started ($(head -c 200 "$SESSION/return.request" 2>/dev/null))"
            [ $t -lt 60 ] || go "the switch did not start xnuhost within 60 s"
            sleep 1; t=$((t + 1))
        done
        [ "$(cat "$SESSION/state" 2>/dev/null)" = running ] || go "the switch ended in state '$(cat "$SESSION/state" 2>/dev/null)'"
        pid=$(cat "$SESSION/xnuhost.pid" 2>/dev/null)
        ns=$(cat "$SESSION/mntns" 2>/dev/null)
        t=0
        while :; do
            [ -e "$SESSION/return.request" ] && go "return asked ($(head -c 200 "$SESSION/return.request" 2>/dev/null))"
            [ -n "$pid" ] && [ "$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)" = "$ns" ] ||
                go "xnuhost $pid ended (last log lines: $(tail -n 3 "$SESSION/xnuhost.log" 2>/dev/null | tr '\n' '|' | cut -c1-300))"
            if [ "$MAX" -gt 0 ] && [ ! -e "$SESSION/ready" ] && [ $t -ge "$MAX" ]; then
                go "the guest did not report ready within ${MAX}s"
            fi
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
if [ "$(cat "$SESSION/boot" 2>/dev/null)" = "$(boot_id)" ]; then
    case "$(cat "$SESSION/state" 2>/dev/null)" in
        starting|running|returning) refuse "an iOS session of this boot is still open ($(cat "$SESSION/state")): restart the phone first" ;;
    esac
fi
op=$(cat "$SESSION/xnuhost.pid" 2>/dev/null)
on=$(cat "$SESSION/mntns" 2>/dev/null)
[ -z "$op" ] || [ -z "$on" ] || [ "$(readlink "/proc/$op/ns/mnt" 2>/dev/null)" != "$on" ] ||
    refuse "xnuhost of an earlier session is still running (pid $op): restart the phone first"

# The ways back: the volume keys, and enough battery to get there.
command -v getevent >/dev/null 2>&1 || refuse "no getevent: Volume Up + Volume Down could not return to One UI"
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
rm -rf "$SESSION"
mkdir -p "$SESSION/base" "$SESSION/keys" "$SESSION/tmp" "$STAGE/data" && chown -R 0:0 "$SESSION" && chmod -R go-rwx "$SESSION" &&
    chmod 0700 "$STAGE/data" || refuse "could not make $SESSION"
: > "$SESSION/xnuhost.log"
boot_id > "$SESSION/boot"
echo starting > "$SESSION/state"
# What the in-place return compares against (oneios_return.sh), read while
# One UI is whole. Nothing here is changed by the session; the return only
# proves that.
B="$SESSION/base"
boot_id > "$B/boot_id"
getenforce > "$B/selinux" 2>&1
getprop > "$B/props"
for n in vold keystore2 surfaceflinger servicemanager; do echo "$n $(pidof $n 2>/dev/null | tr ' ' ',')"; done > "$B/pids"
case "$(settings get global wifi_on 2>/dev/null)" in 1|2) echo 1 ;; *) echo 0 ;; esac > "$B/wifi_on"
awk '{ print $5 }' /proc/1/mountinfo | sort > "$B/mounts"
echo "Baseline: boot $(cat "$B/boot_id"), SELinux $(cat "$B/selinux"), $(tr '\n' ' ' < "$B/pids")wifi $(cat "$B/wifi_on")"

echo "=== [2/5] $(date +%T) Arming the way back ==="
# Before the stop: the watcher returns to One UI by itself if this script
# does not get as far as a running xnuhost.
"$BB" setsid /system/bin/sh "$SELF" --watch </dev/null >>"$STAGE/return.log" 2>&1 &
echo $! > "$SESSION/watcher.pid"
KTOK="$$.$(date +%s)"
echo "$KTOK" > "$SESSION/keys/session"
for kd in $KDEVS; do
    ( echo 0 > /sys/fs/cgroup/cgroup.procs 2>/dev/null
      echo -1000 > /proc/self/oom_score_adj 2>/dev/null
      exec /system/bin/sh "$SELF" --keys "$kd" "$KTOK" ) </dev/null >/dev/null 2>&1 &
    echo $! >> "$SESSION/keys/pids"
done
echo "Return to One UI: hold Volume Up + Volume Down for 3 s (key devices: $(echo $KDEVS)); watcher $(cat "$SESSION/watcher.pid")"
# With One UI's power manager gone nothing would keep the phone awake.
echo oneios_session > /sys/power/wake_lock 2>/dev/null

echo "=== [3/5] $(date +%T) Stopping the One UI framework ==="
# The watchdog device(s) One UI's system_server keeps open, before it stops
# (oneos_switch.sh [4b/6]: recorded for the feeder).
for p in $(pidof system_server); do
    for fd in /proc/$p/fd/*; do
        t=$(readlink "$fd" 2>/dev/null)
        case "$t" in /dev/watchdog*|/dev/softdog*) echo "$t" ;; esac
    done
done 2>/dev/null | sort -u > "$SESSION/softdog_nodes"
# From here One UI's framework is down: the return starts it again. Without
# this mark the return only tidies up (a switch that ended before the stop).
echo "$(date +%s)" > "$SESSION/stopped"
setprop ctl.stop zygote
[ -n "$(getprop init.svc.zygote_secondary)" ] && setprop ctl.stop zygote_secondary
n=0
while [ $n -lt 50 ] && pidof system_server >/dev/null 2>&1; do sleep 0.2; n=$((n + 1)); done
kill -9 $(pidof system_server) 2>/dev/null
kill -9 $(pidof zygote64) $(pidof zygote) 2>/dev/null
"$BB" setsid /system/bin/sh "$SELF" --stop-loop </dev/null >/dev/null 2>&1 &
echo $! > "$SESSION/stop-loop.pid"
# Samsung's software watchdog: its magic close now, then the feeder.
for wd in /dev/watchdog /dev/softdog $(cat "$SESSION/softdog_nodes"); do
    [ -c "$wd" ] || continue
    if e=$(printf V 2>&1 > "$wd"); then echo "Softdog: $wd closed with V"; else echo "Softdog: $wd not written ($e)"; fi
done
"$BB" setsid /system/bin/sh "$SELF" --feed </dev/null >/dev/null 2>&1 &
echo $! > "$SESSION/feeder.pid"
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
    echo failed > "$SESSION/state"
    # The watcher sees the state and returns; nothing else to undo here.
    exit 4
fi
echo "$XNS" > "$SESSION/mntns"
echo running > "$SESSION/state"
echo "xnuhost: pid $XP in mount namespace $XNS, log $SESSION/xnuhost.log"

echo "=== [5/5] $(date +%T) Session running ==="
echo "Auto-return to One UI: when xnuhost ends, on $SESSION/return.request, or without $SESSION/ready after ${ONEIOS_RETURN_MAX:-600}s"
echo "=== ONEIOS SESSION LAUNCHED ==="

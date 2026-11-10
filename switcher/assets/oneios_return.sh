#!/system/bin/sh
# Back to One UI from a OneiOS session (oneios_switch.sh). docs/oneios.md.
#
#   oneios_return.sh [who]      in place when every check holds, else a reboot
#   oneios_return.sh reboot     straight to the reboot
#   oneios_return.sh --guard T  (internal) this return's own dead-man timer
#
# In place (the structure of return_to_oneui.sh, docs/inplace-return.md,
# shorter: an iOS session mounts nothing in init's namespace, changes no
# property and never talks to One UI's services):
#   1  stop the session: SIGTERM to xnuhost, 20 s, then SIGKILL to everything
#      in its cgroup and its mount namespace; the key readers and the watcher end.
#   A  nothing of the session is left: no process in its namespace or cgroup,
#      the stage mounted in no process's mount table, the same boot, vold,
#      keystore2 and servicemanager with the pids of the switch, SELinux as it
#      was.
#   B  the stop loop is gone; One UI's boot counters are back; the display is
#      One UI's again (the composer and surfaceflinger restarted, the boot
#      animation); audioserver and the rest of zygote's restart list; the
#      services One UI's framework waits for are registered; zygote starts.
#   C  system_server keeps its pid until user 0 is unlocked and 20 s more.
# Any failed check ends in failsafe(): a reboot, which is always a correct way
# back (nothing of the session survives one, and nothing of One UI's was
# written). A return that does not finish is rebooted by its guard.

# Tests (OneiosScriptTest) set ONEIOS_TEST_ROOT to a folder that stands for /:
# its proc, sys, stage and root tools, its bin/ first on PATH, its bin/kill
# and bin/sleep in place of the shell's, so a test never signals a real
# process, and its bin/now as the clock (a test's seconds are shorter). Never
# as root; on a phone the variable is dropped instead, because this script
# must not refuse to return.
T="${ONEIOS_TEST_ROOT:-}"
if [ -n "$T" ] && [ "$(id -u 2>/dev/null)" = 0 ]; then
    if [ -e /system/build.prop ]; then T=""; else echo "oneios_return.sh: ONEIOS_TEST_ROOT is for tests, never as root"; exit 3; fi
fi
if [ -n "$T" ]; then
    PATH="$T/bin:$PATH"; export PATH
    kill() { "$T/bin/kill" "$@"; }
    sleep() { "$T/bin/sleep" "$@"; }
    now() { "$T/bin/now"; }
else
    now() { date +%s; }
fi
SH=/system/bin/sh
[ -z "$T" ] || SH="${ONEIOS_TEST_SH:-/bin/sh}"
P="$T/proc"
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$T$c" ] && { BB=$T$c; break; }
done
RP=""
for c in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /debug_ramdisk/resetprop /sbin/resetprop; do
    [ -x "$T$c" ] && { RP=$T$c; break; }
done
S="$T/data/local/tmp/oneios"
# The stage as mount tables show it: its path, and its path on /data's own
# filesystem (the source of a bind from it, mountinfo's fourth field).
SM=/data/local/tmp/oneios
SRC=/local/tmp/oneios
# The way back's own folder (oneios_switch.sh): the state, the baseline, the
# pids. Read-only in xnuhost's namespace.
CTL=$S/control
BASE=$CTL/base
LOG=$S/return.log
# xnuhost's cgroup (oneios_switch.sh --inner). Only ever this one path.
CG="$T/sys/fs/cgroup/oneios_session"
WHO="${1:-manual}"
# Every wait below has its own limit and its own failsafe; all of them
# together, each used up to its last second, come to about 7 minutes (20 s for
# xnuhost, the display and audio waits, 60 s for system_server, 180 s for the
# unlock, 20 s after it). The guard is for what has no limit: a command that
# never comes back. Past this it reboots.
GUARD_MAX=600
[ -z "$T" ] || GUARD_MAX="${ONEIOS_TEST_GUARD_MAX:-$GUARD_MAX}"

[ -n "$T" ] || [ "$(id -u 2>/dev/null)" = 0 ] || { echo "oneios_return.sh: not root"; exit 2; }
# The return must finish even if whatever started it goes away.
trap '' HUP PIPE
# (2>/dev/null first: a path that is not there is not worth a line.)
echo $$ 2>/dev/null > "$T/sys/fs/cgroup/cgroup.procs"
echo -1000 2>/dev/null > "$P/$$/oom_score_adj"

# Every line to the caller and to the log; once only where the caller's
# output is the log itself (the watcher, the app's root script, the key readers).
TEE=1
[ "/proc/$$/fd/1" -ef "$LOG" ] && TEE=0
say() {
    m="$(date +%T) $*"
    echo "$m"
    [ $TEE = 0 ] || echo "$m" >> "$LOG"
}
step() {
    echo "$*" 2>/dev/null > "$CTL/return.step"
    say "=== $* ==="
}
do_reboot() { # <reason word>
    sync
    setprop sys.powerctl "reboot,$1"
    sleep 20
    # init did not reboot: the kernel's reboot, then sysrq as the last resort.
    sync
    [ -n "$BB" ] && "$BB" reboot -f
    sleep 5
    echo 1 > "$P/sys/kernel/sysrq" 2>/dev/null
    echo s > "$P/sysrq-trigger" 2>/dev/null
    sleep 2
    echo b > "$P/sysrq-trigger" 2>/dev/null
    exit 1
}
failsafe() {
    say "FAILSAFE: $* - rebooting into One UI instead"
    echo "failsafe $(date +%s) $*" > "$S/return.outcome"
    do_reboot oneios-inplace-failsafe
}
base_prop() { sed -n "s/^\[$1\]: \[\(.*\)\]\$/\1/p" "$BASE/props" 2>/dev/null | head -n 1; }
base_has() { grep -q "^\[$1\]: " "$BASE/props" 2>/dev/null; }
# A non-persist prop back to its value at the switch, in memory only
# (resetprop -n: no property triggers), or deleted if One UI had none.
put_back() {
    if base_has "$1"; then "$RP" -n "$1" "$(base_prop "$1")" 2>/dev/null
    else "$RP" --delete "$1" 2>/dev/null; fi
}
# Is this pid still one of our own shells? A pid file outlives its process and
# ids are reused: nothing is signalled by a pid alone.
is_ours() { # <pid> <script and mode words>
    case "$(tr '\0' ' ' 2>/dev/null < "$P/$1/cmdline")" in *"$2"*) return 0 ;; esac
    return 1
}
# Ends one of oneios_switch.sh's helpers by its pid file.
end_helper() { # <pid file> <mode word>
    for p in $(cat "$1" 2>/dev/null); do
        is_ours "$p" "oneios_switch.sh $2" && kill -9 "$p" 2>/dev/null
    done
}
# The key readers lead process groups of their own (setsid): the reader, its
# getevent and its timers end together. A reader that is not a group leader
# has no such group, and is ended alone.
end_readers() {
    for p in $(cat "$CTL/keys/pids" 2>/dev/null); do
        is_ours "$p" "oneios_switch.sh --keys" || continue
        kill -9 -- "-$p" 2>/dev/null
        kill -9 "$p" 2>/dev/null
    done
}
wait_found() { # <servicemanager name> <seconds>
    w=0
    while [ $w -lt $(($2 * 2)) ]; do
        timeout 3 service check "$1" 2>/dev/null | grep -q ': found' && return 0
        sleep 0.5; w=$((w + 1))
    done
    return 1
}

# --- THE GUARD -------------------------------------------------------------
# Armed by every return before its first step, in a session of its own, in
# the root cgroup and out of the OOM killer's reach: it does not depend on the
# return's shell. The return takes its mark away when it is done. A mark that
# is still this return's GUARD_MAX seconds later means a step never came back
# (a command that hangs on a dead service, a script that was killed): the
# phone reboots into One UI.
if [ "$WHO" = --guard ]; then
    tok=$2
    [ -n "$tok" ] || exit 3
    t=0
    while [ $t -lt $GUARD_MAX ]; do
        [ "$(cat "$CTL/return.guard" 2>/dev/null)" = "$tok" ] || exit 0
        sleep 5; t=$((t + 5))
    done
    [ "$(cat "$CTL/return.guard" 2>/dev/null)" = "$tok" ] || exit 0
    say "GUARD: the return did not finish within ${GUARD_MAX}s (last step: $(cat "$CTL/return.step" 2>/dev/null)) - rebooting into One UI"
    echo "failsafe $(date +%s) the return did not finish within ${GUARD_MAX}s (last step: $(cat "$CTL/return.step" 2>/dev/null))" > "$S/return.outcome"
    do_reboot oneios-return-guard
fi

: >> "$LOG"
say "=== Return to One UI ($WHO), session state '$(cat "$CTL/state" 2>/dev/null)', boot $(cat "$P/sys/kernel/random/boot_id" 2>/dev/null) ==="
# The reboot return needs no session state and no lock.
if [ "$WHO" = reboot ]; then
    say "Reboot return asked"
    echo "reboot $(date +%s) asked" > "$S/return.outcome"
    do_reboot oneios-return
fi

# A session that already returned, or none: nothing to do, and never a reboot.
# One exception. The watcher and the key readers exist only in a session, so
# a state they cannot read is a session whose control folder is gone; if One
# UI's framework is down as well, nothing here can be checked: the reboot.
case "$(cat "$CTL/state" 2>/dev/null)" in
    returned) say "no open session (state 'returned'): nothing to return from"; exit 0 ;;
    '')
        case "$WHO" in
            watcher|keys-direct)
                [ "$(getprop init.svc.zygote)" = running ] || pidof system_server >/dev/null 2>&1 ||
                    failsafe "the session's state cannot be read ($CTL/state) and One UI's framework is not running" ;;
        esac
        say "no open session (state ''): nothing to return from"; exit 0 ;;
esac
# One return at a time: the watcher, the key readers and a manual return can
# meet. The lock names its holder; a holder that is gone (a return that was
# killed) does not keep the next one out.
if ! mkdir "$CTL/returning.lock" 2>/dev/null; then
    [ -d "$CTL" ] || { say "no session folder: nothing to return from"; exit 0; }
    holder=$(cat "$CTL/returning.lock/pid" 2>/dev/null)
    if [ -n "$holder" ] && is_ours "$holder" "oneios_return.sh"; then
        say "another return is already running (pid $holder); leaving it to it"
        exit 0
    fi
    # The holder writes its pid right after it makes the lock: an empty lock is
    # a return that is just starting, unless it is still empty a moment later.
    [ -n "$holder" ] || { sleep 2; holder=$(cat "$CTL/returning.lock/pid" 2>/dev/null); }
    if [ -n "$holder" ] && is_ours "$holder" "oneios_return.sh"; then
        say "another return is already running (pid $holder); leaving it to it"
        exit 0
    fi
    say "the return that held the lock is gone (pid '${holder}'): taking over"
fi
echo $$ > "$CTL/returning.lock/pid"
echo returning > "$CTL/state"
echo oneios_return 2>/dev/null > "$T/sys/power/wake_lock"
GTOK="$$.$(date +%s)"
echo "$GTOK" > "$CTL/return.guard"
if [ -n "$BB" ]; then "$BB" setsid $SH "$S/oneios_return.sh" --guard "$GTOK" </dev/null >/dev/null 2>&1 &
else $SH "$S/oneios_return.sh" --guard "$GTOK" </dev/null >/dev/null 2>&1 & fi
finished() { # the guard's mark and the lock go; the wakelocks are released
    rm -f "$CTL/return.guard" "$CTL/return.step"
    rm -rf "$CTL/returning.lock"
    echo oneios_session 2>/dev/null > "$T/sys/power/wake_unlock"
    echo oneios_return 2>/dev/null > "$T/sys/power/wake_unlock"
}

step "[1/5] Stopping the session"
# The key readers and the watcher (unless this return is the watcher's own
# child, or the watcher itself).
: > "$CTL/keys/session" 2>/dev/null
end_readers
wp=$(cat "$CTL/watcher.pid" 2>/dev/null)
[ "$wp" = "$$" ] || [ "$wp" = "$PPID" ] || end_helper "$CTL/watcher.pid" --watch
XP=$(cat "$CTL/xnuhost.pid" 2>/dev/null)
XNS=$(cat "$CTL/mntns" 2>/dev/null)
INIT_NS=$(readlink "$P/1/ns/mnt" 2>/dev/null)
[ -n "$INIT_NS" ] || failsafe "init's mount namespace is not readable"
# Never kill by a namespace that is init's own (a session that did not get as
# far as a namespace has none recorded).
[ "$XNS" != "$INIT_NS" ] || XNS=""
[ -d "$CG" ] || CG=""
# The pids in the session's mount namespace: one ls for every process (a
# readlink each took over a second a round on a phone's few hundred).
in_session() {
    [ -n "$XNS" ] || return 0
    ls -l "$P"/[0-9]*/ns/mnt 2>/dev/null |
        awk -v ns="$XNS" -v pre="$P/" '$NF == ns && $(NF - 1) == "->" { p = substr($(NF - 2), length(pre) + 1); sub(/\/.*/, "", p); print p }'
}
# The pids in xnuhost's cgroup: a task that made a mount namespace of its own
# is still here. (Only pids that exist: the kernel lists no others.)
in_cgroup() {
    [ -n "$CG" ] || return 0
    for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do [ -d "$P/$p" ] && echo "$p"; done
}
# The pids outside init's namespace whose mount table shows the stage (bound
# from it, or mounted under it). The session's binds are private to a
# namespace made for it, so only something that came from the session has
# them: a task in a namespace copied from xnuhost's.
stage_holders() {
    grep -l -F "$SRC" "$P"/[0-9]*/mountinfo 2>/dev/null | while read -r f; do
        awk -v s="$SM" -v r="$SRC" '$5 == s || index($5, s "/") == 1 || $4 == r || index($4, r "/") == 1 { f = 1; exit } END { exit !f }' "$f" 2>/dev/null || continue
        p=${f%/mountinfo}
        [ "$(readlink "$p/ns/mnt" 2>/dev/null)" = "$INIT_NS" ] || echo "${p##*/}"
    done
}
session_left() { { in_cgroup; in_session; stage_holders; } | sort -u | grep -v -x -e 1 -e "$$" | tr '\n' ' '; }
if [ -n "$XNS" ] && [ -n "$XP" ] && [ "$(readlink "$P/$XP/ns/mnt" 2>/dev/null)" = "$XNS" ]; then
    # What xnuhost holds of the display and the GPU, for the log: the kernel
    # takes all of it back when the process ends, however it ends.
    held=$(ls -l "$P/$XP/fd" 2>/dev/null | awk '$NF ~ /^\/dev\/(dri\/|kgsl|dma_heap\/|udmabuf|input\/)/ { n[$NF]++ } END { for (d in n) printf "%s x%d ", d, n[d] }')
    say "xnuhost $XP holds: ${held:-no display, GPU or input node}"
    say "SIGTERM to xnuhost $XP (20 s to end its tasks and flush the guest's data)"
    kill -TERM "$XP" 2>/dev/null
    t0=$(now)
    while [ $(($(now) - t0)) -lt 20 ] && [ "$(readlink "$P/$XP/ns/mnt" 2>/dev/null)" = "$XNS" ]; do sleep 0.2; done
fi
# Everything that is left, clean end or not: the cgroup at once (the kernel
# ends every member, forks included), then by pid, five rounds.
left=$(session_left)
if [ -n "$left" ]; then
    say "SIGKILL to what is left of the session: $left"
    pass=1
    while [ $pass -le 5 ] && [ -n "$left" ]; do
        [ -n "$CG" ] && [ -e "$CG/cgroup.kill" ] && echo 1 > "$CG/cgroup.kill" 2>/dev/null
        for p in $left; do kill -9 "$p" 2>/dev/null; done
        sleep 1
        left=$(session_left)
        pass=$((pass + 1))
    done
fi

# The switch ended before it stopped One UI's zygote (it marks the stop):
# One UI never went away, so there is nothing to check or start. Its helpers
# end, and that is the whole return.
if [ ! -e "$CTL/stopped" ]; then
    : > "$CTL/stop-loop.off"
    : > "$CTL/feeder.off"
    end_helper "$CTL/stop-loop.pid" --stop-loop
    end_helper "$CTL/feeder.pid" --feed
    [ -z "$CG" ] || rmdir "$CG" 2>/dev/null
    echo "inplace $(date +%s) One UI was never stopped" > "$S/return.outcome"
    finished
    say "The switch ended before One UI's framework was stopped: nothing to restore."
    echo returned > "$CTL/state"
    exit 0
fi

step "[2/5] Gate A: nothing of the session is left"
left=$(session_left)
[ -z "$left" ] || failsafe "processes still in the session's namespace or cgroup: $left"
[ -z "$CG" ] || rmdir "$CG" 2>/dev/null || say "the session's cgroup $CG is empty but could not be removed (logged only)"
[ -f "$BASE/boot_id" ] || failsafe "no baseline of the switch ($BASE)"
[ "$(cat "$BASE/boot_id")" = "$(cat "$P/sys/kernel/random/boot_id" 2>/dev/null)" ] || failsafe "the baseline is another boot's"
# The stage, in every process's mount table and not only init's (OneOS run 45:
# another namespace kept its own copy of a stage mount). By mount point or by
# source. Nothing is unmounted here: a namespace that still has the stage as
# its /data would see One UI's /data in its place.
m=$(grep -H -F "$SRC" "$P"/[0-9]*/mountinfo 2>/dev/null |
    awk -v s="$SM" -v r="$SRC" '$5 == s || index($5, s "/") == 1 || $4 == r || index($4, r "/") == 1 { print $1 " " $5 }' | head -n 3 | tr '\n' ' ')
[ -z "$m" ] || failsafe "the stage is still mounted (mount table, mount point): $m"
added=$(awk '{ print $5 }' "$P/1/mountinfo" | sort | comm -13 "$BASE/mounts" - 2>/dev/null | grep -E '^/(data|system|vendor|product|system_ext|odm|apex)(/|$)' | head -n 3 | tr '\n' ' ')
[ -z "$added" ] || failsafe "mounts added on One UI's partitions during the session: $added"
# The daemons One UI cannot get back without a boot. surfaceflinger is not one
# of them: it is restarted below with the composer, so its pid is only logged.
SF_BASE=""
while read -r name pids; do
    now=$(pidof "$name" 2>/dev/null | tr ' ' ',')
    if [ "$name" = surfaceflinger ]; then
        SF_BASE=$pids
        [ "$now" = "$pids" ] || say "surfaceflinger is ${now:-not running} now, was $pids at the switch (it is restarted below)"
        continue
    fi
    [ "$now" = "$pids" ] || failsafe "One UI's $name is ${now:-not running} now, was $pids at the switch"
done < "$BASE/pids"
for svc in vold keystore2 servicemanager hwservicemanager logd lmkd installd; do
    [ "$(base_prop init.svc.$svc)" = running ] || continue
    [ "$(getprop init.svc.$svc)" = running ] || failsafe "$svc is $(getprop init.svc.$svc), was running at the switch"
done
[ "$(getenforce 2>/dev/null)" = "$(cat "$BASE/selinux")" ] || failsafe "SELinux is $(getenforce 2>/dev/null), was $(cat "$BASE/selinux")"
# The session scripts set no persist property. What differs from the switch
# is One UI's own daemons' doing, or xnuhost's against its contract: by name
# only (values can be personal), and nothing is written back.
changed=$(getprop | awk -F'\\]: \\[' 'NR == FNR { b[$1] = $2; next } $1 ~ /^\[persist\./ && (!($1 in b) || b[$1] != $2) { sub(/^\[/, "", $1); print $1 }' "$BASE/props" - 2>/dev/null | head -n 20 | tr '\n' ' ')
say "Gate A: no session process, the stage mounted nowhere, vold, keystore2 and servicemanager as at the switch, SELinux $(getenforce 2>/dev/null); persist properties that differ from the switch: ${changed:-none}"

step "[3/5] Gate B: One UI's display and services"
# The stop loop must be gone before anything starts (its last ctl.stop can
# land after a start; it also stops the boot animation).
: > "$CTL/stop-loop.off"
n=0
while [ $n -lt 15 ]; do
    alive=0
    for p in $(cat "$CTL/stop-loop.pid" 2>/dev/null); do
        is_ours "$p" "oneios_switch.sh --stop-loop" && alive=1
    done
    [ $alive = 1 ] || break
    [ $n -lt 10 ] || end_helper "$CTL/stop-loop.pid" --stop-loop
    sleep 0.2; n=$((n + 1))
done
[ $alive = 0 ] || failsafe "the session's stop loop is still running"
[ "$(getprop init.svc.zygote)" != running ] && ! pidof system_server >/dev/null 2>&1 ||
    failsafe "One UI's zygote or system_server started before the return was ready"
# One UI's boot-loop check counts every system_server start in a 10 minute
# window (return_to_oneui.sh, 0.4.47: a switch and return read as a boot loop
# and rolled back a Play system update). The counters go back to the
# switch's, in memory only; nothing persist.* is written.
if [ -n "$RP" ]; then
    for k in crashrecovery.rescue_boot_start crashrecovery.boot_mitigation_count crashrecovery.boot_mitigation_start \
             crashrecovery.attempting_reboot crashrecovery.attempting_factory_reset; do
        put_back "$k"
    done
    "$RP" -n sys.rescue_boot_count 0 2>/dev/null
    "$RP" -n crashrecovery.rescue_boot_count 0 2>/dev/null
else
    say "!!! no resetprop: One UI's boot counters stay as they are"
fi

# Display (return_to_oneui.sh's step, for a session in which One UI's own
# surfaceflinger kept running). xnuhost drew the guest with the Adreno and,
# with --display drm, on the panel itself; the kernel closed its KGSL contexts
# and DRM handles when it ended, a SIGKILL included. What may be left is on
# One UI's side: a composer that last saw another DRM master or a mode it did
# not set, a surfaceflinger whose GPU context a guest fault reset or that sits
# in a call that will not return, layers of a display helper. So nothing of
# the old display state is trusted: the composer is restarted, surfaceflinger
# with it, and the boot animation covers One UI's start. Each must come back,
# or the phone reboots.
COMPOSER_SVC=""
for c in vendor.qti.hardware.display.composer vendor.hwcomposer-3; do
    [ -n "$(getprop init.svc.$c)" ] && { COMPOSER_SVC=$c; break; }
done
[ -n "$COMPOSER_SVC" ] || COMPOSER_SVC=$(getprop | sed -n 's/^\[init\.svc\.\([^]]*\)\]: \[running\]$/\1/p' | grep -m1 -E 'hwcomposer|display\.composer|graphics\.composer')
[ -n "$COMPOSER_SVC" ] || failsafe "no display composer service found"
C_OLD=$(getprop "init.svc_debug_pid.$COMPOSER_SVC")
SF_OLD=$(pidof surfaceflinger 2>/dev/null)
setprop ctl.restart "$COMPOSER_SVC"
# The new composer, not the old one on its way out: init's pid for the
# service has changed (a second's wait where init publishes none).
[ -n "$C_OLD" ] || sleep 1
n=0
while [ $n -lt 20 ]; do
    if [ "$(getprop "init.svc.$COMPOSER_SVC")" = running ]; then
        [ -z "$C_OLD" ] || [ "$(getprop "init.svc_debug_pid.$COMPOSER_SVC")" != "$C_OLD" ] && break
    fi
    sleep 0.5; n=$((n + 1))
done
[ $n -lt 20 ] || failsafe "the display composer $COMPOSER_SVC did not restart (pid still '$C_OLD', $(getprop "init.svc.$COMPOSER_SVC"))"
# The vendor manifest says which composer interface this phone serves.
if grep -rqs 'android.hardware.graphics.composer3' "$T/vendor/etc/vintf/"; then
    wait_found android.hardware.graphics.composer3.IComposer/default 10 || failsafe "the display composer did not come back"
else
    n=0
    while [ $n -lt 20 ] && ! timeout 3 lshal list -i 2>/dev/null | grep -q 'android\.hardware\.graphics\.composer@[0-9.]*::IComposer/default'; do
        sleep 0.5; n=$((n + 1))
    done
    [ $n -lt 20 ] || failsafe "the display composer (HIDL) did not come back"
fi
# surfaceflinger was the old composer's client: it ends with it and init
# starts it again. One that is still the old process after 5 s is restarted by
# name; one that is not running is started.
n=0; sf=""
while [ $n -lt 10 ]; do
    sf=$(pidof surfaceflinger 2>/dev/null)
    [ -n "$sf" ] && [ "$sf" != "$SF_OLD" ] && break
    sleep 0.5; n=$((n + 1))
done
if [ -z "$sf" ]; then setprop ctl.start surfaceflinger
elif [ "$sf" = "$SF_OLD" ]; then setprop ctl.restart surfaceflinger; fi
n=0
while [ $n -lt 30 ]; do
    sf=$(pidof surfaceflinger 2>/dev/null)
    [ -n "$sf" ] && [ "$sf" != "$SF_OLD" ] && break
    sleep 0.5; n=$((n + 1))
done
[ -n "$sf" ] && [ "$sf" != "$SF_OLD" ] || failsafe "One UI's surfaceflinger did not restart (pid '${sf}', was '${SF_OLD}')"
wait_found SurfaceFlinger 10 || failsafe "One UI's surfaceflinger did not register"
setprop service.bootanim.exit 0
setprop ctl.start bootanim
say "display: composer $COMPOSER_SVC restarted (was $C_OLD), surfaceflinger $sf (was ${SF_OLD:-not running}; ${SF_BASE:-?} at the switch), boot animation started"

# Audio and the rest of zygote's onrestart list, which a start after a stop
# skips. They served One UI's old framework all session (and the guest's
# bridges, where one of them plays through audioserver): Android restarts them
# with every framework restart. AudioService waits for the policy service
# with no timeout.
setprop ctl.stop audioserver
setprop ctl.start audioserver
wait_found media.audio_policy 20 || failsafe "One UI's audioserver did not register"
setprop ctl.restart cameraserver
for svc in media mediaextractor mediametrics; do setprop ctl.start $svc; done
setprop ctl.restart wificond
# One UI's init.zygote64.rc also restarts these two (return_to_oneui.sh, run 44).
for svc in perfmond media.tuner; do
    [ "$(base_prop init.svc.$svc)" = running ] && setprop ctl.restart $svc
done
say "audioserver, cameraserver, media and wificond restarted"

# Everything One UI's framework waits for, with nothing of the session left.
left=$(session_left)
[ -z "$left" ] || failsafe "processes of the session appeared again: $left"
for name in vold SurfaceFlinger media.audio_policy media.audio_flinger installd; do
    wait_found "$name" 5 || failsafe "$name is not registered"
done
say "Gate B: display, audio and One UI's services up, SELinux $(getenforce 2>/dev/null)"

step "[4/5] Starting One UI in place"
# zygote's onrestart by hand: abort the FUSE connections the old framework left.
timeout 10 vdc volume abort_fuse >/dev/null 2>&1
# One UI's zygote_next ran through the session with the old framework's
# children: a fresh one, as a boot gives (return_to_oneui.sh).
if [ -n "$(pidof zygote_next 2>/dev/null)" ] && [ "$(base_prop init.svc.zygote_next)" = running ]; then
    setprop ctl.restart zygote_next
fi
# netd's restart is on zygote's list too (the new system_server needs a fresh
# DnsResolver); where its own onrestart starts zygote, that is the start.
setprop ctl.restart netd
n=0
while [ $n -lt 20 ] && [ "$(getprop init.svc.zygote)" != running ]; do sleep 0.5; n=$((n + 1)); done
[ "$(getprop init.svc.zygote)" = running ] || setprop ctl.start zygote
if [ "$(base_prop init.svc.zygote_secondary)" = running ] && [ "$(getprop init.svc.zygote_secondary)" != running ]; then
    setprop ctl.start zygote_secondary
    say "One UI's zygote_secondary started"
fi
n=0
while [ $n -lt 20 ] && [ "$(getprop init.svc.zygote)" != running ]; do sleep 0.5; n=$((n + 1)); done
[ "$(getprop init.svc.zygote)" = running ] || failsafe "One UI's zygote did not start ($(getprop init.svc.zygote))"
say "One UI's zygote started"

step "[5/5] Gate C: One UI's system_server"
# By the clock, not by counting rounds: one round's "am" alone takes a second.
t0=$(now); t=0; ss=""
while [ $t -lt 60 ]; do
    # Two pids: a child system_server forked and has not exec'd yet; ask again.
    ss=$(pidof system_server); case "$ss" in *" "*) ss="" ;; esac
    [ -n "$ss" ] && break
    sleep 1; t=$(($(now) - t0))
done
[ -n "$ss" ] || failsafe "One UI's system_server did not start in 60 s"
say "One UI's system_server $ss"
# system_server feeds Samsung's software watchdog again from here.
: > "$CTL/feeder.off"
t0=$(now); up=0
while :; do
    sleep 2; t=$(($(now) - t0))
    [ "$(cat "$P/$ss/comm" 2>/dev/null)" = system_server ] ||
        failsafe "One UI's system_server $ss died after ${t}s (now $(pidof system_server 2>/dev/null || echo none))"
    [ "$(getprop init.svc.zygote)" = running ] || failsafe "zygote is $(getprop init.svc.zygote)"
    if [ $up = 0 ]; then
        st=$(timeout 5 am get-started-user-state 0 2>&1)
        case "$st" in
            *RUNNING_UNLOCKED*) up=$t; say "user 0 unlocked after ${t}s" ;;
            *nknown*|*rror*) pidof com.sec.android.app.launcher >/dev/null 2>&1 && { up=$t; say "One UI Home running after ${t}s"; } ;;
        esac
    fi
    [ $up -gt 0 ] && [ $t -ge $((up + 20)) ] && break
    [ $up = 0 ] && [ $t -ge 180 ] && failsafe "user 0 not unlocked within 180 s"
done
end_helper "$CTL/feeder.pid" --feed
echo "inplace $(date +%s) $(cat "$P/sys/kernel/random/boot_id" 2>/dev/null)" > "$S/return.outcome"
finished
say "One UI restored in place ($(getenforce 2>/dev/null))."
# Last: whoever waits for this state finds everything above done.
echo returned > "$CTL/state"

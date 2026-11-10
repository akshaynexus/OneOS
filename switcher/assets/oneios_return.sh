#!/system/bin/sh
# Back to One UI from a OneiOS session (oneios_switch.sh). docs/oneios.md.
#
#   oneios_return.sh [who]      in place when every check holds, else a reboot
#   oneios_return.sh reboot     straight to the reboot
#
# In place (the structure of return_to_oneui.sh, docs/inplace-return.md, much
# shorter: an iOS session mounts nothing in init's namespace, changes no
# property and never talks to One UI's services):
#   1  stop the session: SIGTERM to xnuhost, 20 s, then SIGKILL to everything
#      in its mount namespace; the key readers and the watcher end.
#   A  nothing of the session is left: no process in its namespace, nothing
#      mounted under the stage, the same boot, vold, keystore2, surfaceflinger
#      and servicemanager with the pids of the switch, SELinux as it was.
#   B  the stop loop is gone; One UI's boot counters are back; zygote starts.
#   C  system_server keeps its pid until user 0 is unlocked and 20 s more.
# Any failed check ends in failsafe(): a reboot, which is always a correct way
# back (nothing of the session survives one).
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
    [ -x "$c" ] && { BB=$c; break; }
done
RP=""
for c in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /debug_ramdisk/resetprop /sbin/resetprop; do
    [ -x "$c" ] && { RP=$c; break; }
done
S=/data/local/tmp/oneios
SESSION=$S/session
BASE=$SESSION/base
LOG=$S/return.log
WHO="${1:-manual}"

[ "$(id -u 2>/dev/null)" = 0 ] || { echo "oneios_return.sh: not root"; exit 2; }
# The return must finish even if whatever started it goes away.
trap '' HUP PIPE
echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
echo -1000 > /proc/$$/oom_score_adj 2>/dev/null

say() {
    m="$(date +%T) $*"
    echo "$m"
    echo "$m" >> "$LOG"
}
do_reboot() { # <reason word>
    sync
    setprop sys.powerctl "reboot,$1"
    sleep 20
    # init did not reboot: the kernel's reboot, then sysrq as the last resort.
    sync
    [ -n "$BB" ] && "$BB" reboot -f
    sleep 5
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null
    sleep 2
    echo b > /proc/sysrq-trigger 2>/dev/null
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
# Ends one of oneios_switch.sh's helpers by its pid file, only while that pid
# is still such a shell (a pid file outlives its process; ids are reused).
end_helper() { # <pid file> <mode word>
    for p in $(cat "$1" 2>/dev/null); do
        case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in
            *"oneios_switch.sh $2"*) kill -9 "$p" 2>/dev/null ;;
        esac
    done
}

: >> "$LOG"
say "=== Return to One UI ($WHO), session state '$(cat "$SESSION/state" 2>/dev/null)', boot $(cat /proc/sys/kernel/random/boot_id 2>/dev/null) ==="
# The reboot return needs no session state and no lock.
if [ "$WHO" = reboot ]; then
    say "Reboot return asked"
    echo "reboot $(date +%s) asked" > "$S/return.outcome"
    do_reboot oneios-return
fi

# A session that already returned, or none: nothing to do, and never a reboot.
case "$(cat "$SESSION/state" 2>/dev/null)" in
    ''|returned) say "no open session (state '$(cat "$SESSION/state" 2>/dev/null)'): nothing to return from"; exit 0 ;;
esac
# One return at a time: the watcher and a manual return can meet.
if ! mkdir "$SESSION/returning.lock" 2>/dev/null; then
    [ -d "$SESSION" ] || { say "no session folder: nothing to return from"; exit 0; }
    say "another return is already running; leaving it to it"
    exit 0
fi
echo returning > "$SESSION/state"
echo oneios_return > /sys/power/wake_lock 2>/dev/null

echo "=== [1/4] $(date +%T) Stopping the session ==="
# The key readers and (unless it is this process: the watcher execs this
# script) the watcher.
: > "$SESSION/keys/session" 2>/dev/null
end_helper "$SESSION/keys/pids" --keys
[ "$(cat "$SESSION/watcher.pid" 2>/dev/null)" = "$$" ] || end_helper "$SESSION/watcher.pid" --watch
XP=$(cat "$SESSION/xnuhost.pid" 2>/dev/null)
XNS=$(cat "$SESSION/mntns" 2>/dev/null)
INIT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
[ -n "$INIT_NS" ] || failsafe "init's mount namespace is not readable"
# Never kill by a namespace that is init's own (a session that did not get as
# far as a namespace has none recorded).
[ "$XNS" != "$INIT_NS" ] || XNS=""
in_session() { # prints the pids in the session's mount namespace
    [ -n "$XNS" ] || return 0
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/ns/mnt" 2>/dev/null)" = "$XNS" ] && echo "${p#/proc/}"
    done
}
if [ -n "$XNS" ] && [ -n "$XP" ] && [ "$(readlink "/proc/$XP/ns/mnt" 2>/dev/null)" = "$XNS" ]; then
    say "SIGTERM to xnuhost $XP (20 s to end its tasks and flush the guest's data)"
    kill -TERM "$XP" 2>/dev/null
    n=0
    while [ $n -lt 100 ] && [ -n "$(in_session)" ]; do sleep 0.2; n=$((n + 1)); done
fi
left=$(in_session | tr '\n' ' ')
if [ -n "$left" ]; then
    say "SIGKILL to what is left in the session's namespace: $left"
    n=0
    while [ $n -lt 25 ] && [ -n "$(in_session)" ]; do
        for p in $(in_session); do kill -9 "$p" 2>/dev/null; done
        sleep 0.2; n=$((n + 1))
    done
fi

# The switch ended before it stopped One UI's zygote (it marks the stop):
# One UI never went away, so there is nothing to check or start. Its helpers
# end, and that is the whole return.
if [ ! -e "$SESSION/stopped" ]; then
    : > "$SESSION/stop-loop.off"
    : > "$SESSION/feeder.off"
    end_helper "$SESSION/stop-loop.pid" --stop-loop
    end_helper "$SESSION/feeder.pid" --feed
    echo returned > "$SESSION/state"
    echo "inplace $(date +%s) One UI was never stopped" > "$S/return.outcome"
    echo oneios_session > /sys/power/wake_unlock 2>/dev/null
    echo oneios_return > /sys/power/wake_unlock 2>/dev/null
    say "The switch ended before One UI's framework was stopped: nothing to restore."
    exit 0
fi

echo "=== [2/4] $(date +%T) Gate A: nothing of the session is left ==="
left=$(in_session | tr '\n' ' ')
[ -z "$left" ] || failsafe "processes still in the session's namespace: $left"
[ -f "$BASE/boot_id" ] || failsafe "no baseline of the switch ($BASE)"
[ "$(cat "$BASE/boot_id")" = "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" ] || failsafe "the baseline is another boot's"
m=$(awk -v s="$S" '$5 == s || index($5, s "/") == 1 { print $5 }' /proc/1/mountinfo | head -n 3 | tr '\n' ' ')
[ -z "$m" ] || failsafe "mounted under the stage in init's namespace: $m"
added=$(awk '{ print $5 }' /proc/1/mountinfo | sort | comm -13 "$BASE/mounts" - 2>/dev/null | grep -E '^/(data|system|vendor|product|system_ext|odm|apex)(/|$)' | head -n 3 | tr '\n' ' ')
[ -z "$added" ] || failsafe "mounts added on One UI's partitions during the session: $added"
while read -r name pids; do
    now=$(pidof "$name" 2>/dev/null | tr ' ' ',')
    [ "$now" = "$pids" ] || failsafe "One UI's $name is ${now:-not running} now, was $pids at the switch"
done < "$BASE/pids"
[ "$(getenforce 2>/dev/null)" = "$(cat "$BASE/selinux")" ] || failsafe "SELinux is $(getenforce 2>/dev/null), was $(cat "$BASE/selinux")"
say "Gate A: no session process, no stage mount, vold, keystore2, surfaceflinger and servicemanager as at the switch, SELinux $(getenforce 2>/dev/null)"

echo "=== [3/4] $(date +%T) Gate B: starting One UI in place ==="
# The stop loop must be gone before anything starts (its last ctl.stop can
# land after a start).
: > "$SESSION/stop-loop.off"
n=0
while [ $n -lt 15 ]; do
    alive=0
    for p in $(cat "$SESSION/stop-loop.pid" 2>/dev/null); do
        case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in *"oneios_switch.sh --stop-loop"*) alive=1 ;; esac
    done
    [ $alive = 1 ] || break
    [ $n -lt 10 ] || end_helper "$SESSION/stop-loop.pid" --stop-loop
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
# zygote's onrestart by hand: abort the FUSE connections the old framework left.
timeout 10 vdc volume abort_fuse >/dev/null 2>&1
setprop ctl.start zygote
if [ "$(base_prop init.svc.zygote_secondary)" = running ]; then
    setprop ctl.start zygote_secondary
    say "One UI's zygote_secondary started"
fi
n=0
while [ $n -lt 20 ] && [ "$(getprop init.svc.zygote)" != running ]; do sleep 0.5; n=$((n + 1)); done
[ "$(getprop init.svc.zygote)" = running ] || failsafe "One UI's zygote did not start ($(getprop init.svc.zygote))"
say "Gate B: One UI's zygote started"

echo "=== [4/4] $(date +%T) Gate C: One UI's system_server ==="
t=0; ss=""
while [ $t -lt 60 ]; do
    # Two pids: a child system_server forked and has not exec'd yet; ask again.
    ss=$(pidof system_server); case "$ss" in *" "*) ss="" ;; esac
    [ -n "$ss" ] && break
    sleep 1; t=$((t + 1))
done
[ -n "$ss" ] || failsafe "One UI's system_server did not start in 60 s"
say "One UI's system_server $ss"
# system_server feeds Samsung's software watchdog again from here.
: > "$SESSION/feeder.off"
t=0; up=0
while :; do
    sleep 2; t=$((t + 2))
    [ "$(cat /proc/$ss/comm 2>/dev/null)" = system_server ] ||
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
end_helper "$SESSION/feeder.pid" --feed
echo returned > "$SESSION/state"
echo "inplace $(date +%s) $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" > "$S/return.outcome"
echo oneios_session > /sys/power/wake_unlock 2>/dev/null
echo oneios_return > /sys/power/wake_unlock 2>/dev/null
say "One UI restored in place ($(getenforce 2>/dev/null))."

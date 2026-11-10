#!/system/bin/sh
# OneiOS root script: every change the OneOS app makes as root for the iOS 27
# (OneiOS) system is one of the verbs below, and nothing else (docs/oneios.md).
#
# Like oneos_root.sh, the app never runs this file from its own storage. Its
# launcher (OneiosRoot.kt, a fixed text) runs only $STAGE/bin/oneios_root.sh,
# root's and writable by root only, and only with the SHA-256 pinned in the
# app's BuildConfig; status, begin and remove may first install it there.
# Arguments are fixed words, decimal numbers, lowercase hex and plain relative
# paths only.
#
#   status                      read only: what is staged, the session, whether
#                               a switch would start (oneios_switch.sh --check)
#   begin <runtime|image>       start staging one of them into <kind>.new
#   receive <runtime|image> <path> <bytes> <sha256> <mode>
#                               stdin: exactly <bytes> bytes of <path>
#                               (mode 0644 or 0755)
#   script <name> <bytes> <sha256>
#                               stdin: oneios_switch.sh or oneios_return.sh
#   finish runtime <files> <version> <sessionAbi> <xnuhost> <imageFormats> <placeholder>
#   finish image <files> <format> <version> <build>
#                               <files> received files (the manifest included)
#                               become $STAGE/<kind>; the facts the app read
#                               from the checked manifest go to <kind>.conf
#   switch <versionCode> <ack>  the preflight, then the session, detached, in
#                               init's mount namespace (ack 1 = the
#                               experimental tick)
#   remove                      delete the stage (never during a session)
#
# Writes: only under $STAGE (/data/local/tmp/oneios), which is root's, mode
# 0700, and separate from OneOS's Android stage. Nothing of One UI's data, no
# property, no SELinux change. switch starts oneios_switch.sh; what that does
# is written at its top.
umask 077
T="${ONEIOS_TEST_ROOT:-}"
if [ -n "$T" ]; then
    [ "$(id -u)" != 0 ] || { echo "@@REFUSED ONEIOS_TEST_ROOT is for tests, never as root"; exit 3; }
fi
STAGE="$T/data/local/tmp/oneios"
OWNER=0
[ -z "$T" ] || OWNER=$(id -u)
EXIT_REFUSED=2
EXIT_USAGE=3
EXIT_FAILED=4
# One file of a runtime package or an image set: 16 GiB at most.
RECEIVE_MAX=17179869184
SCRIPT_MAX=1048576

say() { echo "$*"; }
refuse() { echo "@@REFUSED $*"; exit $EXIT_REFUSED; }
usage() { echo "@@REFUSED usage: $*"; exit $EXIT_USAGE; }
die() { echo "@@FAILED $*"; exit $EXIT_FAILED; }
is_dec() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ ${#1} -le 18 ]; }
is_hex64() { case "$1" in *[!0-9a-f]*) return 1 ;; esac; [ ${#1} -eq 64 ]; }
# A relative path of plain segments: no leading slash or dot, no "..", no "//".
is_path() {
    case "$1" in
        ''|/*|*/|.*|*/.*|*..*|*//*|*[!A-Za-z0-9._+/-]*) return 1 ;;
    esac
    [ ${#1} -le 200 ]
}
is_word() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; [ ${#1} -le 40 ]; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
mine() {
    [ ! -L "$1" ] && [ -e "$1" ] || return 1
    case "$(stat -c '%u %A' "$1" 2>/dev/null)" in
        "$OWNER "?????w*|"$OWNER "????????w*) return 1 ;;
        "$OWNER "*) return 0 ;;
    esac
    return 1
}
own() { # <path> <mode>
    { [ -n "$T" ] || chown 0:0 "$1"; } && chmod "$2" "$1"
}
boot_id() { cat "$T/proc/sys/kernel/random/boot_id" 2>/dev/null; }
conf() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
find_bb() {
    BB=""
    for c in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
        [ -x "$T$c" ] && { BB=$T$c; break; }
    done
}
# A session of this boot that has not returned, or an xnuhost still alive in
# the namespace the switch recorded.
session_open() {
    s="$STAGE/session"
    if [ "$(cat "$s/boot" 2>/dev/null)" = "$(boot_id)" ]; then
        case "$(cat "$s/state" 2>/dev/null)" in starting|running|returning) return 0 ;; esac
    fi
    p=$(cat "$s/xnuhost.pid" 2>/dev/null)
    n=$(cat "$s/mntns" 2>/dev/null)
    [ -n "$p" ] && [ -n "$n" ] && [ "$(readlink "$T/proc/$p/ns/mnt" 2>/dev/null)" = "$n" ]
}
stage_ok() {
    [ -d "$STAGE" ] && mine "$STAGE" || refuse "$STAGE is missing or not root's"
}
kind_ok() { case "$1" in runtime|image) ;; *) usage "kind '$1' is not runtime or image" ;; esac; }
manifest_name() { case "$1" in runtime) echo runtime.json ;; image) echo manifest.json ;; esac; }

do_status() {
    [ $# -eq 0 ] || usage "status"
    if [ ! -d "$STAGE" ]; then
        say "@@RESULT stage none"
        say "@@OK status"
        return
    fi
    say "@@RESULT stage present"
    rc="$STAGE/runtime.conf"
    if [ -f "$rc" ] && mine "$rc" && [ -d "$STAGE/runtime" ]; then
        say "@@RESULT runtime $(conf "$rc" version) $(conf "$rc" session_abi) $(conf "$rc" xnuhost) $(conf "$rc" image_formats) $(conf "$rc" placeholder)"
    else
        say "@@RESULT runtime none"
    fi
    ic="$STAGE/image.conf"
    if [ -f "$ic" ] && mine "$ic" && [ -d "$STAGE/image" ]; then
        b=$(conf "$ic" build)
        say "@@RESULT image $(conf "$ic" format) $(conf "$ic" version) ${b:-unknown} $(conf "$ic" bytes)"
    else
        say "@@RESULT image none"
    fi
    st=$(cat "$STAGE/session/state" 2>/dev/null)
    if session_open; then say "@@RESULT session open ${st:-running}"; else say "@@RESULT session none ${st:-never}"; fi
    o=$(head -n 1 "$STAGE/return.outcome" 2>/dev/null | cut -c1-200)
    case "$o" in inplace\ *|failsafe\ *|reboot\ *) say "@@RESULT outcome $o" ;; *) say "@@RESULT outcome none" ;; esac
    # Would a switch start now? The session script's own preflight, read only.
    if [ -f "$STAGE/oneios_switch.sh" ] && mine "$STAGE/oneios_switch.sh"; then
        if [ -n "$T" ]; then
            out=$(ONEIOS_TEST_ROOT="$T" sh "$STAGE/oneios_switch.sh" --check 2>&1)
        else
            find_bb
            if [ -n "$BB" ]; then
                out=$(ONEIOS_APP=1 ONEIOS_ACK_EXPERIMENTAL=1 "$BB" nsenter -t 1 -m -- /system/bin/sh "$STAGE/oneios_switch.sh" --check 2>&1 </dev/null)
            else
                out="PREFLIGHT REFUSED: no busybox at the root manager's paths"
            fi
        fi
        why=$(printf '%s\n' "$out" | sed -n 's/^PREFLIGHT REFUSED: //p' | head -n 1 | cut -c1-400)
        if [ -n "$why" ]; then say "@@RESULT ready 0 $why"
        elif printf '%s\n' "$out" | grep -q -e '^PREFLIGHT OK$' -e '^TEST ROOT: stage checks passed'; then say "@@RESULT ready 1"
        else say "@@RESULT ready 0 the preflight gave no answer: $(printf '%s\n' "$out" | tail -n 1 | cut -c1-200)"
        fi
    else
        say "@@RESULT ready 0 OneiOS is not set up on this phone yet"
    fi
    say "@@OK status"
}

do_begin() {
    [ $# -eq 1 ] || usage "begin <runtime|image>"
    kind_ok "$1"
    stage_ok
    session_open && refuse "an iOS session is running: return to One UI first"
    n="$STAGE/$1.new"
    [ ! -L "$n" ] || refuse "$n is a link"
    rm -rf "$n" "$STAGE/$1.new.sha256" "$STAGE/$1.new.ids" || die "could not clear $n"
    mkdir "$n" && own "$n" 0700 || die "could not make $n"
    : > "$STAGE/$1.new.sha256" && : > "$STAGE/$1.new.ids" && own "$STAGE/$1.new.sha256" 0600 && own "$STAGE/$1.new.ids" 0600 ||
        die "could not start the list"
    say "@@OK begin $1"
}

# Reads exactly <bytes> bytes of stdin into <file>.part, checks size and
# SHA-256, and only then gives it its name.
take() { # <file> <bytes> <sha256> <mode>
    f=$1
    rm -f "$f.part"
    head -c "$2" > "$f.part" || { rm -f "$f.part"; die "could not write ${f##*/}"; }
    got=$(stat -c %s "$f.part" 2>/dev/null)
    [ "$got" = "$2" ] || { rm -f "$f.part"; refuse "${f##*/}: $got of $2 bytes arrived"; }
    [ "$(sha "$f.part")" = "$3" ] || { rm -f "$f.part"; refuse "${f##*/} did not arrive intact (SHA-256 differs)"; }
    own "$f.part" "$4" && mv -f "$f.part" "$f" || { rm -f "$f.part"; die "could not place ${f##*/}"; }
}

do_receive() {
    [ $# -eq 5 ] || usage "receive <runtime|image> <path> <bytes> <sha256> <mode>"
    kind=$1 path=$2 bytes=$3 sum=$4 mode=$5
    kind_ok "$kind"
    is_path "$path" || usage "receive: path '$path'"
    is_dec "$bytes" || usage "receive: size '$bytes'"
    is_hex64 "$sum" || usage "receive: SHA-256"
    case "$mode" in 0644|0755) ;; *) usage "receive: mode '$mode'" ;; esac
    [ "$bytes" -le $RECEIVE_MAX ] || refuse "$path is too large"
    stage_ok
    session_open && refuse "an iOS session is running: return to One UI first"
    n="$STAGE/$kind.new"
    [ -d "$n" ] && mine "$n" || refuse "no $kind is being staged: begin first"
    awk -v p="$path" '$2 == p { f = 1 } END { exit !f }' "$STAGE/$kind.new.sha256" && refuse "$path was already received"
    # Room for the file and a little more.
    if [ -z "$T" ]; then
        set -- $(stat -f -c '%a %S' "$STAGE" 2>/dev/null)
        [ $# -eq 2 ] && [ "$(awk -v a="$1" -v s="$2" -v b="$bytes" 'BEGIN { print (a * s >= b + 268435456) ? 1 : 0 }')" = 1 ] ||
            refuse "not enough free space on /data for $path"
    fi
    # Its folders, each root's own, never through a link.
    d=$n
    rest=$path
    while [ "$rest" != "${rest#*/}" ]; do
        d="$d/${rest%%/*}"
        rest=${rest#*/}
        [ ! -L "$d" ] || refuse "$d is a link"
        [ -d "$d" ] || { mkdir "$d" && own "$d" 0700; } || die "could not make $d"
    done
    take "$n/$path" "$bytes" "$sum" "$mode"
    echo "$sum  $path" >> "$STAGE/$kind.new.sha256" &&
        echo "$(stat -c '%d:%i:%s:%Y' "$n/$path") $path" >> "$STAGE/$kind.new.ids" || die "could not record $path"
    say "@@OK receive $kind $path"
}

do_script() {
    [ $# -eq 3 ] || usage "script <name> <bytes> <sha256>"
    case "$1" in oneios_switch.sh|oneios_return.sh) ;; *) usage "script: '$1'" ;; esac
    is_dec "$2" && [ "$2" -ge 1 ] && [ "$2" -le $SCRIPT_MAX ] || usage "script: size '$2'"
    is_hex64 "$3" || usage "script: SHA-256"
    stage_ok
    session_open && refuse "an iOS session is running: return to One UI first"
    [ ! -L "$STAGE/$1" ] || refuse "$STAGE/$1 is a link"
    take "$STAGE/$1" "$2" "$3" 0700
    say "@@OK script $1"
}

do_finish() {
    [ $# -ge 1 ] || usage "finish <runtime|image> ..."
    kind=$1
    kind_ok "$kind"
    if [ "$kind" = runtime ]; then
        [ $# -eq 7 ] || usage "finish runtime <files> <version> <sessionAbi> <xnuhost> <imageFormats> <placeholder>"
        files=$2 version=$3 abi=$4 xnuhost=$5 formats=$6 placeholder=$7
        case "$placeholder" in 0|1) ;; *) usage "finish: placeholder '$placeholder'" ;; esac
        is_dec "$abi" || usage "finish: session ABI '$abi'"
        is_path "$xnuhost" || usage "finish: xnuhost '$xnuhost'"
        case "$formats" in ''|*[!0-9,]*|,*|*,|*,,*) usage "finish: image formats '$formats'" ;; esac
    else
        [ $# -eq 5 ] || usage "finish image <files> <format> <version> <build>"
        files=$2 format=$3 version=$4 build=$5
        is_dec "$format" || usage "finish: format '$format'"
        is_word "$build" || usage "finish: build '$build'"
    fi
    is_dec "$files" && [ "$files" -ge 2 ] || usage "finish: file count '$files'"
    is_word "$version" || usage "finish: version '$version'"
    stage_ok
    session_open && refuse "an iOS session is running: return to One UI first"
    n="$STAGE/$kind.new"
    sums="$STAGE/$kind.new.sha256"
    [ -d "$n" ] && mine "$n" && [ -f "$sums" ] && mine "$sums" || refuse "no $kind is being staged: begin first"
    got=$(awk 'END { print NR }' "$sums")
    [ "$got" = "$files" ] || refuse "$got of $files files were received"
    man=$(manifest_name "$kind")
    awk -v p="$man" '$2 == p { f = 1 } END { exit !f }' "$sums" || refuse "$man was not received"
    onDisk=$(cd "$n" && find . ! -type d | awk 'END { print NR }')
    [ "$onDisk" = "$files" ] || refuse "$kind.new holds $onDisk files, $files were received"
    if [ "$kind" = runtime ]; then
        awk -v p="$xnuhost" '$2 == p { f = 1 } END { exit !f }' "$sums" || refuse "the runtime has no $xnuhost"
        [ -x "$n/$xnuhost" ] || refuse "$xnuhost is not executable (mode 0755 in runtime.json)"
    fi
    c="$STAGE/$kind.conf.new"
    {
        echo "version=$version"
        if [ "$kind" = runtime ]; then
            echo "format=1"
            echo "session_abi=$abi"
            echo "xnuhost=$xnuhost"
            echo "image_formats=$formats"
            echo "placeholder=$placeholder"
        else
            echo "format=$format"
            echo "build=$build"
            echo "bytes=$(cd "$n" && find . -type f -exec stat -c %s {} + | awk '{ s += $1 } END { printf "%.0f", s }')"
        fi
        echo "staged=$(date +%s)"
    } > "$c" && own "$c" 0600 || die "could not write $kind.conf"
    # The old one aside, the new one in, then the old one gone. The guest's
    # data ($STAGE/data) is not touched: a new runtime or image keeps it.
    old="$STAGE/$kind.old-$$"
    rm -f "$STAGE/$kind.conf"
    if [ -e "$STAGE/$kind" ] || [ -L "$STAGE/$kind" ]; then
        mv "$STAGE/$kind" "$old" || die "could not move the old $kind aside"
    fi
    mv "$n" "$STAGE/$kind" && mv -f "$sums" "$STAGE/$kind.sha256" && mv -f "$STAGE/$kind.new.ids" "$STAGE/$kind.ids" &&
        mv -f "$c" "$STAGE/$kind.conf" || die "could not put the new $kind in place"
    rm -rf "$old"
    say "@@OK finish $kind $version"
}

do_switch() {
    [ $# -eq 2 ] || usage "switch <versionCode> <ack>"
    is_dec "$1" || usage "switch versionCode '$1'"
    case "$2" in 1) ;; *) refuse "the experimental tick was not given" ;; esac
    stage_ok
    for f in oneios_switch.sh oneios_return.sh; do
        [ -f "$STAGE/$f" ] && mine "$STAGE/$f" || refuse "$f is not staged: set up again"
    done
    session_open && refuse "an iOS session is already running"
    if [ -n "$T" ]; then
        out=$(ONEIOS_TEST_ROOT="$T" sh "$STAGE/oneios_switch.sh" --check 2>&1)
        why=$(printf '%s\n' "$out" | sed -n 's/^PREFLIGHT REFUSED: //p' | head -n 1)
        [ -z "$why" ] || refuse "$why"
        refuse "test root: every stage check passed, nothing was started"
    fi
    find_bb
    [ -n "$BB" ] || refuse "no busybox at the root manager's paths"
    for a in sh nsenter setsid; do
        "$BB" --list 2>/dev/null | grep -q -x "$a" || refuse "$BB lacks $a"
    done
    # The preflight first, here, so its refusal is the app's answer: one line,
    # and nothing was changed.
    out=$(ONEIOS_APP=1 ONEIOS_ACK_EXPERIMENTAL=1 "$BB" nsenter -t 1 -m -- /system/bin/sh "$STAGE/oneios_switch.sh" --check 2>&1 </dev/null)
    why=$(printf '%s\n' "$out" | sed -n 's/^PREFLIGHT REFUSED: //p' | head -n 1 | cut -c1-400)
    [ -z "$why" ] || refuse "$why"
    printf '%s\n' "$out" | grep -q '^PREFLIGHT OK$' || refuse "the preflight gave no answer: $(printf '%s\n' "$out" | tail -n 1 | cut -c1-200)"
    echo "=== OneOS app switch $(date '+%F %T') epoch $(date +%s) versionCode $1 ===" >> "$STAGE/switch.log"
    # Out of the app's cgroup: the app dies when One UI's framework stops.
    echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
    for v in $(env | sed -n 's/^\(ONEIOS_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    ONEIOS_APP=1 ONEIOS_ACK_EXPERIMENTAL=1 "$BB" nsenter -t 1 -m -- "$BB" setsid /system/bin/sh "$STAGE/oneios_switch.sh" \
        </dev/null >>"$STAGE/switch.log" 2>&1 &
    say "@@OK switch"
}

do_remove() {
    [ $# -eq 0 ] || usage "remove"
    [ -e "$STAGE" ] || [ -L "$STAGE" ] || { say "@@OK remove nothing"; return; }
    stage_ok
    session_open && refuse "an iOS session is running: return to One UI first"
    for m in "$T/proc/1/mountinfo" "$T/proc/self/mountinfo"; do
        [ -r "$m" ] || refuse "could not read $m"
        awk -v s="${STAGE#$T}" '$5 == s || index($5, s "/") == 1 { f = 1 } END { exit !f }' "$m" &&
            refuse "something is mounted in the stage: restart the phone first"
    done
    trash="$STAGE.trash-$(date +%s)"
    mv "$STAGE" "$trash" || die "could not move the stage aside"
    rm -rf "$trash" || die "could not delete $trash"
    say "@@OK remove"
}

[ -n "$T" ] || [ "$(id -u)" = 0 ] || refuse "not root"
verb=${1:-}
[ $# -gt 0 ] && shift
case "$verb" in
    status) do_status "$@" ;;
    begin) do_begin "$@" ;;
    receive) do_receive "$@" ;;
    script) do_script "$@" ;;
    finish) do_finish "$@" ;;
    switch) do_switch "$@" ;;
    remove) do_remove "$@" ;;
    *) usage "oneios_root.sh status|begin|receive|script|finish|switch|remove" ;;
esac

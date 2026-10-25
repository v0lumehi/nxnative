#!/bin/bash
# Agents' iPhone loop, step 2: one measured run on a wired device, with no one at the phone.
#   auto_run.sh <name> <env file> <seconds> [--route FILE] [--counters] [--no-trace] [--keep-app]
# Pushes the env file (plus the automation switches below) as Documents/env.txt and the route as Documents/ctl.txt (a DM_CTL file the host runs from its start: presses,
# stick holds, waits for a scene, screenshots, and the marks "steady" and "end"), optionally a save snapshot as Documents/<DM_AUTO_SAVE_NAME>, launches the app, waits for
# the route's "steady" mark in the log, records Instruments' Metal System Trace for <seconds> (all processes; --counters adds Metal GPU Counters), waits for "end" (at most
# DM_AUTO_END_WAIT s more), stops the app, pulls log.txt, frames.tsv and the route's screenshots, puts the device's own env.txt back, and summarises with
# dm/tools/frame_timeline.py (and DM_GPUPROF_PY on the log when set). Output: $DM_AUTO_RUNS/<name>/ (summary.txt first).
# The env file's lines win over the automation defaults; DM_SAVE is set only with a save snapshot, so without one the game uses the player's saves.
# Settings: the environment or the file $DM_AUTO_CONF (see dev_install.sh): DM_IOS_DEVICE, DM_IOS_BUNDLE, DM_AUTO_RUNS, DM_AUTO_ROUTE (default route), DM_AUTO_LOCK (a lock
# file shared with other agents using the phone: waited for, held during the run), DM_AUTO_SAVE (local save folder pushed before each launch, so every run starts from the
# same save and the player's saves are never written), DM_AUTO_SAVE_NAME (default save_auto), DM_AUTO_STEADY_WAIT (s, default 420), DM_AUTO_END_WAIT (s, default 120).
set -u
[ -n "${DM_AUTO_CONF:-}" ] && [ -f "$DM_AUTO_CONF" ] && . "$DM_AUTO_CONF"
die() { echo "[RED] $*" >&2; exit 1; }
[ $# -ge 3 ] || die "usage: auto_run.sh <name> <env file> <seconds> [--route FILE] [--counters] [--no-trace] [--keep-app]"
NAME=$1 ENVF=$2 SECS=$3; shift 3
ROUTE="${DM_AUTO_ROUTE:-}" COUNTERS=0 TRACE=1 KEEP=0
while [ $# -gt 0 ]; do case "$1" in --route) ROUTE=$2; shift;; --counters) COUNTERS=1;; --no-trace) TRACE=0;; --keep-app) KEEP=1;; *) die "unknown option $1";; esac; shift; done
D="${DM_IOS_DEVICE:?}" BID="${DM_IOS_BUNDLE:?}" R="${DM_AUTO_RUNS:?}/$NAME" LOCK="${DM_AUTO_LOCK:-}" SNAME="${DM_AUTO_SAVE_NAME:-save_auto}"
TOOLS="$(cd "$(dirname "$0")/../../tools" && pwd)"
[ -f "$ENVF" ] || die "no env file $ENVF"; [ -n "$ROUTE" ] && [ -f "$ROUTE" ] || die "no route file (--route or DM_AUTO_ROUTE)"
mkdir -p "$R"; L="$R/auto.log"; : > "$L"
say() { echo "$(date +%T) $*" | tee -a "$L"; }
dc() { local a=$1 b=$2 c=$3; shift 3; xcrun devicectl "$a" "$b" "$c" --device "$D" "$@" >> "$L" 2>&1; }   # three command words, then the device, then the rest (launch takes the bundle ID last)
put() { dc device copy to --domain-type appDataContainer --domain-identifier "$BID" --source "$1" --destination "Documents/$2"; }
get() { dc device copy from --domain-type appDataContainer --domain-identifier "$BID" --source "Documents/$1" --destination "$2"; }
app_url() {   # where this bundle is installed: other apps on the device may have an executable of the same name (DmIOS)
    xcrun devicectl device info apps --device "$D" --bundle-id "$BID" --json-output "$R/.apps.json" >/dev/null 2>&1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["apps"][0]["url"])' "$R/.apps.json" 2>/dev/null; }
running_pid() { xcrun devicectl device info processes --device "$D" --json-output "$R/.ps.json" >/dev/null 2>&1
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(next((str(p["processIdentifier"]) for p in d["result"]["runningProcesses"] if p.get("executable","").startswith(sys.argv[2])), ""))' "$R/.ps.json" "$APPURL" 2>/dev/null; }
others_busy() { pgrep -f "xctrace record" >/dev/null || pgrep -f "devicectl device (install|process launch)" >/dev/null; }
# --- the phone is shared: wait for the lock and for other recordings / installs, then hold the lock
if [ -n "$LOCK" ]; then
    n=0; while [ -e "$LOCK" ] || others_busy; do [ $((n % 12)) = 0 ] && say "waiting for the phone ($(cat "$LOCK" 2>/dev/null || echo 'another xctrace / devicectl run'))"; n=$((n + 1)); sleep 5; done
    echo "ios-auto $NAME $(date +%T)" > "$LOCK"; trap 'rm -f "$LOCK"' EXIT INT TERM
fi
xcrun devicectl device info details --device "$D" >> "$L" 2>&1 || die "device $D not reachable"
APPURL=$(app_url); [ -n "$APPURL" ] || die "$BID is not installed on $D"
[ -z "$(running_pid)" ] || die "the app is already running on the device (someone is playing?)"
# --- push the env, the route, the save snapshot
get env.txt "$R/env.device.txt" || : > "$R/env.device.txt"
{ echo "# auto_run.sh $NAME $(date '+%F %T')"; cat "$ENVF"; echo
  for kv in DM_LAUNCHER=0 DM_CTL=ctl.txt DM_NVN_TSV=frames.tsv DM_NVN_TSV_CALLS=0 DM_SIGNPOST=1 ${DM_AUTO_SAVE:+DM_SAVE=$SNAME}; do
      grep -q "^${kv%%=*}=" "$ENVF" || echo "$kv"; done; } > "$R/env.txt"
cp "$ROUTE" "$R/route.ctl"
put "$R/env.txt" env.txt || die "env push failed"
put "$R/route.ctl" ctl.txt || die "route push failed"
if [ -n "${DM_AUTO_SAVE:-}" ]; then put "$DM_AUTO_SAVE" "$SNAME" || die "save snapshot push failed"; say "save snapshot $DM_AUTO_SAVE → Documents/$SNAME"; fi
say "env and route pushed: $(grep -v '^#' "$R/env.txt" | grep . | tr '\n' ' ')"
cleanup_device() {   # the device's own env back, the route and the per-frame file emptied (the next manual start runs no route)
    : > "$R/.empty"; put "$R/env.device.txt" env.txt; put "$R/.empty" ctl.txt; put "$R/.empty" frames.tsv; }
# --- launch, wait for the route's steady part
dc device process launch --terminate-existing --json-output "$R/launch.json" "$BID" || { cleanup_device; die "launch failed"; }
PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["process"]["processIdentifier"])' "$R/launch.json" 2>/dev/null)
say "launched, pid ${PID:-?}"
t0=$(date +%s); steady=0
while [ $(( $(date +%s) - t0 )) -lt "${DM_AUTO_STEADY_WAIT:-420}" ]; do
    sleep 5; get log.txt "$R/log.txt" || continue
    if LC_ALL=C grep -aq "DM_CTL: mark steady" "$R/log.txt"; then steady=1; break; fi
    [ -n "$(running_pid)" ] || { say "[RED] the app ended before the steady mark"; break; }
done
if [ $steady = 1 ]; then
    say "steady part reached after $(( $(date +%s) - t0 )) s"
    if [ $TRACE = 1 ]; then
        xcrun devicectl device info details --device "$D" >> "$L" 2>&1   # the device "connected" for xctrace
        INST=(--template 'Metal System Trace'); [ $COUNTERS = 1 ] && INST+=(--instrument 'Metal GPU Counters')
        say "recording ${SECS} s (${INST[*]})"
        : > "$R/.rec_start"
        xcrun xctrace record "${INST[@]}" --device "$D" --all-processes --time-limit "${SECS}s" --no-prompt --output "$R/trace.trace" >> "$L" 2>&1 || say "[RED] xctrace exited $?"
        # xctrace leaves its raw kernel trace in the temp folder (about 0.1 GB per second recorded); the internal disk also has to hold the device installer's stage
        for k in "${TMPDIR:-/tmp}"/instruments*.ktrace; do [ -f "$k" ] && [ "$k" -nt "$R/.rec_start" ] && ! lsof "$k" >/dev/null 2>&1 && rm -f "$k"; done
    else sleep "$SECS"; fi
    t1=$(date +%s)
    while [ $(( $(date +%s) - t1 )) -lt "${DM_AUTO_END_WAIT:-120}" ]; do
        get log.txt "$R/log.txt" && LC_ALL=C grep -aq "DM_CTL: mark end" "$R/log.txt" && break; sleep 5; done
else say "[RED] no steady mark within ${DM_AUTO_STEADY_WAIT:-420} s"; fi
# --- stop, pull, clean up
if [ $KEEP = 0 ]; then   # terminate, wait for the exit, and kill what is left (one run's app still ran when the next run started)
    P2=$(running_pid); [ -n "$P2" ] && dc device process terminate --pid "$P2"
    for i in 1 2 3 4 5 6 7 8; do [ -z "$(running_pid)" ] && break; sleep 2; done
    P2=$(running_pid); [ -n "$P2" ] && { dc device process signal --signal 9 --pid "$P2"; sleep 2; say "the app did not end on SIGTERM; killed"; }
fi
get log.txt "$R/log.txt"; get frames.tsv "$R/frames.tsv"
for s in $(sed -n 's/^shot \([^ /]*\.png\)$/\1/p' "$R/route.ctl"); do get "$s" "$R/$s"; done
cleanup_device
say "pulled: $(cd "$R" && ls | tr '\n' ' ')"
[ -n "$LOCK" ] && rm -f "$LOCK"
# --- summaries (Mac only from here)
TA=(); [ -d "$R/trace.trace" ] && TA=(--trace "$R/trace.trace")
python3 "$TOOLS/frame_timeline.py" "$R" --from-mark steady --to-mark end ${TA[@]+"${TA[@]}"} --json "$R/summary.json" > "$R/summary.txt" 2>&1 || say "[RED] frame_timeline.py failed (see summary.txt)"
[ -n "${DM_GPUPROF_PY:-}" ] && LC_ALL=C grep -aq "\[gpuprof\]" "$R/log.txt" && python3 "$DM_GPUPROF_PY" "$R/log.txt" > "$R/gpuprof.txt" 2>&1
cat "$R/summary.txt"

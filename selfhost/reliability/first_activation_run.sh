#!/usr/bin/env bash
# cspell:words rbtrace idevicesyslog idevicescreenshot idevicecrashreport routeb dlc
#
# first_activation_run.sh -- capture ONE launch of the disappearance
# investigation, into an immutable per-run folder.
#
# THE RULE THIS ENCODES: syslog is A SOURCE, NOT THE TRUTH. Both failure modes
# have already been paid for on this rig --
#   * a Route B line was DROPPED under load and was very nearly read as a failed
#     activation, when the durable trace showed the activation succeeded;
#   * the capture reader was accidentally killed and stalled silently, so a
#     launch that definitely happened left no syslog record at all.
# A stalled capture is indistinguishable from "nothing happened", so this script
# MEASURES capture health and marks syslog UNUSABLE rather than letting its
# silence mean anything.
#
# Phases are explicit because a human tap sits in the middle:
#
#   arm      <run-id>   start capture, snapshot PRE state, verify the guard
#   collect  <run-id>   screenshot while alive, stop capture, pull everything
#   delayed  <run-id>   the second crash-report pull, later
#
# Nothing here changes lifecycle semantics, the certified runtime, or the cell;
# `arm` refuses to run if anything frozen has moved.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNS=${RUNS:-$HERE/first_activation_runs}
BUNDLE=${BUNDLE:-dev.selfhost.firstActivationProbe}
CMD=${1:-}
RUN=${2:-}
[[ -n "$CMD" && -n "$RUN" ]] || { sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 2; }
D="$RUNS/$RUN"

note() { printf '  %s\n' "$*"; }
die()  { printf '  ERROR: %s\n' "$*" >&2; exit 2; }

case "$CMD" in
arm)
  [[ -e "$D" ]] && die "$D already exists -- runs are immutable, pick a new id"
  mkdir -p "$D"
  # A run captured against a moved runtime is worthless and, worse, misleading.
  if ! bash "$HERE/verify_frozen_surfaces.sh" > "$D/frozen_surfaces.txt" 2>&1; then
    note "REFUSING: frozen surfaces have moved"; sed 's/^/    /' "$D/frozen_surfaces.txt"; exit 1
  fi
  note "frozen surfaces intact"

  {
    echo "run_id           $RUN"
    echo "bundle           $BUNDLE"
    echo "host_armed_at    $(date -u +%FT%TZ)"
    echo "device           $(idevice_id -l 2>/dev/null | head -1)"
    echo "repo_head        $(git -C "$HERE/../.." rev-parse HEAD 2>/dev/null)"
  } > "$D/manifest.txt"

  # PRE state, so a disappearance can be diffed against what preceded it.
  mkdir -p "$D/pre_state"
  ios-deploy --download --bundle_id "$BUNDLE" --to "$D/pre_state" >/dev/null 2>&1
  mkdir -p "$D/crashreports_pre"
  idevicecrashreport --keep "$D/crashreports_pre" >/dev/null 2>&1

  # KILL EVERY READER, and the narrower version was a bug.
  #
  # This used to be `pkill -f "idevicesyslog.*$RUNS"`, matching on the output
  # path. That only matches the bash WRAPPER: the bare `idevicesyslog` child has
  # nothing but its own name on the command line, so every arm leaked one.
  # Measured: eleven orphaned readers accumulated, all competing for the device's
  # single syslog service, and new captures received ZERO lines -- which is also
  # what stalled the capture in the Epoch B canary lane, where I wrongly blamed
  # killing the wrong process.
  #
  # The harness owns the device's syslog for the duration of a run. There should
  # never be a second reader, so kill them all.
  pkill -f idevicesyslog 2>/dev/null
  # CAPTURE RAW, FILTER AT COLLECT. Filtering in the stream made liveness
  # untestable: the first version waited for an APP-related line while the app was
  # still closed, so it could never pass and refused every arm. A narrow live
  # filter also risks discarding a line nobody predicted mattering.
  # Create the file BEFORE the writer starts. `tail -f` on a nonexistent path
  # fails INSTANTLY rather than waiting, so without this the liveness probe below
  # returned at once and refused every arm -- a race in the check, not a dead
  # reader. Two refusals were spent finding that.
  : > "$D/syslog_raw.log"
  nohup bash -c "idevicesyslog >> '$D/syslog_raw.log' 2>&1" >/dev/null 2>&1 &
  echo "$!" > "$D/capture.pid"

  # ARM MEANS ACTUALLY CAPTURING, and it is proved before returning.
  #
  # A reader that starts but receives nothing is indistinguishable from a quiet
  # device, and a run armed that way produces syslog that proves nothing -- which
  # already happened once, on top of eleven orphaned readers starving the service.
  # Block until the first line of ANY kind arrives: `tail -f | head -1` returns as
  # soon as there is one and `timeout` bounds the wait, with no sleep involved.
  # Read the first line into a VARIABLE rather than testing the pipeline's exit
  # status. `set -o pipefail` is on, and `head -1` closing the pipe sends SIGPIPE
  # to `tail`, which then exits 141 -- so pipefail reported the pipeline as failed
  # even when a line HAD arrived. That cost a third refusal, and it is the same
  # trap as reading $? through a pipeline instead of measuring the command.
  first_line=$(timeout 25 tail -f "$D/syslog_raw.log" 2>/dev/null | head -1 || true)
  if [[ -n "$first_line" ]]; then
    note "capture armed and RECEIVING -> $D/syslog_raw.log"
  else
    note "REFUSING: capture started but received nothing in 25s."
    note "  A run armed on a dead reader yields syslog that proves nothing."
    note "  Check for competing readers (pgrep -fl idevicesyslog) and the cable."
    pkill -f idevicesyslog 2>/dev/null
    exit 1
  fi
  note "NOW: launch the app by hand, leave it on screen, then run:"
  note "  first_activation_run.sh collect $RUN"
  ;;

collect)
  [[ -d "$D" ]] || die "no run at $D -- arm it first"
  # Screenshot FIRST, while the process may still be alive.
  idevicescreenshot "$D/render.png" >/dev/null 2>&1 && note "render captured" \
    || note "render NOT captured (app likely already gone)"

  # Derive the filtered view the report reads, from the raw capture.
  grep -iE "shorebird|routeb|Runner|$BUNDLE|Bootstrap|jetsam|watchdog|termina" \
    "$D/syslog_raw.log" > "$D/syslog.log" 2>/dev/null || true

  # SYSLOG HEALTH, measured rather than assumed.
  alive=no; kill -0 "$(cat "$D/capture.pid" 2>/dev/null)" 2>/dev/null && alive=yes
  lines=$(wc -l < "$D/syslog_raw.log" 2>/dev/null | tr -d ' ')
  saw_app=$(grep -c "$BUNDLE\|Runner(Flutter)" "$D/syslog.log" 2>/dev/null || echo 0)
  if [[ "$alive" == yes && "${lines:-0}" -gt 0 && "${saw_app:-0}" -gt 0 ]]; then
    health="USABLE (reader alive, $lines lines, $saw_app app lines)"
  elif [[ "${saw_app:-0}" -gt 0 ]]; then
    health="PARTIAL (app lines present but reader died: $lines lines)"
  else
    health="UNUSABLE (reader_alive=$alive, lines=${lines:-0}, app_lines=${saw_app:-0})"
  fi
  note "syslog health: $health"
  pkill -f "idevicesyslog.*$RUNS" 2>/dev/null

  mkdir -p "$D/crashreports_immediate" "$D/post_state"
  idevicecrashreport --keep "$D/crashreports_immediate" >/dev/null 2>&1
  ios-deploy --download --bundle_id "$BUNDLE" --to "$D/post_state" >/dev/null 2>&1

  U="$D/post_state/Library/Application Support/shorebird/shorebird_updater"
  {
    echo "host_collected_at $(date -u +%FT%TZ)"
    echo "syslog_health     $health"
    echo
    echo "# --- updater state ---"
    [[ -f "$U/pointers.json" ]] && { echo "pointers:";  sed 's/^/  /' "$U/pointers.json"; echo; }
    [[ -f "$U/state.json" ]]    && { echo "state:";     sed 's/^/  /' "$U/state.json"; echo; }
    [[ -f "$U/success_diag.log" ]] && { echo "success_diag:"; sed 's/^/  /' "$U/success_diag.log"; }
    echo
    echo "# --- per-patch state and artifact hashes ---"
    for p in "$U"/patches/*/; do
      [[ -d "$p" ]] || continue
      n=$(basename "$p")
      echo "patch $n:"
      [[ -f "$p/state.json" ]] && sed 's/^/    /' "$p/state.json"
      for a in "$p"dlc.vmcode "$p"dlc.vmcode.routeb; do
        [[ -f "$a" ]] && printf '    %-24s %s  %s bytes\n' "$(basename "$a")" \
          "$(shasum -a 256 "$a" | cut -d' ' -f1)" "$(stat -f%z "$a")"
      done
      [[ -f "$p/dlc.vmcode.routeb.trace" ]] && {
        echo "    rbtrace records: $(grep -c rbtrace "$p/dlc.vmcode.routeb.trace")"
        echo "    rbtrace latest:  $(tail -1 "$p/dlc.vmcode.routeb.trace" | cut -c1-160)"
      }
    done
    echo
    echo "# --- Dart lifetimes in the timeline ---"
    #
    # PID IS NOT A PROCESS BOUNDARY HERE. Measured in run_006: the Dart VM was
    # torn down and rebuilt INSIDE the same OS process -- `seq` restarted at 0
    # while the native side's process-start static kept counting (378 s at
    # FLUTTER_ENGINE_INITIALIZED). So two Dart lifetimes shared one pid.
    #
    # That breaks two things if it goes unnoticed: grepping the timeline by pid
    # merges distinct lifetimes, and correlating to success_diag by pid is
    # ambiguous -- report_launch_success is guarded once per PROCESS, so a second
    # in-process Dart lifetime CANNOT re-report success even if it reached the
    # trigger. Absence of a success row is then not evidence of anything.
    #
    # Segment by PROCESS_BEGIN and say so out loud.
    T="$D/post_state/Documents/first_activation_timeline.log"
    if [[ -f "$T" ]]; then
      n_begin=$(grep -c 'event=PROCESS_BEGIN' "$T")
      n_pid=$(grep -oE 'pid=[0-9]+' "$T" | sort -u | wc -l | tr -d ' ')
      echo "  PROCESS_BEGIN blocks: $n_begin   distinct pids: $n_pid"
      last_pid=$(grep -oE 'pid=[0-9]+' "$T" | tail -1 | cut -d= -f2)
      begins_last_pid=$(grep "pid=$last_pid" "$T" | grep -c 'event=PROCESS_BEGIN')
      if [[ "${begins_last_pid:-0}" -gt 1 ]]; then
        echo "  WARNING: pid $last_pid carries $begins_last_pid Dart lifetimes."
        echo "           Segment by PROCESS_BEGIN, not by pid. success_diag"
        echo "           correlation by pid is AMBIGUOUS for this run: success is"
        echo "           reported once per PROCESS, so a later in-process Dart"
        echo "           lifetime cannot re-report it."
      fi
    fi
    echo
    echo "# --- app durable timeline (the investigation fixture writes this) ---"
    if [[ -f "$T" ]]; then sed 's/^/  /' "$T"; else echo "  (absent)"; fi
    echo
    echo "# --- crash reports ---"
    # REPORTED AS NEW-SINCE-ARM, not as a raw listing. The device keeps old
    # reports, so a plain listing shows unrelated history and reads as though it
    # belonged to THIS run -- which it did, misleadingly, the first time: three
    # reports from an earlier instrumentation bug appeared under every run.
    echo "  pre:       $(find "$D/crashreports_pre" -type f 2>/dev/null | wc -l | tr -d ' ')"
    echo "  immediate: $(find "$D/crashreports_immediate" -type f 2>/dev/null | wc -l | tr -d ' ')"
    comm -13 \
      <(find "$D/crashreports_pre" -type f -exec basename {} \; 2>/dev/null | sort) \
      <(find "$D/crashreports_immediate" -type f -exec basename {} \; 2>/dev/null | sort) \
      > "$D/crashreports_new.txt"
    n_new=$(wc -l < "$D/crashreports_new.txt" | tr -d ' ')
    echo "  NEW since arm: $n_new"
    if [[ "${n_new:-0}" -gt 0 ]]; then
      sed 's/^/    /' "$D/crashreports_new.txt"
      echo "  app-related among the NEW ones:"
      grep -iE "Runner|Jetsam|rstActivation" "$D/crashreports_new.txt" | sed 's/^/    /' || echo "    (none)"
    fi
  } >> "$D/manifest.txt"
  note "collected -> $D/manifest.txt"
  note "run the delayed crash pull later:  first_activation_run.sh delayed $RUN"
  ;;

delayed)
  [[ -d "$D" ]] || die "no run at $D"
  mkdir -p "$D/crashreports_delayed"
  idevicecrashreport --keep "$D/crashreports_delayed" >/dev/null 2>&1
  {
    echo
    echo "# --- delayed crash pull $(date -u +%FT%TZ) ---"
    echo "  files: $(find "$D/crashreports_delayed" -type f 2>/dev/null | wc -l | tr -d ' ')"
    comm -13 \
      <(find "$D/crashreports_pre" -type f -exec basename {} \; 2>/dev/null | sort) \
      <(find "$D/crashreports_delayed" -type f -exec basename {} \; 2>/dev/null | sort) \
      > "$D/crashreports_new_delayed.txt"
    echo "  NEW since arm: $(wc -l < "$D/crashreports_new_delayed.txt" | tr -d ' ')"
    sed 's/^/    /' "$D/crashreports_new_delayed.txt"
  } >> "$D/manifest.txt"
  note "delayed pull recorded"
  ;;
*) die "unknown phase: $CMD" ;;
esac

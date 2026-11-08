#!/usr/bin/env bash
# ─── Built-in check: honest status (PLAN §1a) ───
# Polls every 1 s for the whole scenario: the status call must answer in < 1 s, "active" only while traffic really
# leaves through the node, "blocked" only while nothing leaves. Egress comes from its own probe loop (the latest probe that ended within 2.5 s, else unknown), and a
# mismatch counts only if the next sample agrees with it (one-sample skew at a state change is not a lie, Q0418 b).

# status_fresh_egress <egress-live.tsv> <now ms_mono>: the value of the latest probe that ENDED within
# STATUS_EGRESS_FRESH_MS_LIVE (2500) of now AND whose probe also STARTED within that window, else "unknown"
# (not judged). A probe that SPANNED the window (started before it) measured egress before the state change at
# the edge: a probe in flight across a daemon stop still read the node, so that node value is pre-stop, not a
# live reading. Grading it against a teardown "none" sample produced 4 false "LIE state=none egress=<node>" rows
# after S2 term_persist/kill (ABW 11-08: 0 routes to the node after S2, kill switch removed cleanly). Unknown
# there means the pcap leak check owns the teardown verdict. (The recorder path already gates on start; see
# status_from_recorder and the conv_ hung-probe selftest.)
status_fresh_egress() {
  awk -F'\t' -v now="$2" -v fresh="${STATUS_EGRESS_FRESH_MS_LIVE:-2500}" \
    '$2 ~ /^[0-9]+$/ && $2 <= now && (e == "" || $2 >= e) { e = $2; s = $1; v = $3 }
     END { print (e != "" && now - e <= fresh && s ~ /^[0-9]+$/ && now - s <= fresh) ? v : "unknown" }' "$1" 2>/dev/null || echo unknown
}

# status_line_capped: plat_status_line with a STATUS_CALL_CAP_S (5) cap (FLX 11-08, tlx-u22: after a hy2 kill one
# status call never returned and the poller recorded nothing for the rest of the cell). A call past the cap gives
# "state=unknown" and its time counts as slow: a status call that does not answer is a finding, not a gap.
status_line_capped() {
  local f; f=$(mktemp "${TMPDIR:-/tmp}/cbm-sl.XXXXXX")
  ( plat_status_line > "$f" 2>&1 ) & local p=$! i=0 cap=$(( ${STATUS_CALL_CAP_S:-5} * 10 ))
  while kill -0 "$p" 2>/dev/null; do
    if [ "$i" -ge "$cap" ]; then
      pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null
      echo "state=unknown ks=- id=- text=status call did not answer in ${STATUS_CALL_CAP_S:-5} s"; rm -f "$f"; return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  cat "$f"; rm -f "$f"
}

status_start() {
  : > "$SCEN_DIR/status.tsv"; : > "$SCEN_DIR/active-windows.txt"; : > "$SCEN_DIR/egress-live.tsv"
  # Egress runs in its own loop (FLX 11-08, tlx-u22): read inline, a blocked probe waited out its 6 s cap on every
  # sample, so a ks-on cell got 1 status sample per ~7 s (4 in 28 s). Rows: <start ms> <end ms> <value> (ms_mono).
  (
    trap 'exit 0' TERM
    while :; do
      a=$(ms_mono); v=$(plat_egress 2>/dev/null | tail -1); printf '%s\t%s\t%s\n' "$a" "$(ms_mono)" "${v:-none}" >> "$SCEN_DIR/egress-live.tsv"
      sleep 1 & wait $!
    done
  ) &
  EGRESS_PID=$!
  (
    prev=''; open=''
    # a session still active when the scenario ends keeps its window (status_stop kills this poller)
    trap '[ -n "$open" ] && echo "$open $(date +%s)" >> "$SCEN_DIR/active-windows.txt"; exit 0' TERM
    while :; do
      t0=$(ms_mono); line=$(status_line_capped); d=$(( $(ms_mono) - t0 ))
      # An adapter that times the one reported `client status` call itself (call_ms=, Windows: the ssh hop and the
      # session list are harness cost, not the < 1 s promise; TWA 11-08) gives that time instead.
      [[ $line =~ \ call_ms=([0-9]+) ]] && d=${BASH_REMATCH[1]}
      eg=$(status_fresh_egress "$SCEN_DIR/egress-live.tsv" "$(ms_mono)")
      st=$(sed -nE 's/.*state=([a-z]+).*/\1/p' <<<"$line")
      printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$d" "$eg" "$line" >> "$SCEN_DIR/status.tsv"
      # active windows for the KS-off leak rule
      # an unanswered status call says nothing about the state: the window stays as it was
      # KS off + "reconnecting" (final3, 0fec906): the tunnel is down and traffic goes direct BY DESIGN, so that
      # sample closes the window (direct DNS/RPC then is not a leak). KS on/persist keep it: the block must hold.
      [ "$st" = active ] && [[ $line == *ks=off* ]] && [[ $line == *reconnecting* ]] && st=reconnecting-direct
      if [ "$st" = active ] && [ -z "$open" ]; then open=$(date +%s); fi
      if [ "$st" != active ] && [ "$st" != unknown ] && [ -n "$open" ]; then echo "$open $(date +%s)" >> "$SCEN_DIR/active-windows.txt"; open=''; fi
      sleep 1 & wait $!   # wait, not a bare sleep, so the TERM trap runs at once
    done
  ) &
  STATUS_PID=$!
}

status_stop() {
  local slow lies
  # never kill 0 (that signals the whole process group): recorder mode and the selftest have no poller
  if [ "${STATUS_PID:-0}" -gt 0 ]; then kill "$STATUS_PID" 2>/dev/null; wait "$STATUS_PID" 2>/dev/null; fi
  if [ "${EGRESS_PID:-0}" -gt 0 ]; then kill "$EGRESS_PID" 2>/dev/null; wait "$EGRESS_PID" 2>/dev/null; EGRESS_PID=0; fi
  if [ ! -s "$SCEN_DIR/status.tsv" ]; then
    # 0 samples = a blind status row, and no active window for the leak check: never a PASS (DIR 11-08, FLX u22)
    result status FAIL "no samples: the status poller recorded nothing"; return 0
  fi
  lies=$(status_lies "$SCEN_DIR/status.tsv")
  # slow counts judged samples only: a previous session's rows (STALE) are not this cell's status calls (TWA 11-08)
  slow=$(awk '$1 == "SLOW" { print $2 }' "$SCEN_DIR/status-lies.txt" 2>/dev/null); slow=${slow:-0}
  if [ "$slow" = 0 ] && [ "$lies" = 0 ]; then
    result status PASS "$(grep -c . "$SCEN_DIR/status.tsv" || true) samples, all < 1 s and honest"
  else
    result status FAIL "slow(>=1s)=$slow dishonest=$lies; first: $(awk -F'\t' '$2 >= 1000' "$SCEN_DIR/status.tsv" | head -1)$(grep -m1 LIE "$SCEN_DIR/status-lies.txt" 2>/dev/null)"
  fi
}

# status_from_recorder <dir>: the recorder's status-recorder.tsv ("epoch_ms  ms  <state=… line>  egress  [app]") →
# status.tsv ("epoch_s  ms  egress  line"); rows with an app column → status-app.tsv (app-vs-daemon check).
# - CRLF: the Windows recorder writes it; a kept CR makes every egress "<ip>\r" that never matches the node (F1).
# - Egress per sample (DIR 11-08, TWA x64 core_ks-openvpn): the recorder copies the LAST egress.tsv row, and a
#   probe's row lands only when it finishes, so a probe that hangs (12 s seen; the 4 s cap does not hold) leaves
#   an old "none" on every sample meanwhile. With egress.tsv present, each sample takes the result of the latest
#   probe that STARTED within STATUS_EGRESS_FRESH_MS (4000) before it, else "unknown", which is not judged.
status_from_recorder() {
  local d=$1 eg=$1/egress.tsv
  [ -s "$eg" ] || eg=/dev/null
  awk -F'\t' -v OFS='\t' -v egf="$eg" -v fresh="${STATUS_EGRESS_FRESH_MS:-4000}" -v sf="$d/status.tsv" -v af="$d/status-app.tsv" -v haveeg="$([ "$eg" = /dev/null ] && echo 0 || echo 1)" '
    { sub(/\r$/, "") }
    FILENAME == egf { if ($1 ~ /^[0-9]+$/) { n++; t[n] = $1; v[n] = $2 }; next }   # not NR == FNR: /dev/null is empty
    { e = $4
      if (haveeg) { e = "unknown"; for (i = n; i >= 1; i--) if (t[i] <= $1) { if ($1 - t[i] <= fresh) e = v[i]; break } }
      if ($5 == "") print int($1 / 1000), $2, e, $3 > sf; else print int($1 / 1000), $2, e, $3, $5 > af }
  ' "$eg" "$d/status-recorder.tsv"
  touch "$d/status.tsv" "$d/status-app.tsv"
  status_windows_from_tsv "$d/status.tsv" > "$d/active-windows.txt"
}

# status_windows_from_tsv <status.tsv> → "<start s> <end s>" per active window, by the live poller's rule: a window
# opens on "active", closes on any other known state; "unknown" keeps it as it was; a ks=off "reconnecting" sample
# closes it (traffic goes direct by design, final3). A window still open at the end closes at the last sample.
# Recorder mode (Windows) wrote no windows file, so every ks=on cell read "cannot judge" (TWA S1 11-08).
# status_windows_from_tsv <status.tsv> tunnel: as above, but an active sample of a proxy session (the adapter's line says
# proxy=1: v2ray/xray are a local SOCKS proxy, no tunnel) closes the window, so only full-tunnel time is left (rpc-direct).
status_windows_from_tsv() {
  awk -F'\t' -v tunnel="${2:-}" '
    { gsub(/\r/, ""); l = $4; st = l; sub(/.*state=/, "", st); sub(/ .*/, "", st)
      if (st == "active" && l ~ /ks=off/ && l ~ /reconnecting/) st = "reconnecting-direct"
      if (tunnel != "" && st == "active" && l ~ / proxy=1/) st = "proxy"
      if (st == "active" && open == "") open = $1
      if (st != "active" && st != "unknown" && open != "") { print open, $1; open = "" }
      last = $1 }
    END { if (open != "") print open, last }' "$1"
}

# status_lies <status.tsv> → count of samples where status and egress disagree twice in a row.
# Each sample is judged against the session it reports (DIR 11-08, FWA Windows F1): an ended/none sample about a
# session that is never live in this cell is the previous cell's ("stopped by user") and is not judged, so back-to-
# back sessions don't count the old one's rows against the new one. Lines without id= (older recordings): the
# ended/none rows before the cell's first live sample are skipped when they say "stopped by user".
# Transition grace (DIR fix (b) 11-08, Windows SLOW; TWA raw x64 S1 core-wireguard): the status CLI hangs ~5-6 s and
# writes ONE capped "did not answer in 5 s" sample (state=unknown, egress=direct) while the daemon is legitimately
# absent during the harness's own cell-start restart and teardown (the status poller spans those windows). Steady
# state is 50-160 ms. With CBM_TRANSITION_GRACE_S>0 such a slow sample - slow AND state=unknown AND not flanked by a
# live sample within grace seconds on BOTH sides (so: the leading edge before the tunnel is up, the trailing edge
# after it is down, or the gap of a mid-recording daemon restart in S2/S11/S12) - is EXCLUDED from the SLOW count and
# logged as a TRANSITION row (its ms + line) so FWA/FWX still measure the separate "CLI hangs instead of failing fast"
# finding. Default 0 = off, so Linux/Mac (steady fast status, no recorder restart window) are unaffected. The grace
# bound keeps it honest: a slow sample that reads active/none/ended, or an unknown with live samples within grace on
# both sides (a genuine mid-session wedge), is NOT excused - it still counts as SLOW.
status_lies() {
  awk -F'\t' -v node="$NODE_EGRESS" -v direct="$DIRECT_IP" -v out="$SCEN_DIR/status-lies.txt" \
      -v grace="${CBM_TRANSITION_GRACE_S:-0}" '
    function bad(st, txt, eg) {
      if (eg == "unknown" || eg == "") return 0   # no measurement for this sample (status_from_recorder): not judged
      if (txt ~ /blocked/ && eg != "none") return 1
      # "active" + "connection lost; reconnecting" is the daemon saying the tunnel is down (the fork reconnecting
      # contract, final2; FAN 11-08 Android S2): it claims no traffic through the node, so any egress is honest.
      # (No apostrophes in these comments: this awk program sits inside single quotes.)
      if (st == "active" && txt ~ /reconnecting/) return 0
      if (st == "active" && eg != node) return 1
      if ((st == "none" || st == "ended") && eg == node) return 1
      return 0
    }
    function parse(l) { st = l; sub(/.*state=/, "", st); sub(/ .*/, "", st)
      id = ""; if (l ~ / id=/) { id = l; sub(/.* id=/, "", id); sub(/ .*/, "", id) } }
    function live(s) { return s == "active" || s == "connecting" || s == "checking" || s == "reconnecting" }
    # a slow unknown sample is a transition when no live sample sits within grace seconds on BOTH sides of its time t
    function in_transition(t,   i, before, after) {
      if (grace <= 0) return 0
      before = 0; after = 0
      for (i = 1; i <= nl; i++) {
        if (lt[i] <= t && t - lt[i] <= grace) before = 1
        if (lt[i] >= t && lt[i] - t <= grace) after = 1
      }
      return !(before && after)
    }
    { gsub(/\r/, "") }   # a CRLF recording must not turn every egress into "<ip>\r"
    NR == FNR { parse($4); if (live(st)) { anylive = 1; lt[++nl] = $1 + 0; if (id != "" && id != "-") own[id] = 1 }; next }
    { parse($4); txt = $4
      if (live(st)) seenlive = 1
      stale = 0
      if (!live(st) && id != "" && id != "-" && !(id in own)) stale = 1
      if (!live(st) && id == "" && anylive && !seenlive && txt ~ /stopped by user/) stale = 1
      if (stale) { s++; pb = 0; next }
      if ($2 >= 1000) {
        if (st == "unknown" && in_transition($1 + 0)) { tr++; print "TRANSITION " $0 > out }
        else slow++
      }
      b = bad(st, txt, $3)
      if (b && pb) { c++; print "LIE " $0 > out }
      pb = b }
    END { print "SLOW " slow + 0 > out; if (tr) print "TRANSITION-COUNT " tr " sample(s) in a daemon restart/teardown window, excluded from SLOW" > out
      if (s) print "STALE " s " sample(s) of a previous session, not judged" > out; print c+0 }' "$1" "$1"
}

status_selftest() {
  SCEN_DIR=$OUT/selftest/status; mkdir -p "$SCEN_DIR"
  printf '1\t40\t%s\tstate=active ks=off text=Connected\n2\t40\t%s\tstate=active ks=off text=Connected\n' \
    "$DIRECT_IP" "$DIRECT_IP" > "$SCEN_DIR/status.tsv"   # planted: "active" while traffic is direct
  SCENARIO_FAILED=0; STATUS_PID=0; SCENARIO=selftest-status status_stop
  [ "$SCENARIO_FAILED" = 1 ] && echo "status selftest: caught the planted lie" || echo "status selftest: MISSED the planted lie"
}

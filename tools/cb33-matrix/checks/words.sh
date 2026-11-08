#!/usr/bin/env bash
# ─── Built-in check: plain words (PLAN §1a) ───
# Every CLI/app message the scenario produced must read as plain words: no wrapped Go/gRPC errors, format verbs,
# stack frames or long raw keys.

WORDS_BAD='rpc error:|code = [A-Z]|desc = |context deadline exceeded|%!|goroutine [0-9]+|\.go:[0-9]+|panic:|please contact support|<nil>|0x[0-9a-f]{8,}'
WORDS_LONG='[1-9A-HJ-NP-Za-km-z]{45,}|[0-9a-f]{65,}'
# A long base58/hex key check (WORDS_LONG) is about a raw key dumped into USER PROSE ("your key is CVeg..."). A
# machine JSON line - a quoted field like `  "channel": "<id>": {` or `"id": "<id>",` from a status/sessions dump -
# is not user text and legitimately carries ids, so it is NOT a words FAIL (TLX2 11-08, S2 deb12 daemon_term/hy2:
# a post-restart channel id in cli.txt JSON that did not match the cell's $CHANNEL slipped the id allowlist). We
# exclude JSON-structure lines from WORDS_LONG only; WORDS_BAD (wrapped Go errors, stack frames, format verbs) still
# applies to them, because a Go error leaking inside JSON is still a defect.
WORDS_JSON='^[[:space:]]*(\{|\}|\[|\]|"[^"]+"[[:space:]]*:)'

words_start() { :; }

words_stop() {
  local txt bad badlong
  txt=$(plat_cli_outputs 2>/dev/null)
  [ -z "$txt" ] && { result words SKIP "adapter returned no messages"; return 0; }
  printf '%s\n' "$txt" > "$SCEN_DIR/messages.txt"
  # WORDS_BAD on every line; WORDS_LONG only on lines that are not machine JSON structure.
  bad=$(grep -E -e "$WORDS_BAD" "$SCEN_DIR/messages.txt")
  badlong=$(grep -Ev "$WORDS_JSON" "$SCEN_DIR/messages.txt" | grep -E "$WORDS_LONG")
  bad=$(printf '%s\n%s\n' "$bad" "$badlong" | grep -v -F -e "${SID:-@@}" -e "${CHANNEL:-@@}" -e "${NODE_ID:-@@}" | grep -E . | head -3)
  if [ -z "$bad" ]; then result words PASS "$(grep -c . "$SCEN_DIR/messages.txt" || true) messages"
  else result words FAIL "$(head -1 <<<"$bad")"; fi
}

words_selftest() {
  local n=0 bad=0
  # w_ <name> <expect PASS|FAIL> <one line of CLI output>
  w_() {
    local name=$1 want=$2 line=$3 got
    SCEN_DIR=$OUT/selftest/words-$name; mkdir -p "$SCEN_DIR"
    eval "plat_cli_outputs() { printf '%s\n' \"\$W_LINE\"; }"; W_LINE=$line
    SCENARIO_FAILED=0; SCENARIO=$name; SID=''; CHANNEL=''; NODE_ID=''
    words_stop >/dev/null 2>&1
    got=$([ "$SCENARIO_FAILED" = 1 ] && echo FAIL || echo PASS)
    n=$((n + 1)); if [ "$got" = "$want" ]; then echo "ok   words/$name: $got"; else echo "MISSED words/$name: got $got, wanted $want"; bad=$((bad + 1)); fi
  }
  # the original planted raw error: still caught
  w_ raw-rpc-error FAIL 'Could not connect: rpc error: code = Unavailable desc = x'
  # TLX2 S2 deb12 daemon_term/hy2: a machine JSON line carrying a channel id (not matching $CHANNEL) is NOT user
  # text -> PASS (the false positive). Leading spaces + quoted key are the JSON-structure tell.
  w_ json-channel-id PASS '      "channel": "CVegWkrRHK5Td5jNgK8s2VABVRxUJoKWQjdrbfpqDmKage": {'
  # fixture value: a synthetic 46-char base58 string ("FAKE" + the base58 alphabet) - NOT a real key; it is 45+
  # chars so WORDS_LONG would fire in prose, proving the JSON-structure exclusion (not a short value) is what makes
  # this line PASS. 46 chars also keeps it clear of the repo secret-scan's 43-44 base58 rule.
  w_ json-id-value   PASS '  "id": "FAKE123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghi",'
  # honesty preserved: the SAME long key dumped into user PROSE (no JSON structure) is still a FAIL.
  w_ prose-raw-key   FAIL 'Connected on channel CVegWkrRHK5Td5jNgK8s2VABVRxUJoKWQjdrbfpqDmKage now.'
  # honesty preserved: a wrapped Go error INSIDE a JSON line still fails (WORDS_BAD applies to JSON too).
  w_ json-with-goerr FAIL '  "error": "rpc error: code = Unavailable desc = dial tcp",'
  [ "$bad" = 0 ] && echo "words selftest: all $n cases as expected" || echo "words selftest: $bad of $n miss(es)"
}

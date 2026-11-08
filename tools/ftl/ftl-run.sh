#!/usr/bin/env bash
# ─── Real-phone gate: Firebase Test Lab (Android), one instrumented end-to-end test per device ───
# Runs a prebuilt arm64-only debug APK + its instrumented test APK (RealDeviceTest: setup, every protocol
# connect / exit IP = node / still protected after a speed test / disconnect, kill switch persist with dvpnd
# killed, money) on real phones, then pulls each device's report and logcat from the results bucket.
#
# Usage: bash ftl-run.sh <throwaway-wallet-key.json> [model,version ...]
#   default devices: akita,35 (Pixel 8a, Android 15) and SC-51E,36 (Galaxy S24, Android 16)
#
# Required environment (nothing is baked in):
#   FTL_PROJECT          GCP project that runs the matrices (Testing + Tool Results APIs on, billing on)
#   FTL_ACCOUNT          gcloud account to run as (a service account; never the machine's default config)
#   FTL_APK, FTL_TEST    the APK pair: a local path or host:path (scp), e.g. the build's EXTRA=ftl output
#   FTL_NODES_FILE       env file with FTL_NODE_IP and FTL_NODES (see nodes.example.env); keep it out of git
# Optional:
#   FTL_BILLING_PROJECT  quota/billing project, when the account's home project differs from FTL_PROJECT
#   FTL_RESULTS_BUCKET   results bucket (gs://name or name) in FTL_PROJECT; needed with a foreign account
#   FTL_PROTOCOLS        e.g. amneziawg,xray: only those protocols
#   FTL_TIMEOUT          per device, default 40m (keep device minutes low)
#   FTL_PKG              app id, default network.sentinel.devnetdvpn
# The wallet key travels as a test environment variable: use a devnet throwaway key only (it is visible in the
# Test Lab console). Results: ./ftl-results/<UTC stamp>/.
set -euo pipefail
# Git Bash would rewrite /sdcard/… into a Windows path (only that prefix; gcloud needs the rest).
export MSYS2_ARG_CONV_EXCL=/sdcard
KEY=${1:?throwaway wallet key file}
shift
DEVICES=("$@"); [ ${#DEVICES[@]} -eq 0 ] && DEVICES=(akita,35 SC-51E,36)
: "${FTL_PROJECT:?set FTL_PROJECT}" "${FTL_ACCOUNT:?set FTL_ACCOUNT}"
: "${FTL_APK:?set FTL_APK}" "${FTL_TEST:?set FTL_TEST}" "${FTL_NODES_FILE:?set FTL_NODES_FILE}"
PKG=${FTL_PKG:-network.sentinel.devnetdvpn}
ACCT=(--account "$FTL_ACCOUNT" --project "$FTL_PROJECT")
[ -n "${FTL_BILLING_PROJECT:-}" ] && ACCT+=(--billing-project "$FTL_BILLING_PROJECT")
STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT=${FTL_OUT:-$PWD/ftl-results}/$STAMP
mkdir -p "$OUT"

# ─── The APK pair ───
echo "using $FTL_APK + $FTL_TEST"
scp -q "$FTL_APK" "$OUT/app-arm64.apk" && scp -q "$FTL_TEST" "$OUT/test.apk"
unzip -l "$OUT/app-arm64.apk" | grep -q 'lib/x86_64/' && { echo "the APK still has x86_64 (build the arm64-only pair)"; exit 1; }
sha256sum "$OUT/app-arm64.apk" "$OUT/test.apk"

# ─── Nodes ───
# shellcheck disable=SC1090
. "$FTL_NODES_FILE"
: "${FTL_NODE_IP:?FTL_NODES_FILE must set FTL_NODE_IP}" "${FTL_NODES:?FTL_NODES_FILE must set FTL_NODES}"

# ─── Run ───
DEV_ARGS=()
for d in "${DEVICES[@]}"; do DEV_ARGS+=(--device "model=${d%,*},version=${d#*,},locale=en,orientation=portrait"); done
KEY_B64=$(base64 -w0 < "$KEY")
BUCKET_ARGS=()
[ -n "${FTL_RESULTS_BUCKET:-}" ] && BUCKET_ARGS=(--results-bucket "${FTL_RESULTS_BUCKET#gs://}")
gcloud firebase test android run "${ACCT[@]}" \
  --type instrumentation \
  --app "$OUT/app-arm64.apk" --test "$OUT/test.apk" \
  --test-targets "class $PKG.RealDeviceTest" \
  "${DEV_ARGS[@]}" \
  "${BUCKET_ARGS[@]}" \
  --environment-variables "^;^ftlKey=$KEY_B64;ftlNodeIp=$FTL_NODE_IP;ftlNodes=$FTL_NODES${FTL_PROTOCOLS:+;ftlProtocols=$FTL_PROTOCOLS}" \
  --directories-to-pull "/sdcard/Android/data/$PKG/files" \
  --timeout "${FTL_TIMEOUT:-40m}" \
  --record-video \
  --results-dir "ftl/$STAMP" \
  --format=json > "$OUT/outcome.json" 2> "$OUT/gcloud.log" || true
tail -5 "$OUT/gcloud.log"

# ─── Pull each device's report and logcat from the results bucket ───
# gcloud prints https://console.developers.google.com/storage/browser/<bucket>/<dir>/
BUCKET=${FTL_RESULTS_BUCKET:+gs://${FTL_RESULTS_BUCKET#gs://}/}
[ -n "$BUCKET" ] || BUCKET=$(grep -oE 'storage/browser/[^/]+/' "$OUT/gcloud.log" | head -1 | sed 's|storage/browser/|gs://|')
if [ -n "$BUCKET" ]; then
  mkdir -p "$OUT/bucket"
  gcloud storage cp -r "${BUCKET}ftl/$STAMP" "$OUT/bucket" "${ACCT[@]}" > "$OUT/copy.log" 2>&1 \
    || echo "(could not copy results from $BUCKET; see copy.log)"
  # bucket/<stamp>/<model>-<version>-<locale>-<orientation>/artifacts/…/ftl-report.txt
  find "$OUT/bucket" -name ftl-report.txt | while read -r r; do
    dev=$(printf '%s' "${r#"$OUT/bucket/"}" | cut -d/ -f2)
    cp "$r" "$OUT/$dev-report.txt"
    [ -d "$(dirname "$r")/logs" ] && { mkdir -p "$OUT/$dev-logs"; cp "$(dirname "$r")"/logs/* "$OUT/$dev-logs/"; }
    echo "── $dev"; cat "$OUT/$dev-report.txt"
  done
fi
cat "$OUT/outcome.json"

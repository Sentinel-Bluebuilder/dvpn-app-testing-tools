# Firebase Test Lab: the Android real-phone gate

`ftl-run.sh` runs the Android app's instrumented end-to-end test (`RealDeviceTest`) on real phones in Firebase
Test Lab. By default it uses one Pixel 8a (Android 15) and one Galaxy S24 (Android 16).

Per phone, the test checks:
- **setup:** the app's exec hook answers, the CLI runs in the phone's Node, the protocol programs are present, daemon
  init, on-chain device setup, and doctor shows no FAIL;
- **every protocol** (WireGuard, AmneziaWG, OpenVPN, V2Ray, Xray, Hysteria2): connect, the exit IP is the node's, still
  protected 20 s after a speed test, disconnect, and the exit IP goes back to direct;
- **kill switch (persist):** connect with it on, kill dvpnd, no direct internet in the next 10 s, still blocked after
  dvpnd is back, then Restore network brings the internet back;
- **money:** for every deposit, spent ≤ signed ≤ deposit, then a settle run closes them.

## Run
1. Build the arm64-only debug APK and its instrumented test APK (the Android build's `EXTRA=ftl` output).
2. Copy `nodes.example.env` to `nodes.env` and fill in the node IP and one node address per protocol.
3. Make a fresh devnet throwaway wallet and fund it with a little SOL and tDVPN. Never use a real key: the key
   travels as a test environment variable and shows in the Test Lab console.
4. Run:
   ```bash
   FTL_PROJECT=<project> FTL_ACCOUNT=<service account> \
   FTL_BILLING_PROJECT=<project> FTL_RESULTS_BUCKET=<bucket> \
   FTL_APK=<host:path or path>/app-ftl-arm64.apk FTL_TEST=<host:path or path>/app-ftl-test.apk \
   FTL_NODES_FILE=./nodes.env FTL_TIMEOUT=25m \
   bash ftl-run.sh <throwaway-key.json>
   ```
   Set `FTL_BILLING_PROJECT` and `FTL_RESULTS_BUCKET` when the service account's home project is not `FTL_PROJECT`;
   without them gcloud bills, and looks for the default bucket, in the account's home project.

## Read the results
`ftl-results/<stamp>/` holds `outcome.json` (Passed/Failed per device), the gcloud log, and per device the
`ftl-report.txt` and logs pulled from the bucket. The per-row lines are also in logcat under the tag `ddv-ftl`:
`PASS …` / `FAIL …`, plus one speed line per protocol.

Warning-level `ddv-ftl` stack traces from `LocalSocket.connect` are expected. The test polls the app's exec hook once
a second, for up to 90 s, while the VPN service starts. That wait has its own PASS/FAIL row, so it can never pass
silently.

## Cost
Keep device minutes low: one run is 2 devices × about 15–20 min. Lower `FTL_TIMEOUT` to cap a hung run.

#!/bin/bash
# ─── fleet-watch ───
# Read-only fleet watchdog: stale agent heartbeats, running VMs with their 1-min load, VMs nobody claims,
# and the last RPC failover line. It never stops or changes anything; the director acts on the output.
#
# Settings (env):
#   HEARTBEAT_FILE   heartbeat board, one line per update: "<ROLE> <ISO-UTC> <state> | next: ... | eta: ..."
#   BOARD_FILE       VM claim board; a VM whose name is absent is flagged UNCLAIMED
#   SSH_KEY          ssh private key path for the VMs and the controller
#   STALE_MIN        minutes before a heartbeat is STALE (default 45)
#   IDLE_LOAD        load1 below this is IDLE (default 0.15)
#   GCP_PROJECT      GCP project holding the fleet VMs (optional)
#   GCP_ACCOUNT      gcloud account to list them with (optional)
#   CTL_HOST         controller ssh target, user@host (optional; used for Azure, the load relay and the RPC log)
#   SSH_USER         VM login user (default ubuntu)
#   AZ_CONFIG_DIR    Azure CLI config dir on the controller (optional)
#   AZ_BIN           az binary on the controller (default az)
#   RPC_LOG          rpc-failover log path on the controller (default ~/rpc-failover.log)
set -u
: "${HEARTBEAT_FILE:?set HEARTBEAT_FILE}" "${BOARD_FILE:?set BOARD_FILE}" "${SSH_KEY:?set SSH_KEY}"
STALE_MIN="${STALE_MIN:-45}"
IDLE_LOAD="${IDLE_LOAD:-0.15}"
SSH_USER="${SSH_USER:-ubuntu}"
AZ_BIN="${AZ_BIN:-az}"
RPC_LOG="${RPC_LOG:-~/rpc-failover.log}"
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=8 -i "$SSH_KEY")
now=$(date -u +%s)

echo "== fleet-watch $(date -u +%FT%TZ)"

# ─── Heartbeats (latest line per role wins) ───
echo "-- heartbeats (stale > ${STALE_MIN} min marked STALE)"
if [ -f "$HEARTBEAT_FILE" ]; then
  awk '/^[A-Z0-9#]+ [0-9]{4}-[0-9]{2}-[0-9]{2}T/ {last[$1]=$0} END {for (r in last) print last[r]}' "$HEARTBEAT_FILE" | sort |
  while read -r role ts rest; do
    t=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
    age=$(( (now - t) / 60 ))
    flag=ok; [ "$age" -gt "$STALE_MIN" ] && flag=STALE
    printf '%-6s %-5s %4s min  %s\n' "$role" "$flag" "$age" "$(echo "$rest" | cut -c1-110)"
  done
else
  echo "no heartbeat file at $HEARTBEAT_FILE"
fi

# ─── VMs ───
echo "-- running VMs (IDLE = load1 < ${IDLE_LOAD})"
AZ_QUERY="[?powerState=='VM running'].[name,location,publicIps]"
{
  if [ -n "${GCP_PROJECT:-}" ]; then
    gcloud compute instances list --project "$GCP_PROJECT" ${GCP_ACCOUNT:+--account "$GCP_ACCOUNT"} --filter=status=RUNNING \
      --format='value(name,zone.basename(),networkInterfaces[0].accessConfigs[0].natIP)' 2>&1 | sed 's/^/gcp /'
  fi
  if [ -n "${CTL_HOST:-}" ] && [ -n "${AZ_CONFIG_DIR:-}" ]; then
    ssh "${SSH_OPTS[@]}" "$CTL_HOST" "AZURE_CONFIG_DIR=$AZ_CONFIG_DIR $AZ_BIN vm list -d --query \"$AZ_QUERY\" -o tsv 2>&1" | sed 's/^/az /'
  fi
} | while read -r cloud name zone ip; do
  load="?"
  if [ -n "${ip:-}" ]; then
    # Direct first; then through the controller, whose ssh config knows hosts this machine can't reach.
    load=$(timeout 15 ssh "${SSH_OPTS[@]}" -o StrictHostKeyChecking=accept-new "$SSH_USER@$ip" 'cut -d" " -f1 /proc/loadavg' 2>/dev/null)
    if [ -z "$load" ] && [ -n "${CTL_HOST:-}" ]; then
      relay="for h in $name $ip; do o=\$(timeout 10 ssh -n -o BatchMode=yes -o ConnectTimeout=6 \$h cat /proc/loadavg 2>/dev/null) && [ -n \"\$o\" ] && { echo \"\${o%% *}\"; break; }; done"
      load=$(timeout 30 ssh "${SSH_OPTS[@]}" "$CTL_HOST" "$relay" 2>/dev/null)
    fi
    [ -z "$load" ] && load="?"
  fi
  idle=""
  case "$load" in ''|'?') ;; *) awk -v l="$load" -v m="$IDLE_LOAD" 'BEGIN{exit !(l<m)}' && idle=IDLE ;; esac
  owner=""
  awk -v n="$name" 'index($0,n){f=1} END{exit !f}' "$BOARD_FILE" 2>/dev/null || owner=UNCLAIMED
  printf '%-4s %-28s %-16s load1=%-5s %s %s\n' "$cloud" "$name" "$zone" "$load" "$idle" "$owner"
done

# ─── RPC lanes (SWITCHED = act: nodes read their RPC only at start) ───
if [ -n "${CTL_HOST:-}" ]; then
  echo "-- rpc lanes (last failover line; SWITCHED = act)"
  ssh "${SSH_OPTS[@]}" "$CTL_HOST" "tail -n 1 $RPC_LOG; grep -h SWITCHED $RPC_LOG | tail -n 3" 2>&1
fi
echo "== end"

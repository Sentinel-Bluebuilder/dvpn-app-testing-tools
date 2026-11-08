#!/usr/bin/env bash
# ─── Host side of plat/mac.sh's faults (FMC, 2026-11-07). Run ON the GCP Mac host for the whole matrix run. ───
# The guest holds no credential for the host, so the host reads the guest's fault requests over its own ssh to the
# guest, runs ddv-faultctl, and writes the ack back. Only two verbs pass, with validated args:
#   <n> block <ipv4> <1..600>      ddv-faultctl block (self-undoing, as always)
#   <n> clear                      ddv-faultctl clear
# Anything else is acked rc=2 and not run.
# Usage (on the host): bash mac-host-relay.sh [guest-ssh-target]     default target: ddv-mac (ssh config name)
# Stop it with Ctrl-C or kill; on exit it clears every fault.
set -u
GUEST=${1:-ddv-mac}
REQ=${FAULT_REQ:-/tmp/cbm-fault.req}
ACK=${FAULT_ACK:-/tmp/cbm-fault.ack}
FAULTCTL=${FAULTCTL:-/usr/local/sbin/ddv-faultctl}

trap 'sudo -n "$FAULTCTL" clear >/dev/null 2>&1; exit 0' INT TERM EXIT
ssh -o BatchMode=yes "$GUEST" "touch '$REQ'; tail -n 0 -F '$REQ'" | while read -r n verb a b rest; do
  [[ "$n" =~ ^[0-9]{1,6}$ ]] || continue
  rc=2
  case $verb in
    block)
      if [[ "$a" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ "$b" =~ ^[0-9]{1,3}$ ]] && [ -z "$rest" ]; then
        sudo -n "$FAULTCTL" block "$a" "$b"; rc=$?
      fi ;;
    clear)
      [ -z "$a" ] && { sudo -n "$FAULTCTL" clear; rc=$?; } ;;
  esac
  echo "$(date -u +%T) relay: $n $verb $a $b -> rc=$rc" >&2
  ssh -o BatchMode=yes "$GUEST" "echo '$n rc=$rc' >> '$ACK'" < /dev/null
done

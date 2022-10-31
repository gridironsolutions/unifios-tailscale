#!/usr/bin/env bash
set -e

#run: package.sh <source> <destination>

TMP="$(mktemp -d || exit 1)"
trap 'rm -rf ${TMP}' EXIT

mkdir -p "${TMP}/unifios-tailscale"
cp "${1}/ip-rule-monitor.sh" "${TMP}/unifios-tailscale/ip-rule-monitor.sh"
cp "${1}/10-unifios-tailscale.sh" "${TMP}/unifios-tailscale/10-unifios-tailscale.sh"
cp "${1}/unifios-tailscale.sh" "${TMP}/unifios-tailscale/unifios-tailscale.sh"
cp "${1}/wan-failover-monitor.sh" "${TMP}/unifios-tailscale/wan-failover-monitor.sh"
cp "${1}/.env.sample" "${TMP}/unifios-tailscale/.env.sample"

mkdir -p "${2}"
tar czf "${2}/unifios-tailscale.tgz" -C "${TMP}" unifios-tailscale
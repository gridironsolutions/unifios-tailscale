#!/bin/sh
set -e

UNIFIOS_TAILSCALE_ROOT="/mnt/data/unifios-tailscale"

${UNIFIOS_TAILSCALE_ROOT}/unifios-tailscale.sh autostart

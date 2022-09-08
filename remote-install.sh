#!/bin/sh
set -e

# Determine the latest version of the Tailscale UDM package
LATEST_VERSION="${1:-$(curl -sSLq --ipv4 'https://api.github.com/repos/gridironsolutions/unifios-tailscale/releases' | jq -r '.[0].tag_name')}"

# Setup a temporary directory to download the package
TMP="$(mktemp -d || exit 1)"
trap 'rm -rf ${TMP}' EXIT

# Download the Tailscale-UDM package
curl -sSLf --ipv4 -o "${TMP}/tailscale.tgz" "https://github.com/gridironsolutions/unifios-tailscale/releases/download/${LATEST_VERSION}/unifios-tailscale.tgz"

# Extract the package
tar xzf "${TMP}/unifios-tailscale.tgz" -C "/mnt/data/"

# Run the setup script to ensure that Tailscale is installed
/mnt/data/unifios-tailscale/unifios-tailscale.sh install

# Start the tailscaled daemon
/mnt/data/unifios-tailscale/unifios-tailscale.sh start
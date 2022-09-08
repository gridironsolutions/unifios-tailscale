#!/bin/sh
set -e

#get the latest available version number of unifios-tailscale
LATEST_VERSION="${1:-$(curl -sSLq --ipv4 'https://api.github.com/repos/gridironsolutions/unifios-tailscale/releases' | jq -r '.[0].tag_name')}"

#create temporary directory
TMP="$(mktemp -d || exit 1)"

#delete temporary directory when finished
trap 'rm -rf ${TMP}' EXIT

#download the unifios-tailscale tarball
curl -sSLf --ipv4 -o "${TMP}/unifios-tailscale.tgz" "https://github.com/gridironsolutions/unifios-tailscale/releases/download/${LATEST_VERSION}/unifios-tailscale.tgz"

#extract the unifios-tailscale tarball
tar xzf "${TMP}/unifios-tailscale.tgz" -C "/mnt/data/"

#ensure root owns unifios-tailscale
chown -R root:root /mnt/data/unifios-tailscale

#make .sh files executable
chmod +x /mnt/data/unifios-tailscale/*.sh

#install tailscale
/mnt/data/unifios-tailscale/unifios-tailscale.sh install

#start unifios-tailscale
/mnt/data/unifios-tailscale/unifios-tailscale.sh start
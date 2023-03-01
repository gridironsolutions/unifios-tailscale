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

OS_VERSION="$(ubnt-device-info firmware_detail | grep -oE '^[0-9]+')"

#detect major firmware version
if [ "$OS_VERSION" = '1' ]
then
    #PERSISTENT_ROOT="/mnt/data"
    echo "This script is not compatible with this router's firmware."
    exit 1
else
    PERSISTENT_ROOT="/data"
fi

#create unifios-tailscale root directory
UNIFIOS_TAILSCALE_ROOT="${UNIFIOS_TAILSCALE_ROOT:-${PERSISTENT_ROOT}/unifios-tailscale}"
mkdir -p "${UNIFIOS_TAILSCALE_ROOT}"

#extract the unifios-tailscale tarball
tar xzf "${TMP}/unifios-tailscale.tgz" -C "${PERSISTENT_ROOT}"

#create .env from .env.sample if it doesn't exist
if [ -e "${UNIFIOS_TAILSCALE_ROOT}/.env.sample" ]
then
    cp -n "${UNIFIOS_TAILSCALE_ROOT}/.env.sample" "${UNIFIOS_TAILSCALE_ROOT}/.env"
fi

#ensure root owns unifios-tailscale
chown -R root:root "${UNIFIOS_TAILSCALE_ROOT}"

#make .sh files executable
chmod +x "${UNIFIOS_TAILSCALE_ROOT}/"*.sh

#install tailscale
"${UNIFIOS_TAILSCALE_ROOT}/unifios-tailscale.sh" install

#start unifios-tailscale
"${UNIFIOS_TAILSCALE_ROOT}/unifios-tailscale.sh" start
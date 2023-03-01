#!/usr/bin/env bash

SCRIPT_NAME=${0}
COMMAND=${1}
SELECTED_VERSION=${2:-"-1"}
PERSISTENT_ROOT="/data"
IP_RULE_MONITOR_PID_FILE="/run/ip-rule-monitor.pid"
WAN_FAILOVER_MONITOR_PID_FILE="/run/wan-failover-monitor.pid"
UNIFIOS_TAILSCALE_ROOT="${UNIFIOS_TAILSCALE_ROOT:-${PERSISTENT_ROOT}/unifios-tailscale}"
TAILSCALE="/usr/bin/tailscale"
TAILSCALED="/usr/sbin/tailscaled"
TAILSCALED_SOCK="${TAILSCALED_SOCK:-/var/run/tailscale/tailscaled.sock}"
TAILSCALED_LOG_FILE="${UNIFIOS_TAILSCALE_ROOT}/tailscaled.log"
. "${UNIFIOS_TAILSCALE_ROOT}/.env"
SUBNETS=$(ip route | grep br | cut -d ' ' -f 1 | tr '\n' ',' | rev | cut -c2- | rev)
DEFAULT_TAILSCALE_FLAGS="--advertise-exit-node --advertise-routes=${SUBNETS} --snat-subnet-routes=false --accept-routes --reset"
TAILSCALE_FLAGS="${TAILSCALE_FLAGS:-${DEFAULT_TAILSCALE_FLAGS}}"

install_tailscale() {
    echo "Installing unifios-tailscale..."

    #get latest Tailscale version number
    ARG1=${1}
    if [ "x${1}" = "x-1" ]
    then
        unset ARG1
    fi
    TAILSCALE_VERSION="${ARG1:-$(curl -sSLq --ipv4 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.Tarballs.arm64 | capture("tailscale_(?<version>[^_]+)_").version')}"

    #install Tailscale package repository
    if [ ! -f "/etc/apt/sources.list.d/tailscale.list" ]; then
        # shellcheck source=tests/os-release
        . /etc/os-release

        echo "Installing Tailscale package repository."
        curl -fsSL --ipv4 "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.gpg" | apt-key add -
        curl -fsSL --ipv4 "https://pkgs.tailscale.com/stable/${ID}/${VERSION_CODENAME}.list" | tee /etc/apt/sources.list.d/tailscale.list
    fi

    #update package lists
    echo "Updating package lists."
    apt update

    #install Tailscale
    echo "Installing Tailscale ${TAILSCALE_VERSION}."
    apt install -y tailscale="${TAILSCALE_VERSION}"

    #configure Tailscale
    echo "Configuring Tailscale."
    sed -i 's/FLAGS=""/FLAGS="--port 41641 --socket \/var\/run\/tailscale\/tailscaled.sock --state \/data\/unifios-tailscale\/tailscaled.state"/' /etc/default/tailscaled || {
        echo "Failed to configure Tailscale."
        echo "Check that the file /etc/default/tailscaled exists and contains the line FLAGS=\"--port 41641 --socket /var/run/tailscale/tailscaled.sock --state /data/unifios-tailscale/tailscaled.state\"."
        exit 1
    }

    #restart Tailscale daemon to detect new configuration
    stop_unifios_tailscale
    start_unifios_tailscale

    #enable Tailscale to start automatically during system startup
    echo "Enabling Tailscale to start automatically during system startup."
    systemctl enable tailscaled || {
        echo "Failed to enable Tailscale to start automatically during system startup."
        echo "You can enable it manually using 'systemctl enable tailscaled'."
        exit 1
    }

    #notify user that installation is complete
    echo "Installation of unifios-tailscale is complete."
}

tailscale_is_running() {
    systemctl is-active --quiet tailscaled
}

start_unifios_tailscale() {
    echo "Starting unifios-tailscale..."

    #link logrotate configuration file to /etc/logrotate.d
    if [ ! -e /etc/logrotate.d/tailscale_logrotate ]
    then
        ln -s ${UNIFIOS_TAILSCALE_ROOT}/tailscale_logrotate.conf /etc/logrotate.d/tailscale_logrotate || true
    fi

    #start script that monitors changes to ip rules and marks all Tailscale packets
    ${UNIFIOS_TAILSCALE_ROOT}/ip-rule-monitor.sh > /dev/null 2>&1 &

    #save the process id of ip-rule-monitor.sh to a file so that this script can stop it at a later time
    echo ${!} > "${IP_RULE_MONITOR_PID_FILE}"

    #start script that notifies of failover events
    ${UNIFIOS_TAILSCALE_ROOT}/wan-failover-monitor.sh > /dev/null 2>&1 &

    #save the process id of wan-failover-monitor.sh to a file so that this script can stop it at a later time
    echo ${!} > "${WAN_FAILOVER_MONITOR_PID_FILE}"

    #add local networks to tailscale routing table to avoid traffic being wrongly sent over tailscale0
    ROUTES_TO_ADD=$( ip route | grep "dev br" )
    echo "${ROUTES_TO_ADD}" | while read -r route; do /sbin/ip route add ${route} table 52; done

    #launch tailscaled
    systemctl start tailscaled

    # Wait a few seconds for the daemon to start
    sleep 5

    if tailscale_is_running; then
        echo "Tailscaled started successfully."
    else
        echo "Tailscaled failed to start."
        exit 1
    fi

    # Run tailscale up to configure
    echo "Running tailscale up to configure interface..."
    # shellcheck disable=SC2086
    timeout 5 ${TAILSCALE} --socket ${TAILSCALED_SOCK} up $TAILSCALE_FLAGS

    echo "unifios-tailscale started successfully."
}

stop_unifios_tailscale() {
    echo "Stopping unifios-tailscale..."

    #stop tailscaled
    systemctl stop tailscaled

    #get the process id of ip-rule-monitor.sh
    if [ -e "${IP_RULE_MONITOR_PID_FILE}" ]
    then
        read IP_RULE_MONITOR_PID < "${IP_RULE_MONITOR_PID_FILE}"
    fi

    #get the process id of wan-failover-monitor.sh
    if [ -e "${WAN_FAILOVER_MONITOR_PID_FILE}" ]
    then
        read WAN_FAILOVER_MONITOR_PID < "${WAN_FAILOVER_MONITOR_PID_FILE}"
    fi

    #kill ip-rule-monitor.sh
    pkill -f "ip-rule-monitor.sh" || true

    #kill wan-failover-monitor.sh
    pkill -f "wan-failover-monitor.sh" || true

    #delete ip-rule-monitor.sh process id file
    rm -f ${IP_RULE_MONITOR_PID_FILE}

    #delete wan-failover-monitor.sh process id file
    rm -f ${WAN_FAILOVER_MONITOR_PID_FILE}

    #remove local network routes by flushing the route table used by Tailscale
    /sbin/ip route flush table 52

    echo "unifios-tailscale is stopped."
}

tailscale_status() {
    if tailscale_is_running; then
        echo "unifios-tailscale is running."
        ${TAILSCALE} --version

        return 0
    else
        echo "unifios-tailscale is not running."

        return 1
    fi
}

tailscale_upgrade_available() {
    #get the version number of the currently installed Tailscale
    CURRENT_VERSION="$(${TAILSCALE} --version | head -n 1)"

    #use this function's first agrument to get the version number or get the most recently available version of Tailscale
    ARG1="${1}"
    if [ "x${1}" = "x-1" ]
    then
        unset ARG1
    fi
    TARGET_TAILSCALE_VERSION="${ARG1:-$(curl -sSLq --ipv4 'https://pkgs.tailscale.com/stable/?mode=json' | jq -r '.Tarballs.arm64 | capture("tailscale_(?<version>[^_]+)_").version')}"
    
    if [ "${CURRENT_VERSION}" != "${TARGET_TAILSCALE_VERSION}" ] || [ "x${3}" = "xIGNOREVERSION" ]
    then
        echo "TRUE"
    else
        echo "FALSE"
    fi
}

upgrade_tailscale() {
    # if [ $(tailscale_upgrade_available "${1}" "${3}") ]
    TAILSCALE_UPGRADE_AVAILABLE=$( tailscale_upgrade_available "${1}" "${2}" "${3}" )
    if [ "x${TAILSCALE_UPGRADE_AVAILABLE}" = "xTRUE" ]
    then
        if [ -e "${TAILSCALED_SOCK}" ] && [ "x${2}" != "xFORCERESTART" ]
        then
            echo "Upgrade has been aborted because unifios-tailscale is running. If you want to restart it during an upgrade, run '${SCRIPT_NAME} upgrade!'."

            exit 1
        fi

        install_tailscale "${1}" "RESTART"
    else
        echo "Tailscale is already up to date."
    fi
}

uninstall_tailscale() {
    echo "Removing unifios-tailscale..."

    #disable Tailscale from starting automatically during system startup
    echo "Disabling Tailscale from starting automatically during system startup."
    systemctl disable tailscaled || {
        echo "Failed to disable Tailscale from starting automatically during system startup."
        echo "You can disable it manually using 'systemctl disable tailscaled'."
        exit 1
    }

    #remove tailscale package
    apt remove -y tailscale
    rm -f /etc/apt/sources.list.d/tailscale.list || true

    #remove unifios-tailscale installation directory
    rm -rf ${UNIFIOS_TAILSCALE_ROOT}

    echo "Uninstallation of unifios-tailscale is complete."
}



case ${COMMAND} in
    "status")
        tailscale_status
        ;;
    "start")
        start_unifios_tailscale
        ;;
    "stop")
        stop_unifios_tailscale
        ;;
    "restart")
        stop_unifios_tailscale
        start_unifios_tailscale
        ;;
    "install")
        if [ -e "${TAILSCALE}" ]
        then
            echo "unifios-tailscale is already installed. Run '${SCRIPT_NAME} upgrade' to upgrade it."

            exit 0
        fi

        install_tailscale "${SELECTED_VERSION}"
        ;;
    "upgrade")
        upgrade_tailscale "${SELECTED_VERSION}"
        ;;
    "upgrade!")
        upgrade_tailscale "${SELECTED_VERSION}" "FORCERESTART"
        ;;
    "forceupgrade")
        upgrade_tailscale "${SELECTED_VERSION}" "FORCERESTART" "IGNOREVERSION"
        ;;
    "uninstall")
        stop_unifios_tailscale
        uninstall_tailscale
        ;;
    "autostart")
        . "${UNIFIOS_TAILSCALE_ROOT}/.env"

        if [ "${AUTOMATICALLY_UPGRADE_TAILSCALE}" = "true" ]; then
            tailscale_upgrade_available && upgrade_tailscale || echo "unifios-tailscale was not upgraded."
        fi

        start_unifios_tailscale
        ;;
    *)
        echo "Usage: ${SCRIPT_NAME} {status|start|stop|restart|install|uninstall|upgrade|upgrade!|forceupgrade|autostart}"
        exit 1
        ;;
esac

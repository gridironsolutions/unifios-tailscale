#!/usr/bin/env /bin/sh

PERSISTENT_ROOT="/mnt/data"
UNIFIOS_TAILSCALE_ROOT="${UNIFIOS_TAILSCALE_ROOT:-${PERSISTENT_ROOT}/unifios-tailscale}"
. "${UNIFIOS_TAILSCALE_ROOT}/.env"
COOKIE=$(mktemp)
FAILOVER_LOG_SOURCE="/var/log/messages"
FAILOVER_LOG="/mnt/data/log/wan_failover"
EMAIL_CREDENTIALS="${MAIL_USERNAME}:${MAIL_PASSWORD}"

log() {
    TIMESTAMP=$( date '+%x %X %Z%t' )
    echo "${TIMESTAMP} ${2}" >> "${1}"
}

fetch_unifios() {
    BASEURL="https://${HOST}"
    curl --silent --insecure -H "Content-Type: application/json" "${BASEURL}/${1}"
}

fetch_network() {
    BASEURL="https://${HOST}/proxy/network"
    curl --silent --cookie ${COOKIE} --cookie-jar ${COOKIE} --insecure "${BASEURL}/${1}"
}

login_to_network() {
    curl --silent --cookie ${COOKIE} --cookie-jar ${COOKIE} --insecure -H "Content-Type: application/json" --data "{\"username\":\"$API_USERNAME\", \"password\":\"$API_PASSWORD\", \"rememberMe\":false, \"token\":\"\"}" "https://${HOST}/api/auth/login" -o /dev/null
}

logout_of_network() {
    curl --silent --cookie ${COOKIE} --cookie-jar ${COOKIE} --insecure "https://${HOST}/logout" -o /dev/null
}

get_active_wan_interface() {
    ( tail -F -n0 "${FAILOVER_LOG_SOURCE}" & ) | grep -m1 "wan-failover-groups" | sed 's/^.*WAN Failover Groups is using //' | cut -d ' ' -f 1
}

get_active_wan_ip() {
    curl --silent https://checkip.amazonaws.com --max-time 5 || echo "UNKNOWN"
}

get_mac_address() {
    API_SYSTEM=$( fetch_unifios "api/system" )
    MAC=$(echo ${API_SYSTEM} | jq -r ".mac" )
    echo "${MAC}"
}

get_device_status() {
    # echo "getting device status for ${1}"
    echo $( fetch_network "api/s/default/stat/device/${1}" )
}

refresh_wan_details() {
    DEVICE_STATUS="$( get_device_status $( get_mac_address ) )"
    if [ "${DEVICE_STATUS}" == "Unauthorized" ]
    then
        logout_of_network
        login_to_network
        DEVICE_STATUS="$( get_device_status $( get_mac_address ) )"
    fi
    LOCATION_ID=$( echo "${DEVICE_STATUS}" | jq -r ".data[0].lan_ip" | cut -d '.' -f 3 )
    WAN1=$( echo "${DEVICE_STATUS}" | jq -r ".data[0].wan1" )
    WAN2=$( echo "${DEVICE_STATUS}" | jq -r ".data[0].wan2" )
    PRIMARY_WAN_INTERFACE=$( echo "${WAN1}" | jq -r ".ifname" )
    SECONDARY_WAN_INTERFACE=$( echo "${WAN2}" | jq -r ".ifname" )
    PRIMARY_WAN_INTERFACE_IS_UPLINK=$( echo "${WAN1}" | jq -r ".is_uplink" )
    SECONDARY_WAN_INTERFACE_IS_UPLINK=$( echo "${WAN2}" | jq -r ".is_uplink" )
}

email() {
    EMAIL_DATE=$( date "+%a, %-d %b %Y %T %z" )
    SMTP_BODY=$( cat <<END_HEREDOC
From: UniFi Failover Monitor <${MAIL_FROM}>
To: <${1}>
Subject: ${2}
Date: ${EMAIL_DATE}
END_HEREDOC
    )
    SMTP_BODY=$( printf "${SMTP_BODY}\n\n${3}\n" )

    #send email via Amazon SES
    echo "${SMTP_BODY}" | curl --silent --ssl-reqd smtp://email-smtp.us-east-1.amazonaws.com --mail-from "${MAIL_FROM}" --mail-rcpt "${1}" --mail-rcpt "${MAIL_BCC_TO}" --upload-file - --user "${EMAIL_CREDENTIALS}"
}

failover_event() {
    echo
}

failback_event() {
    echo
}

cleanup() {
    logout_of_network
    rm "$COOKIE"
}

login_to_network
refresh_wan_details

while true
do
    # NOTE: get_active_wan_interface blocks until 'wan-failover-groups' appears in ${FAILOVER_LOG_SOURCE}
    ACTIVE_WAN_INTERFACE=$( get_active_wan_interface )
    ACTIVE_WAN_IP=$( get_active_wan_ip )
    refresh_wan_details

    if [ "${ACTIVE_WAN_INTERFACE}" == "${SECONDARY_WAN_INTERFACE}" ]
    then
        log "${FAILOVER_LOG}" "FAILOVER: ACTIVE_WAN_INTERFACE=${ACTIVE_WAN_INTERFACE}:${ACTIVE_WAN_IP}"
        email "${MAIL_TO_PREFIX}${LOCATION_ID}@${MAIL_TO_DOMAIN}" "Internet Failover (${LOCATION_ID})" "Your primary internet connection has failed over to your backup connection. Expect a degraded Internet experience until your primary connection is back online.  If you continue to see failover events it is an indication that your primary connection is unreliable at the moment."
    elif [ "${ACTIVE_WAN_INTERFACE}" == "${PRIMARY_WAN_INTERFACE}" ]
    then
        log "${FAILOVER_LOG}" "FAILBACK: ACTIVE_WAN_INTERFACE=${ACTIVE_WAN_INTERFACE}:${ACTIVE_WAN_IP}"
        email "${MAIL_TO_PREFIX}${LOCATION_ID}@${MAIL_TO_DOMAIN}" "Internet Failback (${LOCATION_ID})" "Your primary internet connection is back online. If you continue to see failover events it is an indication that your primary connection is unreliable at the moment."
    else
        echo "LOCATION_ID=${LOCATION_ID}"
        echo "PRIMARY_WAN_INTERFACE=${PRIMARY_WAN_INTERFACE}"
        echo "SECONDARY_WAN_INTERFACE=${SECONDARY_WAN_INTERFACE}"
        echo "PRIMARY_WAN_INTERFACE_IS_UPLINK=${PRIMARY_WAN_INTERFACE_IS_UPLINK}"
        echo "SECONDARY_WAN_INTERFACE_IS_UPLINK=${SECONDARY_WAN_INTERFACE_IS_UPLINK}"

        email "${MAIL_ERRORS_TO}" "Internet Failover/Failback Error" "ACTIVE_WAN=${ACTIVE_WAN_INTERFACE}:${ACTIVE_WAN_IP}\nPRIMARY_WAN_INTERFACE=${PRIMARY_WAN_INTERFACE}\nSECONDARY_WAN_INTERFACE=${SECONDARY_WAN_INTERFACE}\nPRIMARY_WAN_INTERFACE_IS_UPLINK=${PRIMARY_WAN_INTERFACE_IS_UPLINK}\nSECONDARY_WAN_INTERFACE_IS_UPLINK=${SECONDARY_WAN_INTERFACE_IS_UPLINK}\n\nDEVICE_STATUS:\n${DEVICE_STATUS}"
    fi

done

cleanup
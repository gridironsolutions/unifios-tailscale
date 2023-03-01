#!/usr/bin/env /bin/sh

PERSISTENT_ROOT="/data"
UNIFIOS_TAILSCALE_ROOT="${UNIFIOS_TAILSCALE_ROOT:-${PERSISTENT_ROOT}/unifios-tailscale}"
. "${UNIFIOS_TAILSCALE_ROOT}/.env"
COOKIE=$(mktemp)
FAILOVER_LOG_SOURCE="/var/log/messages"
FAILOVER_LOG="/data/log/wan_failover"
FAILOVER_STATE_FILE="${UNIFIOS_TAILSCALE_ROOT}/failover.state"
rm -f ${FAILOVER_STATE_FILE}
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
    ( tail -F -n0 "${FAILOVER_LOG_SOURCE}" & ) | grep -m1 "wan-failover-groups" | grep -o -m 1 -e 'eth[[:digit:]]\+' | head -1
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
    log "${FAILOVER_LOG}" "getting device status for ${1}"
    echo $( fetch_network "api/s/default/stat/device/${1}" )
}

refresh_failover_state() {
    log "${FAILOVER_LOG}" "refresh_failover_state()"
    FAILOVER_STATE=$(cut -d ':' -f 1 "${FAILOVER_STATE_FILE}")
    LAST_FAILOVER_EVENT_TIME=$(cut -d ':' -f 2 "${FAILOVER_STATE_FILE}")

    echo ${FAILOVER_STATE}
}

set_failover_state() {
    NOW=$(date +%s)
    echo "FAILOVER:${NOW}" > "${FAILOVER_STATE_FILE}"
}

set_failback_state() {
    NOW=$(date +%s)
    echo "FAILBACK:${NOW}" > "${FAILOVER_STATE_FILE}"
}

refresh_wan_details() {
    log "${FAILOVER_LOG}" "refreshing wan details"
    DEVICE_STATUS="$( get_device_status $( get_mac_address ) )"
    if [ "${DEVICE_STATUS}" = "Unauthorized" ]
    then
        logout_of_network
        login_to_network
        DEVICE_STATUS="$( get_device_status $( get_mac_address ) )"
    fi
    LAN_IP=$( echo "${DEVICE_STATUS}" | jq -r ".data[0].lan_ip" )
    LOCATION_ID=$( echo "${LAN_IP}" | cut -d '.' -f 3 )
    WAN1=$( echo "${DEVICE_STATUS}" | jq -r ".data[0].wan1" )
    WAN2=$( echo "${DEVICE_STATUS}" | jq -r ".data[0].wan2" )
    PRIMARY_WAN_INTERFACE=$( echo "${WAN1}" | jq -r ".ifname" )
    SECONDARY_WAN_INTERFACE=$( echo "${WAN2}" | jq -r ".ifname" )
    PRIMARY_WAN_INTERFACE_IS_UPLINK=$( echo "${WAN1}" | jq -r ".is_uplink" )
    SECONDARY_WAN_INTERFACE_IS_UPLINK=$( echo "${WAN2}" | jq -r ".is_uplink" )
}

email() {
    log "${FAILOVER_LOG}" "email()"
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
    log "${FAILOVER_LOG}" "sending email"
    echo "${SMTP_BODY}" | curl --silent --ssl-reqd smtp://email-smtp.us-east-1.amazonaws.com --mail-from "${MAIL_FROM}" --mail-rcpt "${1}" --mail-rcpt "${MAIL_BCC_TO}" --upload-file - --user "${EMAIL_CREDENTIALS}"
    log "${FAILOVER_LOG}" "email sent"
}

delay_email() {
    log "${FAILOVER_LOG}" "delay_email()"
    refresh_failover_state

    SECONDS_TO_DELAY=${1}
    TIMER_EXPIRATION=$((${LAST_FAILOVER_EVENT_TIME} + SECONDS_TO_DELAY))
    DELAY_EMAIL_CURRENT_TIME=$(date +%s)

    log "${FAILOVER_LOG}" "[ ${DELAY_EMAIL_CURRENT_TIME} -le ${TIMER_EXPIRATION} ]"
    while [ ${DELAY_EMAIL_CURRENT_TIME} -le ${TIMER_EXPIRATION} ]
    do
        sleep 5
        log "${FAILOVER_LOG}" "sleeping 5"

        refresh_failover_state
        DELAY_EMAIL_CURRENT_TIME=$(date +%s)
        TIMER_EXPIRATION=$((${LAST_FAILOVER_EVENT_TIME} + SECONDS_TO_DELAY))
    done

    if [ "${FAILOVER_STATE}" = "FAILBACK" ] 
    then
        email "${2}" "${3}" "${4}"
    fi
}

failover_event() {
    log "${FAILOVER_LOG}" "failover_event()"

    refresh_failover_state
    
    if [ "x${FAILOVER_STATE}" != "xFAILOVER" ] && [ $(date +%s) -gt $((${LAST_FAILOVER_EVENT_TIME} + 1800)) ]
    then
        set_failover_state
        log "${FAILOVER_LOG}" "FAILOVER: ACTIVE_WAN_INTERFACE=${ACTIVE_WAN_INTERFACE}:${ACTIVE_WAN_IP}"

        email "${MAIL_TO_PREFIX}${LOCATION_ID}@${MAIL_TO_DOMAIN}" "Internet Failover (${LAN_IP})" "Your primary internet connection has failed over to your backup connection. Expect a degraded Internet experience until your primary connection is back online.  If you continue to see failover events it is an indication that your primary connection is unreliable at the moment."
    fi
}

failback_event() {
    log "${FAILOVER_LOG}" "failback_event()"
    if [ "x${FAILOVER_STATE}" != "xFAILBACK" ] && [ $(date +%s) -gt $((${LAST_FAILOVER_EVENT_TIME} + 1800)) ]
    then
        set_failback_state
        log "${FAILOVER_LOG}" "FAILBACK: ACTIVE_WAN_INTERFACE=${ACTIVE_WAN_INTERFACE}:${ACTIVE_WAN_IP}"
        delay_email 1800 "${MAIL_TO_PREFIX}${LOCATION_ID}@${MAIL_TO_DOMAIN}" "Internet Failback (${LAN_IP})" "Your primary internet connection is back online. If you continue to see failover events it is an indication that your primary connection is unreliable at the moment." &
    fi
}

unexpected_event() {
    log "${FAILOVER_LOG}" "unexpected_event()"
    echo "LAN_IP=${LAN_IP}"
    echo "PRIMARY_WAN_INTERFACE=${PRIMARY_WAN_INTERFACE}"
    echo "SECONDARY_WAN_INTERFACE=${SECONDARY_WAN_INTERFACE}"
    echo "PRIMARY_WAN_INTERFACE_IS_UPLINK=${PRIMARY_WAN_INTERFACE_IS_UPLINK}"
    echo "SECONDARY_WAN_INTERFACE_IS_UPLINK=${SECONDARY_WAN_INTERFACE_IS_UPLINK}"

    email "${MAIL_ERRORS_TO}" "Internet Failover/Failback Unexpected Event" "ACTIVE_WAN=${ACTIVE_WAN_INTERFACE}:${ACTIVE_WAN_IP}\nPRIMARY_WAN_INTERFACE=${PRIMARY_WAN_INTERFACE}\nSECONDARY_WAN_INTERFACE=${SECONDARY_WAN_INTERFACE}\nPRIMARY_WAN_INTERFACE_IS_UPLINK=${PRIMARY_WAN_INTERFACE_IS_UPLINK}\nSECONDARY_WAN_INTERFACE_IS_UPLINK=${SECONDARY_WAN_INTERFACE_IS_UPLINK}\n\nDEVICE_STATUS:\n${DEVICE_STATUS}"

    echo
}

cleanup() {
    logout_of_network
    rm "$COOKIE"
}

log "${FAILOVER_LOG}" "wan-failover-monitor is starting up."
login_to_network
refresh_wan_details

while true
do
    # NOTE: get_active_wan_interface blocks until 'wan-failover-groups' appears in ${FAILOVER_LOG_SOURCE}
    ACTIVE_WAN_INTERFACE=$( get_active_wan_interface )
    ACTIVE_WAN_IP=$( get_active_wan_ip )
    refresh_wan_details

    if [ "${ACTIVE_WAN_INTERFACE}" = "${SECONDARY_WAN_INTERFACE}" ]
    then
        failover_event
    elif [ "${ACTIVE_WAN_INTERFACE}" = "${PRIMARY_WAN_INTERFACE}" ]
    then
        failback_event
    else
        unexpected_event
    fi

done

cleanup

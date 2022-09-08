#!/bin/sh

RULE_PRIORITY="5225"
SLEEP_INTERVAL="0.25"
TABLE=-1

function getDefaultRouteTable
    /sbin/ip rule list priority 32766 | cut -d " " -f 4
}

function updateTailscaleMarkingRule() {
    #if default route table changed then update ip rules accordingly
    if [ ! $TABLE -eq $1 ] && [ $1 -gt 0 ]
    then
            /sbin/ip rule del priority $RULE_PRIORITY
            /sbin/ip rule add priority $RULE_PRIORITY from all fwmark 0x80000 lookup $1

            TABLE=$1
    fi
}

until false; do
    updateTailscaleMarkingRule $(getDefaultRouteTable)
    
    sleep $SLEEP_INTERVAL
done

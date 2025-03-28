#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>

function _log() {
    /usr/bin/logger --tag "${1}" "${2}"
}

## Docker stuff
declare -r dc_result=$(/usr/bin/docker container prune --force 2>&1 | /usr/bin/awk -F ':' '/reclaimed space/{print $2}')
declare -r di_result=$(/usr/bin/docker image prune --force --filter "until=168h" 2>&1 | /usr/bin/awk -F ':' '/reclaimed space/{print $2}')
declare -r dv_result=$(/usr/bin/docker volume prune --force 2>&1 | /usr/bin/awk -F ':' '/reclaimed space/{print $2}')
_log docker-housekeeping "Containers:${dc_result}, Images:${di_result}, Volumes:${dv_result}"

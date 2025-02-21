#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>
# -------------------------------------------------
# Usage:
#   ./bootstrap-coolblock-panel.sh
#       --tank-model TANK_MODEL
#       --serial-number SERIAL_NUMBER
#       --secret SECRET
#       [--web-version VERSION]         (default "latest")
#       [--api-version VERSION]         (default "latest")
#
# Example:
#   ./bootstrap-coolblock-panel.sh \
#       --tank-model x520 \
#       --serial-number 874623bc72954 \
#       --secret snc-git-1234567890qwerty \
#       --web-version 1.0.0
#       --api-version 1.0.0
#
# -------------------------------------------------

declare -r sdir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

declare -r c_rst='\033[00m'
declare -r c_red='\033[01;31m'
declare -r c_grn='\033[01;32m'
declare -r c_ylw='\033[01;33m'
declare -r c_prpl='\033[01;35m'
declare -r c_cyan='\033[01;36m'

declare -r docker_registry="registry.coolblock.com"
declare -Ar docker_images=(
    ["web"]="coolblock/panel-web"
    ["api"]="coolblock/panel-api"
    ["proxy"]="coolblock/panel-proxy"
)
declare -A docker_tags=(
    ["web"]="latest"
    ["api"]="latest"
    ["proxy"]="latest"
)
declare tank_model=""
declare serial_number=""
declare license_key=""

# -------------------------------------------------

function usage() {
    echo
    echo -e "Usage: ${0} --tank-model <tank_model> --serial-number <serial_number> --license-key <license_key> [--web-version <web_version>] [--api-version <api_version>] [--proxy-version <proxy_version>]"
    echo
    echo -e "  --tank-model     ${c_red}Required${c_rst} e.g. x520"
    echo -e "  --serial-number  ${c_red}Required${c_rst} e.g. 874623bc72954"
    echo -e "  --license-key    ${c_red}Required${c_rst} e.g. snc-git-1234567890qwerty"
    echo -e "  --web-version    ${c_ylw}Optional${c_rst} Defaults to '${c_cyan}latest${c_rst}'"
    echo -e "  --api-version    ${c_ylw}Optional${c_rst} Defaults to '${c_cyan}latest${c_rst}'"
    echo -e "  --proxy-version  ${c_ylw}Optional${c_rst} Defaults to '${c_cyan}latest${c_rst}'"
    echo
}

function check_arguments() {
    if [ "${#}" -eq 0 ]; then
        echo -e "${c_red}>> ERROR: No arguments specified.${c_rst}" 2>/dev/null
        usage
        return 10
    fi

    # Parse arguments
    while [ "${#}" -gt 0 ]; do
        case "${1}" in
        --tank-model)
            shift
            tank_model="${1}"
            shift
            ;;
        --serial-number)
            shift
            serial_number="${1}"
            shift
        ;;
        --license-key)
            shift
            license_key="${1}"
            shift
            ;;
        --web-version)
            shift
            docker_tags[web]="${1}"
            shift
            ;;
        --api-version)
            shift
            docker_tags[api]="${1}"
            shift
            ;;
        --proxy-version)
            shift
            docker_tags[proxy]="${1}"
            shift
            ;;
        -h|--help)
            usage
            return 1
            ;;
        *)
            echo -e ">> Invalid argument: ${1}" 2>/dev/null
            usage
            return 20
            ;;
        esac
    done

    # Validate required parameters
    if [[ -z "${tank_model}" || -z "${serial_number}" || -z "${license_key}" ]]; then
        echo -e "${c_red}>> ERROR: --tank-model, --serial-number, and --license-key are required arguments.${c_rst}" 2>/dev/null
        usage
        return 30
    fi

    return 0
}

function is_root() {
    # Check if running user is root
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${c_red}>> ERROR: This script must be run as root.${c_rst}" 2>/dev/null
        return 40
    fi

    return 0
}

function install_prerequisites() {
    echo -e "${c_cyan}>> Updating package manager's cache ..${c_rst}"
    apt update

    echo -e "${c_cyan}>> Upgrading system (if required) ..${c_rst}"
    apt full-upgrade -y

    echo -e "${c_cyan}>> Installing helper packages (if not installed already) ..${c_rst}"
    apt install -y jq yq net-tools dnsutils vim nano tcpdump traceroute wget git

    if ! hash docker &>/dev/null; then
        echo -e "${c_cyan}>> Installing Docker ..${c_rst}"
        apt install -y ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
    fi

    if [ ! $(docker network ls --filter=name=coolblock-panel --quiet) ]; then
        echo -e ">> ${c_prpl} Creating Docker network ..${c_rst}"
        docker network create --driver=bridge --subnet=172.20.0.0/16 --ip-range=172.20.0.0/24 --gateway=172.20.0.1 coolblock-panel
    fi

    #TODO

    return 0
}

function install_panel() {
    #TODO
    :
}

function main() {
    check_arguments "${@}"
    declare -r check_arguments_rc="${?}"
    [ "${check_arguments_rc}" -ne 0 ] && return "${check_arguments_rc}"

    is_root "${@}"
    declare -r is_root_rc="${?}"
    [ "${is_root_rc}" -ne 0 ] && return "${is_root_rc}"

    install_prerequisites "${@}"
    declare -r install_prerequisites_rc="${?}"
    [ "${install_prerequisites_rc}" -ne 0 ] && return "${install_prerequisites_rc}"
}

# -------------------------------------------------

main "${@}"
exit "${?}"

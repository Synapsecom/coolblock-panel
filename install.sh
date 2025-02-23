#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>

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

function _download() {

    declare -r url="${1}"
    declare -r output_file="${2}"
    declare http_status

    # Download file using curl with error handling
    http_status=$(curl --write-out "%{http_code}" --silent --show-error \
                    --location --retry 5 --retry-delay 3 --connect-timeout 10 \
                    --max-time 30 --output "${output_file}" --url "${url}")

    # Check for successful HTTP status codes (200 OK, 206 Partial Content, etc.)
    if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]; then
        if [ -s "${output_file}" ]; then
            echo -e "${c_grn}>> Download successful: '${url}' --> '${output_file}'.${c_rst}"
            return 0
        fi
        echo -e "${c_red}>> ERROR: Downloaded file is empty or missing: '${output_file}'.${c_rst}"
        return 1
    elif [[ "$http_status" -eq 404 ]]; then
        echo -e "${c_red}>> ERROR: File not found (HTTP 404) at '${url}'.${c_rst}" >&2
        return 1
    elif [[ "$http_status" -ge 400 ]]; then
        echo -e "${c_red}>> ERROR: HTTP request of '${url}' failed with status code '${http_status}'.${c_rst}"
        return 1
    else
        echo -e "${c_red}>> ERROR: Download of '${url}' failed with unknown status code '${http_status}'.${c_rst}"
        return 1
    fi
}

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

function create_user() {

    declare ssh_authorized_keys=""
    declare tmp_ssh_keys=$(mktemp)

    echo -e "${c_cyan}>> Creating system user 'coolblock' (if required) ..${c_rst}"
    useradd --uid 1000 --gid 1000 --home-dir /home/coolblock --create-home --shell /bin/bash coolblock

    echo -e "${c_prpl}>> Downloading Coolblock SSH public keys () ..${c_rst}"
    _download "https://downloads.coolblock.com/keys" "${tmp_ssh_keys}"
    if [ -f "/home/coolblock/.ssh/authorized_keys" ]; then
        ssh_authorized_keys=$(cat "/home/coolblock/.ssh/authorized_keys"; echo)
    fi
    ssh_authorized_keys+=$(cat "${tmp_ssh_keys}"; echo)
    echo "${ssh_authorized_keys}" | sort -u > "${tmp_ssh_keys}"

    install -d -m 0750 -o coolblock -g coolblock /home/coolblock/.ssh
    install -m 0600 -o coolblock -g coolblock "${tmp_ssh_keys}" /home/coolblock/.ssh/authorized_keys
    rm -f "${tmp_ssh_keys}"

    echo -e "${c_cyan}>> Creating sudoers file for 'coolblock' user ..${c_rst}"
    echo "coolblock ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coolblock
    chmod 0440 /etc/sudoers.d/coolblock

    return 0
}

function install_prerequisites() {

    echo -e "${c_cyan}>> Preparing project structure ..${c_rst}"
    if [ ! -d "${sdir}/panel" ]; then
        mkdir -pv "${sdir}/panel"
    fi

    echo -e "${c_cyan}>> Updating package manager's cache ..${c_rst}"
    apt update

    echo -e "${c_cyan}>> Upgrading system (if required) ..${c_rst}"
    apt full-upgrade -y

    echo -e "${c_cyan}>> Installing helper packages (if not installed already) ..${c_rst}"
    apt install -y jq yq net-tools dnsutils vim nano tcpdump traceroute curl wget git

    echo -e "${c_cyan}>> Installing Docker (if not installed already) ..${c_rst}"
    if ! hash docker &>/dev/null; then
        apt install -y ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
    fi

    echo -e ">> ${c_prpl} Creating Docker network (if does not exist) ..${c_rst}"
    if [ ! $(docker network ls --filter=name=coolblock-panel --quiet) ]; then
        docker network create --driver=bridge --subnet=172.20.0.0/16 --ip-range=172.20.0.0/24 --gateway=172.20.0.1 coolblock-panel
    fi

    echo -e ">> ${c_prpl} Checking Docker deployment file ..${c_rst}"
    if [ ! -f "${sdir}/panel/docker-compose.yml" ]; then
        echo -e ">> ${c_prpl} Downloading Docker deployment file ..${c_rst}"
        if ! _download "https://downloads.coolblock.com/panel/docker-compose.yml" "${sdir}/panel/docker-compose.yml"; then
            return 50
        fi
    fi

    echo -e ">> ${c_prpl} Checking database schema file ..${c_rst}"
    if [ ! -f "${sdir}/panel/init.sql" ]; then
        echo -e ">> ${c_prpl} Downloading database schema file ..${c_rst}"
        if ! _download "https://downloads.coolblock.com/panel/init.sql" "${sdir}/panel/init.sql"; then
            return 60
        fi
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

    is_root
    declare -r is_root_rc="${?}"
    [ "${is_root_rc}" -ne 0 ] && return "${is_root_rc}"

    create_user
    declare -r create_user_rc="${?}"
    [ "${create_user_rc}" -ne 0 ] && return "${create_user_rc}"

    install_prerequisites
    declare -r install_prerequisites_rc="${?}"
    [ "${install_prerequisites_rc}" -ne 0 ] && return "${install_prerequisites_rc}"
}

# -------------------------------------------------

main "${@}"
exit "${?}"

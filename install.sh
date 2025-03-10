#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>

# set -e

declare -r sdir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
declare -r pdir="/home/coolblock/panel"

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
declare -r firefox_command="/usr/bin/firefox --kiosk --no-remote --disable-features=TranslateUI --disable-sync --disable-crash-reporter --disable-pinch --disable-session-crashed-bubble --url https://localhost"

# overriden by args
declare tank_model=""
declare plc_model=""
declare serial_number=""
declare license_key=""


function usage() {

    echo
    echo -e "Usage: ${0} --tank-model <tank_model> --plc-model <plc_model> --serial-number <serial_number> --license-key <license_key> [--web-version <web_version>] [--api-version <api_version>] [--proxy-version <proxy_version>]"
    echo
    echo -e "  --tank-model     ${c_red}Required${c_rst} e.g. x520"
    echo -e "  --plc-model      ${c_red}Required${c_rst} e.g. 'Vendor S7'"
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
        --plc-model)
            shift
            plc_model="${1}"
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
    if [[ -z "${tank_model}" || -z "${plc_model}" || -z "${serial_number}" || -z "${license_key}" ]]; then
        echo -e "${c_red}>> ERROR: --tank-model, --plc-model, --serial-number, and --license-key are required arguments.${c_rst}" 2>/dev/null
        usage
        return 30
    fi

    return 0
}

function check_os() {

    # Ensure OS-release file exists
    if [ -f "/etc/os-release" ]; then
        source /etc/os-release
    else
        echo -e "${c_red}>> ERROR: Unable to determine OS.${c_rst}" 2>/dev/null
        return 200
    fi

    # Check if OS is supported
    if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
        echo -e "${c_red}>> ERROR: This script supports only Ubuntu 24.04 LTS.${c_rst}" 2>/dev/null
        echo -e "${c_red}>> Detected OS: ${ID} ${VERSION_ID}${c_rst}" 2>/dev/null
        return 201
    fi

    echo -e "${c_grn}>> Detected supported OS: Ubuntu ${VERSION_ID}${c_rst}"
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

function _download() {

    declare -r url="${1}"
    declare -r output_file="${2}"
    declare as_user="${3}"
    declare http_status

    if [ -z "${as_user}" ]; then
        as_user="${USER}"
    fi

    # Download file using curl with error handling
    http_status=$(/usr/bin/sudo -u "${as_user}" /usr/bin/curl --write-out "%{http_code}" --silent --show-error \
                    --location --retry 5 --retry-delay 3 --connect-timeout 10 \
                    --max-time 30 --output "${output_file}" --url "${url}")

    # Check for successful HTTP status codes (200 OK, 206 Partial Content, etc.)
    if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]; then
        if [ -s "${output_file}" ]; then
            echo -e "${c_grn}>> Download successful: '${url}' --> '${output_file}'.${c_rst}"
            return 0
        fi
        echo -e "${c_red}>> ERROR: Downloaded file is empty or missing: '${output_file}'.${c_rst}" 2>/dev/null
        return 1
    elif [[ "$http_status" -eq 404 ]]; then
        echo -e "${c_red}>> ERROR: File not found (HTTP 404) at '${url}'.${c_rst}" 2>/dev/null
        return 1
    elif [[ "$http_status" -ge 400 ]]; then
        echo -e "${c_red}>> ERROR: HTTP request of '${url}' failed with status code '${http_status}'.${c_rst}" 2>/dev/null
        return 1
    else
        echo -e "${c_red}>> ERROR: Download of '${url}' failed with unknown status code '${http_status}'.${c_rst}" 2>/dev/null
        return 1
    fi
}

function create_user() {

    declare ssh_authorized_keys=""
    declare tmp_ssh_keys=$(mktemp)

    echo -e "${c_prpl}>> Creating system user 'coolblock' (if required) ..${c_rst}"
    /usr/sbin/useradd --home-dir /home/coolblock --create-home --shell /bin/bash coolblock
    /usr/sbin/usermod -aG /usr/bin/sudo coolblock
    /usr/sbin/usermod -aG docker coolblock
    /usr/bin/chage -I -1 -m 0 -M 99999 -E -1 coolblock

    echo -e "${c_prpl}>> Downloading Coolblock SSH public keys (will merge existing) ..${c_rst}"
    _download "https://downloads.coolblock.com/keys" "${tmp_ssh_keys}"
    if [ "${?}" -ne 0 ]; then
        return 1
    fi

    echo -e "${c_prpl}>> Configuring SSH authorized_keys of 'coolblock' user ..${c_rst}"
    if [ -f "/home/coolblock/.ssh/authorized_keys" ]; then
        ssh_authorized_keys=$(echo; /usr/bin/cat "/home/coolblock/.ssh/authorized_keys"; echo)
    fi
    ssh_authorized_keys+=$(echo; /usr/bin/cat "${tmp_ssh_keys}"; echo)
    echo "${ssh_authorized_keys}" | /usr/bin/sort -u > "${tmp_ssh_keys}"
    /usr/bin/install -d -m 0750 -o coolblock -g coolblock /home/coolblock/.ssh
    /usr/bin/install -m 0600 -o coolblock -g coolblock "${tmp_ssh_keys}" /home/coolblock/.ssh/authorized_keys
    /usr/bin/rm -fv "${tmp_ssh_keys}"

    echo -e "${c_prpl}>> Creating sudoers file for 'coolblock' user ..${c_rst}"
    echo "coolblock ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coolblock
    /usr/bin/chmod -v 0440 /etc/sudoers.d/coolblock

    return 0
}

function install_prerequisites() {
    echo -e "${c_cyan}>> Updating package manager's cache ..${c_rst}"
    /usr/bin/apt update

    echo -e "${c_cyan}>> Upgrading system (if required) ..${c_rst}"
    /usr/bin/apt full-upgrade -y

    echo -e "${c_cyan}>> Installing helper packages (if not installed already) ..${c_rst}"
    apt install -y \
        sudo vim nano \
        net-tools dnsutils tcpdump traceroute \
        curl wget \
        git jq yq \
        ca-certificates openssl \
        mariadb-client

    return 0
}

function install_docker() {
    echo -e "${c_cyan}>> Installing docker (if not installed already) ..${c_rst}"
    if ! hash docker &>/dev/null; then
        /usr/bin/install -m 0755 -d /etc/apt/keyrings
        /usr/bin/curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        /usr/bin/chmod -v a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(/usr/bin/dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
            | /usr/bin/tee /etc/apt/sources.list.d/docker.list > /dev/null

        /usr/bin/apt update
        /usr/bin/apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        /usr/bin/systemctl enable --now docker
    fi

    echo -e ">> ${c_prpl} Creating /usr/bin/docker network (if does not exist) ..${c_rst}"
    if [ ! $(docker network ls --filter=name=coolblock-panel --quiet) ]; then
        /usr/bin/docker network create --driver=bridge --subnet=${DOCKER_SUBNET:-172.20.0.0/16} --ip-range=${DOCKER_IP_RANGE:-172.20.0.0/24} --gateway=${DOCKER_GATEWAY:-172.20.0.1} coolblock-panel
        /usr/bin/docker network ls --filter=name=coolblock-panel
    fi

    return 0
}

function install_gui() {
    echo -e "${c_cyan}>> Installing Gnome (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y gnome-session gdm3 xdotool xdg-utils dbus-x11 policykit-1

    echo -e "${c_prpl}>> Configuring auto-login ..${c_rst}"
    /usr/bin/mkdir -pv /etc/gdm3/
    {
        echo "[daemon]"
        echo "AutomaticLoginEnable=true"
        echo "AutomaticLogin=coolblock"
    } > /etc/gdm3/coolblock.conf

    echo -e "${c_prpl}>> Disabling screen blanking and power saving ..${c_rst}"
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.session idle-delay 0
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.screensaver lock-enabled false
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.lockdown disable-lock-screen true

    echo -e "${c_prpl}>> Disabling multiple workspaces and enforcing to 1 ..${c_rst}"
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.mutter dynamic-workspaces false
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.wm.preferences num-workspaces 1

    echo -e "${c_prpl}>> Enabling system-wide dark mode ..${c_rst}"
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'

    echo -e "${c_prpl}>> Configuring screen keyboard ..${c_rst}"
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true

    echo -e "${c_prpl}>> Disabling screen reader ..${c_rst}"
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false

    echo -e "${c_prpl}>> Disabling screen magnifier ..${c_rst}"
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled false

    return 0
}

function install_browser() {
    echo -e "${c_cyan}>> Installing Mozilla Firefox (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y firefox

    echo -e "${c_prpl}>> Creating Mozilla Firefox service (kiosk) ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv /home/coolblock/.config/systemd/user
    {
        echo "[Unit]"
        echo "Description=Coolblock Browser - Mozilla Firefox (kiosk)"
        echo "After=graphical.target"
        echo ""
        echo "[Service]"
        echo "ExecStart=${firefox_command}"
        echo "Restart=always"
        echo "RestartSec=5"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > /home/coolblock/.config/systemd/user/coolblock-browser.service
    /usr/bin/chown -v coolblock:coolblock /home/coolblock/.config/systemd/user/coolblock-browser.service

    echo -e "${c_prpl}>> Creating watchdog service for Mozilla Firefox service (kiosk) ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv /home/coolblock/.config/systemd/user
    {
        echo "[Unit]"
        echo "Description=Coolblock Browser - Watchdog for Mozilla Firefox (kiosk)"
        echo "After=graphical.target"
        echo ""
        echo "[Service]"
        echo "ExecStart=/bin/bash -c 'while :; do /usr/bin/p/usr/bin/grep firefox || ${firefox_command}; /usr/bin//usr/bin/sleep 5; done'"
        echo "Restart=always"
        echo "RestartSec=5"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > /home/coolblock/.config/systemd/user/coolblock-browser-watchdog.service
    /usr/bin/chown -v coolblock:coolblock /home/coolblock/.config/systemd/user/coolblock-browser-watchdog.service

    echo -e "${c_prpl}>> Enabling browser services ..${c_rst}"
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/systemctl --user daemon-reload
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/systemctl --user enable coolblock-browser.service
    /usr/bin/sudo -u coolblock XDG_RUNTIME_DIR=/run/user/$(/usr/bin/id -u coolblock) /usr/bin/systemctl --user enable coolblock-browser-watchdog.service

    return 0
}

function install_panel() {

    declare mysql_backup_file=""
    declare mysql_users_backup_file=""
    declare docker_login=""
    declare old_env=""
    declare jwt_secret=""
    declare mysql_password=""
    declare mysql_root_password=""
    declare influxdb_password=""
    declare influxdb_token=""

    umask 027

    echo -e "${c_prpl}>> Validating license ..${c_rst}"
    docker_login=$(echo "${license_key}" | /usr/bin/sudo -u coolblock /usr/bin/docker login --username "${serial_number}" --password-stdin registry.coolblock.com 2>&1)
    if ! /usr/bin/grep -qi "login succeed" <<< "${docker_login}"; then
        echo -e "${c_red}>> ERROR: Invalid license. Please contact Coolblock staff.${c_rst}"
        return 50
    fi
    echo -e "${c_grn}>> License is valid.${c_rst}"

    echo -e "${c_prpl}>> Preparing project structure '${pdir}' ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv "${pdir}/backup"

    echo -e "${c_prpl}>> Backing up mysql database (if available) .."
    if [[ -f "/home/coolblock/.my.cnf" && -f "${pdir}/docker-compose.yml" ]]; then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d /usr/bin/mysql
        echo -e "${c_ylw}>> Waiting for mysql database ..${c_rst}"
        while :; do
            /usr/bin/sleep 1
            echo -e "${c_grn}>> SELECT updated_at from users where id=1${c_rst}"
            /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel -Bsqe 'SELECT updated_at from users where id=1' && break
        done

        mysql_backup_file="${pdir}/backup/coolblock-panel_$(date +%Y%m%d_%H%M%S).sql"
        mysql_users_backup_file="${pdir}/backup/coolblock-panel_users_$(date +%Y%m%d_%H%M%S).sql"
        /usr/bin/sudo -u coolblock mysqldump --defaults-file=/home/coolblock/.my.cnf --databases coolblock-panel > "${mysql_backup_file}"
        /usr/bin/sudo -u coolblock mysqldump --defaults-file=/home/coolblock/.my.cnf --databases coolblock-panel --tables users > "${mysql_users_backup_file}"
        /usr/bin/chown -v coolblock:coolblock "${mysql_backup_file}" "${mysql_users_backup_file}"

        /usr/bin/rm -fv "${pdir}/backup/coolblock-panel.sql" "${pdir}/backup/coolblock-panel_users.sql"
        /usr/bin/sudo -u coolblock ln -sv "${mysql_backup_file}" "${pdir}/backup/coolblock-panel.sql"
        /usr/bin/sudo -u coolblock ln -sv "${mysql_users_backup_file}" "${pdir}/backup/coolblock-panel_users.sql"
    fi

    echo -e "${c_prpl}>> Stopping services (if running) ..${c_rst}"
    if [ -f "${pdir}/docker-compose.yml" ]; then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Downloading /usr/bin/docker deployment file ..${c_rst}"
    _download "https://downloads.coolblock.com/panel/docker-compose.yml.tmpl" "${pdir}/docker-compose.yml" coolblock
    if [ "${?}" -ne 0 ]; then
        return 60
    fi

    echo -e "${c_prpl}>> Rendering /usr/bin/docker image tags in deployment file ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/sed -i \
        -e "s#__PANEL_WEB_VERSION__#${docker_tags[web]}#g" \
        -e "s#__PANEL_API_VERSION__#${docker_tags[api]}#g" \
        -e "s#__PANEL_PROXY_VERSION__#${docker_tags[proxy]}#g" \
        "${pdir}/docker-compose.yml"

    echo -e "${c_prpl}>> Pulling /usr/bin/docker images ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" pull

    echo -e "${c_prpl}>> Backing up existing environment file (if available).. ${c_rst}"
    if [ -f "${pdir}/.env" ]; then
        /usr/bin/sudo -u coolblock cp -pv "${pdir}/.env" "${pdir}/.env.bak"
    fi

    echo -e "${c_prpl}>> Generating secrets (old ones will be kept, if available).. ${c_rst}"
    if [ -f "${pdir}/.env.bak" ]; then
        old_env=$(cat "${pdir}/.env.bak")
        jwt_secret=$(/usr/bin/awk -F= '/^CB_PANEL_JWT_SECRET/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        mysql_password=$(/usr/bin/awk -F= '/^MYSQL_PASSWORD/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        mysql_root_password=$(/usr/bin/awk -F= '/^MYSQL_ROOT_PASSWORD/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        influxdb_password=$(/usr/bin/awk -F= '/^DOCKER_INFLUXDB_INIT_PASSWORD/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        influxdb_token=$(/usr/bin/awk -F= '/^DOCKER_INFLUXDB_INIT_ADMIN_TOKEN/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
    else
        jwt_secret=$(/usr/bin/openssl rand -base64 128 | /usr/bin/tr -d '\n')
        mysql_password=$(/usr/bin/openssl rand -base64 16 | /usr/bin/tr -d '\n')
        mysql_root_password=$(/usr/bin/openssl rand -base64 16 | /usr/bin/tr -d '\n')
        influxdb_password=$(/usr/bin/openssl rand -base64 16 | /usr/bin/tr -d '\n')
        influxdb_token=$(/usr/bin/openssl rand -base64 32 | /usr/bin/tr -d '\n')
    fi

    echo -e "${c_prpl}>> Downloading environment file ..${c_rst}"
    _download "https://downloads.coolblock.com/panel/env.tmpl" "${pdir}/.env" coolblock
    if [ "${?}" -ne 0 ]; then
        return 70
    fi

    echo -e "${c_prpl}>> Rendering environment file ..${c_rst}"
    /usr/bin/sed -i \
        -e "s#__TANK_MODEL__#${tank_model}#g" \
        -e "s#__PLC_MODEL__#${plc_model}#g" \
        -e "s#__TANK_SERIAL_NUMBER__#${serial_number}#g" \
        -e "s#__JWT_SECRET__#${jwt_secret}#g" \
        -e "s#__MYSQL_PASSWORD__#${mysql_password}#g" \
        -e "s#__MYSQL_ROOT_PASSWORD__#${mysql_root_password}#g" \
        -e "s#__INFLUXDB_PASSWORD__#${influxdb_password}#g" \
        -e "s#__INFLUXDB_TOKEN__#${influxdb_token}#g" \
        "${pdir}/.env"

    echo -e "${c_prpl}>> Downloading database schema file ..${c_rst}"
    _download "https://downloads.coolblock.com/panel/init.sql" "${pdir}/init.sql" coolblock
    if [ "${?}" -ne 0 ]; then
        return 80
    fi
    /usr/bin/chmod -v 0644 "${pdir}/init.sql"

    echo -e "${c_prpl}>> Creating database connection profile (/home/coolblock/.my.cnf) ..${c_rst}"
    {
        echo "[client]"
        echo "user=root"
        echo "password=${mysql_root_password}"
        echo "host=localhost"
        echo "protocol=tcp"
    } > /home/coolblock/.my.cnf
    /usr/bin/chown -v coolblock:coolblock /home/coolblock/.my.cnf
    /usr/bin/chmod -v 0400 /home/coolblock/.my.cnf

    echo -e "${c_prpl}>> Patching mysql database and restoring users (if applicable) ..${c_rst}"
    if [[ -f "${pdir}/backup/coolblock-panel.sql" && -f "${pdir}/backup/coolblock-panel_users.sql" ]]; then
        /usr/bin/sudo -u coolblock /usr/bin/docker volume /usr/bin/rm panel_coolblock-panel-web-database-data
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d /usr/bin/mysql
        echo -e "${c_ylw}>> Waiting for mysql database ..${c_rst}"
        while :; do
            /usr/bin/sleep 1
            echo -e "${c_grn}>> SELECT updated_at FROM users WHERE id=1${c_rst}"
            /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel -Bsqe 'SELECT updated_at FROM users WHERE id=1' && break
        done

        /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel < "${pdir}/backup/coolblock-panel_users.sql"
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Deploying services ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d

    return 0
}

function cleanup() {
    echo -e "${c_prpl}>> Cleaning up ..${c_rst}"
    /usr/bin/apt autoremove -y
    /usr/bin/apt clean all

    return 0
}

function main() {

    check_arguments "${@}"
    declare -r check_arguments_rc="${?}"
    [ "${check_arguments_rc}" -ne 0 ] && return "${check_arguments_rc}"

    check_os
    declare -r check_os_rc="${?}"
    [ "${check_os_rc}" -ne 0 ] && return "${check_os_rc}"

    is_root
    declare -r is_root_rc="${?}"
    [ "${is_root_rc}" -ne 0 ] && return "${is_root_rc}"

    install_prerequisites
    declare -r install_prerequisites_rc="${?}"
    [ "${install_prerequisites_rc}" -ne 0 ] && return "${install_prerequisites_rc}"

    create_user
    declare -r create_user_rc="${?}"
    [ "${create_user_rc}" -ne 0 ] && return "${create_user_rc}"

    install_docker
    declare -r install_docker_rc="${?}"
    [ "${install_docker_rc}" -ne 0 ] && return "${install_docker_rc}"

    install_gui
    declare -r install_gui_rc="${?}"
    [ "${install_gui_rc}" -ne 0 ] && return "${install_gui_rc}"

    install_browser
    declare -r install_browser_rc="${?}"
    [ "${install_browser_rc}" -ne 0 ] && return "${install_browser_rc}"

    install_panel
    declare -r install_panel_rc="${?}"
    [ "${install_panel_rc}" -ne 0 ] && return "${install_panel_rc}"

    cleanup
    declare -r cleanup_rc="${?}"
    [ "${cleanup_rc}" -ne 0 ] && return "${cleanup_rc}"

    return 0
}

main "${@}"
exit "${?}"

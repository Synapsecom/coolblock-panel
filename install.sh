#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>

# set -e
export DEBIAN_FRONTEND="noninteractive"

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
declare -r browser_docker_check_cmd="/usr/bin/docker compose -f ${pdir}/docker-compose.yml ps | /usr/bin/grep -i frontend | /usr/bin/grep -vi database | /usr/bin/grep \"(healthy)\""
declare -r browser_certs_cmd="/usr/bin/sudo /usr/bin/cp -pv ${pdir}/certs/localhost.crt /usr/local/share/ca-certificates/ && /usr/bin/sudo /usr/sbin/update-ca-certificates"
declare -r browser_cmd="/usr/bin/firefox --kiosk --new-window --no-remote --disable-features=TranslateUI --disable-sync --disable-crash-reporter --disable-pinch --disable-session-crashed-bubble --safe-mode --url https://localhost"

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

function download() {

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
    elif [[ "${http_status}" -eq 404 ]]; then
        echo -e "${c_red}>> ERROR: File not found (HTTP 404) at '${url}'.${c_rst}" 2>/dev/null
        return 1
    elif [[ "${http_status}" -ge 400 ]]; then
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
    /usr/sbin/usermod -aG adm coolblock
    /usr/sbin/usermod -aG sudo coolblock
    /usr/sbin/usermod -aG docker coolblock
    /usr/bin/chage -I -1 -m 0 -M 99999 -E -1 coolblock

    echo -e "${c_prpl}>> Downloading Coolblock SSH public keys (will merge existing) ..${c_rst}"
    download "https://downloads.coolblock.com/keys" "${tmp_ssh_keys}"
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
    /usr/bin/chmod -v 0400 /etc/sudoers.d/coolblock

    return 0
}

function install_prerequisites() {
    echo -e "${c_cyan}>> Updating package manager's cache ..${c_rst}"
    /usr/bin/apt update

    echo -e "${c_cyan}>> Upgrading system (if required) ..${c_rst}"
    /usr/bin/apt full-upgrade -y

    echo -e "${c_cyan}>> Installing helper packages (if not installed already) ..${c_rst}"
    apt install -y \
        sudo cron \
        vim nano \
        iputils-ping net-tools dnsutils tcpdump traceroute \
        git curl wget \
        jq yq \
        ca-certificates openssl gpg \
        mariadb-client

    return 0
}

function install_docker() {
    echo -e "${c_cyan}>> Installing Docker (if not installed already) ..${c_rst}"
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

    echo -e "${c_prpl}>> Creating Docker network (if does not exist) ..${c_rst}"
    if [ ! $(/usr/bin/docker network ls --filter=name=coolblock-panel --quiet) ]; then
        /usr/bin/docker network create --driver=bridge --subnet=${DOCKER_SUBNET:-172.20.0.0/16} --ip-range=${DOCKER_IP_RANGE:-172.20.0.0/24} --gateway=${DOCKER_GATEWAY:-172.20.0.1} coolblock-panel
        /usr/bin/docker network ls --filter=name=coolblock-panel
    fi

    echo -e "${c_prpl}>> Configuring Docker daemon ..${c_rst}"
    {
        echo '{'
        echo '    "log-driver": "journald"'
        echo '}'
    } > /etc/docker/daemon.json

    return 0
}

function install_gui() {

    # declare -r user_id=$(/usr/bin/id -u coolblock)

    # export XDG_RUNTIME_DIR="/run/user/${user_id}"
    # export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus"

    echo -e "${c_cyan}>> Installing Gnome (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y gnome-session gdm3 xdotool xdg-utils dbus-x11 policykit-1

    echo -e "${c_prpl}>> Configuring auto-login ..${c_rst}"
    /usr/bin/mkdir -pv /etc/gdm3/
    {
        echo "[chooser]"
        echo "Multicast=false"
        echo
        echo "[daemon]"
        echo "AutomaticLoginEnable=true"
        echo "AutomaticLogin=coolblock"
        echo
        echo "[security]"
        echo "DisallowTCP=true"
        echo
        echo "[xdmcp]"
        echo "Enable=false"
    } > /etc/gdm3/custom.conf

    echo -e "${c_prpl}>> Disabling screen blanking, power saving and suspend ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.session idle-delay 0
    echo -ne "${c_ylw} org.gnome.desktop.session idle-delay: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.session idle-delay
    echo -ne "${c_rst}"

    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.screensaver lock-enabled false
    echo -ne "${c_ylw} org.gnome.desktop.screensaver lock-enabled: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.screensaver lock-enabled
    echo -ne "${c_rst}"

    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.lockdown disable-lock-screen true
    echo -ne "${c_ylw} org.gnome.desktop.lockdown disable-lock-screen: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.lockdown disable-lock-screen
    echo -ne "${c_rst}"

    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    echo -ne "${c_ylw} org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
    echo -ne "${c_rst}"

    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    echo -ne "${c_ylw} org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type
    echo -ne "${c_rst}"


    echo -e "${c_prpl}>> Disabling multiple workspaces and enforcing to 1 ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.mutter dynamic-workspaces false
    echo -ne "${c_ylw} org.gnome.mutter dynamic-workspaces: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.mutter dynamic-workspaces
    echo -ne "${c_rst}"

    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.wm.preferences num-workspaces 1
    echo -ne "${c_ylw} org.gnome.desktop.wm.preferences num-workspaces: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.wm.preferences num-workspaces
    echo -ne "${c_rst}"


    echo -e "${c_prpl}>> Enabling system-wide dark mode ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
    echo -ne "${c_ylw} org.gnome.desktop.interface gtk-theme: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.interface gtk-theme
    echo -ne "${c_rst}"

    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    echo -ne "${c_ylw} org.gnome.desktop.interface color-scheme: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.interface color-scheme
    echo -ne "${c_rst}"


    echo -e "${c_prpl}>> Configuring screen keyboard ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
    echo -ne "${c_ylw} org.gnome.desktop.a11y.applications screen-keyboard-enabled: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.a11y.applications screen-keyboard-enabled
    echo -ne "${c_rst}"


    echo -e "${c_prpl}>> Disabling screen reader ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false
    echo -ne "${c_ylw} org.gnome.desktop.a11y.applications screen-reader-enabled: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.a11y.applications screen-reader-enabled
    echo -ne "${c_rst}"


    echo -e "${c_prpl}>> Disabling screen magnifier ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled false
    echo -ne "${c_ylw} org.gnome.desktop.a11y.applications screen-magnifier-enabled: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.a11y.applications screen-magnifier-enabled
    echo -ne "${c_rst}"


    echo -e "${c_prpl}>> Setting branding wallpaper ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.background picture-uri https://downloads.coolblock.com/panel/wallpaper.jpg
    echo -ne "${c_ylw} org.gnome.desktop.background picture-uri: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.background picture-uri
    echo -ne "${c_rst}"

    /usr/bin/sudo -u coolblock /usr/bin/gsettings set org.gnome.desktop.background picture-uri-dark https://downloads.coolblock.com/panel/wallpaper.jpg
    echo -ne "${c_ylw} org.gnome.desktop.background picture-uri-dark: "
    /usr/bin/sudo -u coolblock /usr/bin/gsettings get org.gnome.desktop.background picture-uri-dark
    echo -ne "${c_rst}"

    return 0
}

function install_browser() {

    # declare -r user_id=$(/usr/bin/id -u coolblock)

    # export XDG_RUNTIME_DIR="/run/user/${user_id}"
    # export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus"

    echo -e "${c_cyan}>> Installing Mozilla signing key ..${c_rst}"
    /usr/bin/wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
        | /usr/bin/gpg --dearmor \
        | /usr/bin/tee /etc/apt/keyrings/packages.mozilla.org.gpg >/dev/null

    echo -e "${c_prpl}>> Setting up APT preferences for Mozilla Firefox ..${c_rst}"
    {
        echo "Package: firefox*"
        echo "Pin: origin packages.mozilla.org"
        echo "Pin-Priority: 1001"
    } > /etc/apt/preferences.d/mozilla

    echo -e "${c_prpl}>> Setting up APT sources for Mozilla Firefox ..${c_rst}"
    {
        echo "Types: deb"
        echo "URIs: https://packages.mozilla.org/apt"
        echo "Suites: mozilla"
        echo "Components: main"
        echo "Signed-By: /etc/apt/keyrings/packages.mozilla.org.gpg"
    } > /etc/apt/sources.list.d/mozilla.sources

    echo -e "${c_prpl}>> Setting up APT unattended upgrades for Mozilla Firefox ..${c_rst}"
    {
        echo 'Unattended-Upgrade::Origins-Pattern { "archive=mozilla"; };'
    } > /etc/apt/apt.conf.d/51unattended-upgrades-firefox

    echo -e "${c_cyan}>> Installing Mozilla Firefox (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y firefox

    echo -e "${c_prpl}>> Creating Systemd service for Mozilla Firefox in kiosk mode ..${c_rst}"
    {
        echo "[Unit]"
        echo "Description=Coolblock Browser - Mozilla Firefox Service"
        echo "Requires=coolblock-panel.service"
        echo "After=coolblock-panel.service graphical.target"
        echo ""
        echo "[Service]"
        echo "User=coolblock"
        echo "Group=coolblock"
        echo "ExecStart=/bin/bash -c 'while : ; do /usr/bin/pgrep firefox >/dev/null || { ${browser_docker_check_cmd} && ${browser_certs_cmd} && ${browser_cmd} ; } ; /usr/bin/sleep 5; done'"
        echo "Restart=no"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > /etc/systemd/system/coolblock-browser.service
    # fixes "is marked world-inaccessible" systemd log spam
    /usr/bin/chmod 0644 /etc/systemd/system/coolblock-browser.service

    echo -e "${c_prpl}>> Creating Mozilla Firefox policies (based on https://github.com/mozilla/policy-templates/blob/master/linux/policies.json) ..${c_rst}"
    /usr/bin/mkdir -pv /etc/firefox/policies
    {
        echo '{'
        echo '    "policies": {'
        echo '        "CaptivePortal": false,'
        echo '        "DisableBuiltinPDFViewer": true,'
        echo '        "DisableDeveloperTools": true,'
        echo '        "DisableFeedbackCommands": true,'
        echo '        "DisableFirefoxAccounts": true,'
        echo '        "DisableFirefoxScreenshots": true,'
        echo '        "DisableFirefoxStudies": true,'
        echo '        "DisableFormHistory": true,'
        echo '        "DisableMasterPasswordCreation": true,'
        echo '        "DisablePocket": true,'
        echo '        "DisableProfileImport": true,'
        echo '        "DisableTelemetry": true,'
        echo '        "DisplayBookmarksToolbar": "never",'
        echo '        "DontCheckDefaultBrowser": true,'
        echo '        "HardwareAcceleration": true,'
        echo '        "PasswordManagerEnabled": false,'
        echo '        "PrintingEnabled": false,'
        echo '        "BlockAboutSupport": true,'
        echo '        "BlockAboutProfiles": true,'
        echo '        "BlockAboutConfig": true,'
        echo '        "BlockAboutAddons": true,'
        echo '        "BackgroundAppUpdate": true,'
        echo '        "ShowHomeButton": false,'
        echo '        "TranslateEnabled": false,'
        echo '        "SupportMenu": {'
        echo '            "Title": "Coolblock Support Menu",'
        echo '            "URL": "https://coolblock.com",'
        echo '            "AccessKey": "5"'
        echo '        },'
        echo '        "UserMessaging": {'
        echo '            "ExtensionRecommendations": false,'
        echo '            "FeatureRecommendations": false,'
        echo '            "UrlbarInterventions": false,'
        echo '            "SkipOnboarding": true,'
        echo '            "MoreFromMozilla": false,'
        echo '            "FirefoxLabs": false,'
        echo '            "Locked": true'
        echo '        },'
        echo '        "Certificates": {'
        echo '            "Install": ["/home/coolblock/panel/certs/ca.crt"]'
        echo '        }'
        echo '    }'
        echo '}'
    } > /etc/firefox/policies/policies.json

    echo -e "${c_prpl}>> Enabling Mozilla Firefox service to start on boot ..${c_rst}"
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl enable coolblock-browser.service

    return 0
}

function install_panel() {

    # declare -r user_id=$(/usr/bin/id -u coolblock)

    # export XDG_RUNTIME_DIR="/run/user/${user_id}"
    # export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus"

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
        echo -e "${c_red}>> ERROR: Invalid license. Please contact Coolblock staff.${c_rst}" 2>/dev/null
        return 50
    fi
    echo -e "${c_grn}>> License is valid.${c_rst}"

    echo -e "${c_prpl}>> Preparing project structure '${pdir}' ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv "${pdir}/backup" "${pdir}/certs"

    echo -e "${c_prpl}>> Stopping services (if running) ..${c_rst}"
    if [ -f "${pdir}/docker-compose.yml" ]; then
        /usr/bin/systemctl stop coolblock-panel.service \
            || /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Generating certificates (if not already) ..${c_rst}"
    if [ -f "${pdir}/docker-compose.yml" ]; then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" pull proxy
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d proxy
        /usr/bin/timeout 5 /usr/bin/docker compose -f "${pdir}/docker-compose.yml" logs -f proxy || /usr/bin/true
        /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down proxy
    fi

    echo -e "${c_prpl}>> Backing up mysql database (if available) ..${c_rst}"
    if [[ -f "/home/coolblock/.my.cnf" && -f "${pdir}/docker-compose.yml" ]]; then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" pull mysql
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d mysql
        echo -e "${c_ylw}>> Waiting for mysql database ..${c_rst}"
        while :; do
            /usr/bin/sleep 1
            echo -e "${c_grn}>> SELECT updated_at from users where id=1${c_rst}"
            /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel -Bsqe 'SELECT updated_at from users where id=1' && break
        done

        mysql_backup_file="${pdir}/backup/coolblock-panel_$(date +%Y%m%d_%H%M%S).sql"
        mysql_users_backup_file="${pdir}/backup/coolblock-panel_users_$(date +%Y%m%d_%H%M%S).sql"
        /usr/bin/sudo -u coolblock /usr/bin/mysqldump --defaults-file=/home/coolblock/.my.cnf --databases coolblock-panel > "${mysql_backup_file}"
        /usr/bin/sudo -u coolblock /usr/bin/mysqldump --defaults-file=/home/coolblock/.my.cnf --databases coolblock-panel --tables users > "${mysql_users_backup_file}"
        /usr/bin/chown -v coolblock:coolblock "${mysql_backup_file}" "${mysql_users_backup_file}"

        /usr/bin/rm -fv "${pdir}/backup/coolblock-panel.sql" "${pdir}/backup/coolblock-panel_users.sql"
        /usr/bin/sudo -u coolblock ln -sv "${mysql_backup_file}" "${pdir}/backup/coolblock-panel.sql"
        /usr/bin/sudo -u coolblock ln -sv "${mysql_users_backup_file}" "${pdir}/backup/coolblock-panel_users.sql"
    fi

    echo -e "${c_prpl}>> Stopping services (if running) ..${c_rst}"
    if [ -f "${pdir}/docker-compose.yml" ]; then
        /usr/bin/systemctl stop coolblock-panel.service \
            || /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Downloading Docker deployment file ..${c_rst}"
    download "https://downloads.coolblock.com/panel/docker-compose.yml.tmpl" "${pdir}/docker-compose.yml" coolblock
    if [ "${?}" -ne 0 ]; then
        return 60
    fi

    echo -e "${c_prpl}>> Rendering Docker image tags in deployment file ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/sed -i \
        -e "s#__PANEL_WEB_VERSION__#${docker_tags[web]}#g" \
        -e "s#__PANEL_API_VERSION__#${docker_tags[api]}#g" \
        -e "s#__PANEL_PROXY_VERSION__#${docker_tags[proxy]}#g" \
        "${pdir}/docker-compose.yml"

    echo -e "${c_prpl}>> Pulling Docker images (if available) ..${c_rst}"
    if [ -f "${pdir}/.env" ]; then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" pull
    fi

    echo -e "${c_prpl}>> Backing up existing environment file (if available).. ${c_rst}"
    if [ -f "${pdir}/.env" ]; then
        /usr/bin/sudo -u coolblock cp -pv "${pdir}/.env" "${pdir}/.env.bak" 2>/dev/null
    fi

    echo -e "${c_prpl}>> Generating secrets (old ones will be kept, if available).. ${c_rst}"
    if [ -f "${pdir}/.env.bak" ]; then
        old_env=$(/usr/bin/cat "${pdir}/.env.bak")
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
    download "https://downloads.coolblock.com/panel/env.tmpl" "${pdir}/.env" coolblock
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
    download "https://downloads.coolblock.com/panel/init.sql" "${pdir}/init.sql" coolblock
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
        /usr/bin/docker volume rm panel_coolblock-panel-web-database-data
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d mysql
        echo -e "${c_ylw}>> Waiting for mysql database ..${c_rst}"
        while :; do
            /usr/bin/sleep 1
            echo -e "${c_grn}>> SELECT updated_at FROM users WHERE id=1${c_rst}"
            /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel -Bsqe 'SELECT updated_at FROM users WHERE id=1' && break
        done

        /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel < "${pdir}/backup/coolblock-panel_users.sql"
        /usr/bin/systemctl stop coolblock-panel.service \
            || /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Creating Systemd service for Coolblock Panel Core ..${c_rst}"
    {
        echo "[Unit]"
        echo "Description=Coolblock Panel - Core Services"
        echo "Requires=docker.service"
        echo "After=docker.service network-online.target"
        echo ""
        echo "[Service]"
        echo "User=coolblock"
        echo "Group=coolblock"
        # echo "RemainAfterExit=true"
        echo "WorkingDirectory=${pdir}"
        # echo "ExecStart=/bin/bash -c 'docker compose up -d --remove-orphans'"
        echo "ExecStart=/bin/bash -c 'docker compose up --remove-orphans'"
        echo "ExecStop=/bin/bash -c 'docker compose down'"
        echo "Restart=no"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > /etc/systemd/system/coolblock-panel.service
    # fixes "is marked world-inaccessible" systemd log spam
    /usr/bin/chmod 0644 /etc/systemd/system/coolblock-panel.service

    echo -e "${c_prpl}>> Enabling core services to start on boot ..${c_rst}"
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl enable coolblock-panel.service

    return 0
}

function configure_sysctl() {
    echo -e "${c_cyan}>> Disabling Magic SysRq ..${c_rst}"
    {
        echo "# Coolblock Panel - Magic SysRq"
        echo "### DO NOT EDIT ###"
        echo "kernel.sysrq = 0"
    } > /etc/sysctl.d/10-magic-sysrq.conf

    echo -e "${c_cyan}>> Disabling IPv6 ..${c_rst}"
    {
        echo "# Coolblock Panel - IPv6"
        echo "### DO NOT EDIT ###"
        echo "net.ipv6.conf.all.disable_ipv6 = 1"
        echo "net.ipv6.conf.default.disable_ipv6 = 1"
        echo "net.ipv6.conf.lo.disable_ipv6 = 1"
    } > /etc/sysctl.d/10-disable-ipv6.conf

    return 0
}

function configure_network() {
    echo -e "${c_cyan}>> Configuring network ..${c_rst}"
    if [ "${CONFIGURE_NETWORK:-yes}" == "yes" ]; then
        /usr/bin/rm -fv /etc/netplan/*

        {
            echo "# Coolblock Panel - Network"
            echo "### DO NOT EDIT ###"
            echo "network:"
            echo "version: 2"
            echo "renderer: networkd"
            echo "ethernets:"
            echo "  enp1s0:"
            echo "    addresses:"
            echo "      - 10.13.37.41/24"
            echo "    routes:"
            echo "      - to: default"
            echo "        via: 10.13.37.1"
            echo "    nameservers:"
            echo "      addresses:"
            echo "        - 1.1.1.1"
            echo "        - 1.0.0.1"
        } > /etc/netplan/99-coolblock.yaml
    else
        echo -e "${c_ylw}>> Skipping network configuration (CONFIGURE_NETWORK=no) ..${c_rst}"
    fi

    return 0
}

function configure_crons() {
    echo -e "${c_cyan}>> Downloading housekeeping script ..${c_rst}"
    download "https://downloads.coolblock.com/panel/housekeeping.sh" "${pdir}/housekeeping.sh" coolblock

    echo -e "${c_prpl}>> Setting up scheduled tasks ..${c_rst}"
    declare -r cron_housekeeping_file=$(/usr/bin/mktemp)
    {
        echo "# Coolblock Panel - Crons"
        echo "### DO NOT EDIT ###"
        echo "*/5 * * * * /bin/bash ${pdir}/housekeeping.sh --"
    } > "${cron_housekeeping_file}"
    /usr/bin/crontab "${cron_housekeeping_file}"
    /usr/bin/rm -fv "${cron_housekeeping_file}"

    return 0
}

function debloat() {
    echo -e "${c_prpl}>> Disabling unnecessary services ..${c_rst}"
    /usr/bin/systemctl disable wpa_supplicant.service
    /usr/bin/systemctl mask wpa_supplicant.service
    /usr/bin/systemctl disable avahi-daemon.service
    /usr/bin/systemctl mask avahi-daemon.socket
    /usr/bin/systemctl disable --global pipewire
    /usr/bin/systemctl disable --global wireplumber

    echo -e "${c_prpl}>> Blacklisting unnecessary kernel modules ..${c_rst}"
    {
        echo "# Coolblock Panel - Blacklist Kernel Modules"
        echo "### DO NOT EDIT ###"
        echo "blacklist rtlwifi"
        echo "blacklist rtl8188ee"
        echo "blacklist mac80211"
        echo "blacklist cfg80211"
        echo "blacklist soundcore"
        echo "blacklist snd"
        echo "blacklist snd_pcm"
        echo "blacklist snd_pcsp"
        echo "blacklist snd_hda_codec_hdmi"
        echo "blacklist snd_hda_codec_realtek"
        echo "blacklist snd_hda_codec_generic"
        echo "blacklist snd_hda_intel"
        echo "blacklist snd_hda_codec"
        echo "blacklist snd_hda_core"
        echo "blacklist snd_hwdep"
        echo "blacklist snd_timer"
        echo "blacklist pcspkr"
    } > /etc/modprobe.d/coolblock-blacklist.conf

    return 0
}

function cleanup() {
    echo -e "${c_prpl}>> Cleaning up package manager ..${c_rst}"
    /usr/bin/apt autoremove -y
    /usr/bin/apt clean all

    echo -e "${c_prpl}>> Removing installation user ..${c_rst}"
    /usr/sbin/userdel --force --remove ubuntu 2>/dev/null
    /usr/sbin/userdel --force --remove installer 2>/dev/null
    /usr/sbin/userdel --force --remove test 2>/dev/null
    /usr/sbin/userdel --force --remove ci 2>/dev/null

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

    install_docker
    declare -r install_docker_rc="${?}"
    [ "${install_docker_rc}" -ne 0 ] && return "${install_docker_rc}"

    create_user
    declare -r create_user_rc="${?}"
    [ "${create_user_rc}" -ne 0 ] && return "${create_user_rc}"

    install_gui
    declare -r install_gui_rc="${?}"
    [ "${install_gui_rc}" -ne 0 ] && return "${install_gui_rc}"

    install_panel
    declare -r install_panel_rc="${?}"
    [ "${install_panel_rc}" -ne 0 ] && return "${install_panel_rc}"

    install_browser
    declare -r install_browser_rc="${?}"
    [ "${install_browser_rc}" -ne 0 ] && return "${install_browser_rc}"

    configure_crons
    declare -r configure_crons_rc="${?}"
    [ "${configure_crons_rc}" -ne 0 ] && return "${configure_crons_rc}"

    configure_sysctl
    declare -r configure_sysctl_rc="${?}"
    [ "${configure_sysctl_rc}" -ne 0 ] && return "${configure_sysctl_rc}"

    configure_network
    declare -r configure_network_rc="${?}"
    [ "${configure_network_rc}" -ne 0 ] && return "${configure_network_rc}"

    debloat
    declare -r debloat_rc="${?}"
    [ "${debloat_rc}" -ne 0 ] && return "${debloat_rc}"

    cleanup
    declare -r cleanup_rc="${?}"
    [ "${cleanup_rc}" -ne 0 ] && return "${cleanup_rc}"

    return 0
}

main "${@}"
exit "${?}"

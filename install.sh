#! /usr/bin/env bash
# Author: Sotirios Roussis <s.roussis@synapsecom.gr>

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

    if [ "${#}" -eq 0 ]
    then
        echo -e "${c_red}>> ERROR: No arguments specified.${c_rst}" 2>/dev/null
        usage
        return 10
    fi

    # Parse arguments
    while [ "${#}" -gt 0 ]
    do
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
    if [[ -z "${tank_model}" || -z "${plc_model}" || -z "${serial_number}" || -z "${license_key}" ]]
    then
        echo -e "${c_red}>> ERROR: --tank-model, --plc-model, --serial-number, and --license-key are required arguments.${c_rst}" 2>/dev/null
        usage
        return 30
    fi

    return 0
}

function check_os() {

    if [ -f "/etc/os-release" ]
    then
        source /etc/os-release
    else
        echo -e "${c_red}>> ERROR: Unable to determine OS.${c_rst}" 2>/dev/null
        return 200
    fi

    if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]
    then
        echo -e "${c_red}>> ERROR: This script supports only Ubuntu 24.04 LTS.${c_rst}" 2>/dev/null
        echo -e "${c_red}>> Detected OS: ${ID} ${VERSION_ID}${c_rst}" 2>/dev/null
        return 201
    fi

    echo -e "${c_grn}>> Detected supported OS: Ubuntu ${VERSION_ID}${c_rst}"
    return 0
}

function is_root() {

    if [[ "${EUID}" -ne 0 ]]
    then
        echo -e "${c_red}>> ERROR: This script must be run as root.${c_rst}" 2>/dev/null
        return 40
    fi

    return 0
}

function generate_password() {

  declare -r length="${1:-12}"
  /usr/bin/tr -dc 'a-zA-Z0-9.,@_+\-' < /dev/urandom | /usr/bin/head -c "${length}"
  echo
}

function download() {

    declare -r url="${1}"
    declare -r output_file="${2}"
    declare as_user="${3}"
    declare http_status

    if [ -z "${as_user}" ]
    then
        as_user="${USER}"
    fi

    # Download file using curl with error handling
    http_status=$(/usr/bin/sudo -u "${as_user}" /usr/bin/curl --write-out "%{http_code}" --silent --show-error \
                    --location --retry 5 --retry-delay 3 --connect-timeout 10 \
                    --max-time 30 --output "${output_file}" --url "${url}")

    # Check for successful HTTP status codes (200 OK, 206 Partial Content, etc.)
    if [[ "${http_status}" -ge 200 && "${http_status}" -lt 300 ]]
    then
        if [ -s "${output_file}" ]
        then
            echo -e "${c_grn}>> Download successful: '${url}' --> '${output_file}'.${c_rst}"
            return 0
        fi

        echo -e "${c_red}>> ERROR: Downloaded file is empty or missing: '${output_file}'.${c_rst}" 2>/dev/null
        return 1
    elif [[ "${http_status}" -eq 404 ]]
    then
        echo -e "${c_red}>> ERROR: File not found (HTTP 404) at '${url}'.${c_rst}" 2>/dev/null
        return 1
    elif [[ "${http_status}" -ge 400 ]]
    then
        echo -e "${c_red}>> ERROR: HTTP request of '${url}' failed with status code '${http_status}'.${c_rst}" 2>/dev/null
        return 1
    else
        echo -e "${c_red}>> ERROR: Download of '${url}' failed with unknown status code '${http_status}'.${c_rst}" 2>/dev/null
        return 1
    fi
}

function mktmp() {

    declare as_user="${1}"
    declare -r tmpf="/tmp/$(/usr/bin/uuid)"

    if [ -z "${as_user}" ]
    then
        as_user="${USER}"
    fi

    if /usr/bin/sudo -u "${as_user}" /usr/bin/touch "${tmpf}"
    then
        echo "${tmpf}"
        return 0
    fi

    return 235
}

function create_user() {

    declare ssh_authorized_keys=""
    declare tmp_ssh_keys=$(mktmp)

    echo -e "${c_prpl}>> Creating system user 'coolblock' (if required) ..${c_rst}"
    /usr/sbin/useradd --home-dir /home/coolblock --create-home --shell /bin/bash coolblock
    /usr/sbin/usermod -aG adm coolblock
    /usr/sbin/usermod -aG sudo coolblock
    /usr/sbin/usermod -aG docker coolblock
    /usr/bin/chage -I -1 -m 0 -M 99999 -E -1 coolblock

    echo -e "${c_prpl}>> Downloading Coolblock SSH public keys (will merge existing) ..${c_rst}"
    download "https://downloads.coolblock.com/keys" "${tmp_ssh_keys}"
    if [ "${?}" -ne 0 ]
    then
        return 1
    fi

    echo -e "${c_prpl}>> Configuring SSH authorized_keys of 'coolblock' user ..${c_rst}"
    if [ -f "/home/coolblock/.ssh/authorized_keys" ]
    then
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
    /usr/bin/apt install -y \
        sudo cron uuid \
        vim nano \
        iputils-ping net-tools dnsutils tcpdump traceroute \
        git curl wget \
        jq yq \
        ca-certificates openssl gpg \
        mariadb-client \
        libcanberra-gtk-module libcanberra-gtk3-module

    return 0
}

function install_docker() {

    echo -e "${c_cyan}>> Installing Docker (if not installed already) ..${c_rst}"
    if ! hash docker &>/dev/null
    then
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
    if [ ! $(/usr/bin/docker network ls --filter=name=coolblock-panel --quiet) ]
    then
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

function install_kde() {

    echo -e "${c_cyan}>> Installing KDE (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y kubuntu-desktop xdg-utils qtvirtualkeyboard-plugin maliit-keyboard plasma-wayland-protocols plasma-workspace-wayland plasma-mobile-tweaks

    echo -e "${c_prpl}>> Configuring SDDM autologin ..${c_rst}"
    /usr/bin/mkdir -pv /etc/sddm.conf.d
    {
        echo "[Autologin]"
        echo "User=coolblock"
        echo "Session=plasmawayland"
    } | /usr/bin/tee /etc/sddm.conf.d/autologin.conf

    echo -e "${c_prpl}>> Configuring shell environment ..${c_rst}"
    {
        echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"'
        echo 'QT_QUICK_CONTROLS_STYLE=org.kde.desktop'
    } | /usr/bin/tee /etc/environment

    echo -e "${c_prpl}>> Preparing user namespace configuration directory ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv /home/coolblock/.config /home/coolblock/.config/autostart /home/coolblock/.config/gtk-3.0 /home/coolblock/.config/gtk-4.0

    echo -e "${c_prpl}>> Customizing GTK ..${c_rst}"
    {
        echo '[Settings]'
        echo 'gtk-application-prefer-dark-theme=true'
        echo 'gtk-button-images=true'
        echo 'gtk-cursor-theme-name=breeze_cursors'
        echo 'gtk-cursor-theme-size=24'
        echo 'gtk-decoration-layout=icon:minimize,maximize,close'
        echo 'gtk-enable-animations=true'
        echo 'gtk-font-name=Noto Sans,  10'
        echo 'gtk-icon-theme-name=breeze-dark'
        echo 'gtk-menu-images=true'
        echo 'gtk-modules=colorreload-gtk-module:window-decorations-gtk-module'
        echo 'gtk-primary-button-warps-slider=false'
        echo 'gtk-theme-name=Breeze'
        echo 'gtk-toolbar-style=3'
        echo 'gtk-xft-dpi=98304'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/gtk-3.0/settings.ini
    {
        echo '[Settings]'
        echo 'gtk-application-prefer-dark-theme=true'
        echo 'gtk-cursor-theme-name=breeze_cursors'
        echo 'gtk-cursor-theme-size=24'
        echo 'gtk-decoration-layout=icon:minimize,maximize,close'
        echo 'gtk-enable-animations=true'
        echo 'gtk-font-name=Noto Sans,  10'
        echo 'gtk-icon-theme-name=breeze-dark'
        echo 'gtk-modules=colorreload-gtk-module:window-decorations-gtk-module'
        echo 'gtk-primary-button-warps-slider=false'
        echo 'gtk-xft-dpi=98304'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/gtk-4.0/settings.ini

    echo -e "${c_prpl}>> Customizing KDE globals ..${c_rst}"
    {
        echo '[General]'
        echo 'ColorScheme=BreezeDark'
        echo ''
        echo '[Icons]'
        echo 'Theme=breeze-dark'
        echo ''
        echo '[KDE]'
        echo 'widgetStyle=Breeze'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/kdedefaults/kdeglobals
    {
        echo '[$Version]'
        echo 'update_info=filepicker.upd:filepicker-remove-old-previews-entry,fonts_global.upd:Fonts_Global,fonts_global_toolbar.upd:Fonts_Global_Toolbar,icons_remove_effects.upd:IconsRemoveEffects,kwin.upd:animation-speed,style_widgetstyle_default_breeze.upd:StyleWidgetStyleDefaultBreeze'
        echo ''
        echo '[ColorEffects:Disabled]'
        echo 'ChangeSelectionColor='
        echo 'Color=56,56,56'
        echo 'ColorAmount=0'
        echo 'ColorEffect=0'
        echo 'ContrastAmount=0.65'
        echo 'ContrastEffect=1'
        echo 'Enable='
        echo 'IntensityAmount=0.1'
        echo 'IntensityEffect=2'
        echo ''
        echo '[ColorEffects:Inactive]'
        echo 'ChangeSelectionColor=true'
        echo 'Color=112,111,110'
        echo 'ColorAmount=0.025'
        echo 'ColorEffect=2'
        echo 'ContrastAmount=0.1'
        echo 'ContrastEffect=2'
        echo 'Enable=false'
        echo 'IntensityAmount=0'
        echo 'IntensityEffect=0'
        echo ''
        echo '[Colors:Button]'
        echo 'BackgroundAlternate=30,87,116'
        echo 'BackgroundNormal=49,54,59'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=61,174,233'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=29,153,243'
        echo 'ForegroundNegative=218,68,83'
        echo 'ForegroundNeutral=246,116,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=39,174,96'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[Colors:Complementary]'
        echo 'BackgroundAlternate=30,87,116'
        echo 'BackgroundNormal=42,46,50'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=61,174,233'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=29,153,243'
        echo 'ForegroundNegative=218,68,83'
        echo 'ForegroundNeutral=246,116,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=39,174,96'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[Colors:Header]'
        echo 'BackgroundAlternate=42,46,50'
        echo 'BackgroundNormal=49,54,59'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=61,174,233'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=29,153,243'
        echo 'ForegroundNegative=218,68,83'
        echo 'ForegroundNeutral=246,116,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=39,174,96'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[Colors:Header][Inactive]'
        echo 'BackgroundAlternate=49,54,59'
        echo 'BackgroundNormal=42,46,50'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=61,174,233'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=29,153,243'
        echo 'ForegroundNegative=218,68,83'
        echo 'ForegroundNeutral=246,116,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=39,174,96'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[Colors:Selection]'
        echo 'BackgroundAlternate=30,87,116'
        echo 'BackgroundNormal=61,174,233'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=252,252,252'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=253,188,75'
        echo 'ForegroundNegative=176,55,69'
        echo 'ForegroundNeutral=198,92,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=23,104,57'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[Colors:Tooltip]'
        echo 'BackgroundAlternate=42,46,50'
        echo 'BackgroundNormal=49,54,59'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=61,174,233'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=29,153,243'
        echo 'ForegroundNegative=218,68,83'
        echo 'ForegroundNeutral=246,116,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=39,174,96'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[Colors:View]'
        echo 'BackgroundAlternate=35,38,41'
        echo 'BackgroundNormal=27,30,32'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=61,174,233'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=29,153,243'
        echo 'ForegroundNegative=218,68,83'
        echo 'ForegroundNeutral=246,116,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=39,174,96'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[Colors:Window]'
        echo 'BackgroundAlternate=49,54,59'
        echo 'BackgroundNormal=42,46,50'
        echo 'DecorationFocus=61,174,233'
        echo 'DecorationHover=61,174,233'
        echo 'ForegroundActive=61,174,233'
        echo 'ForegroundInactive=161,169,177'
        echo 'ForegroundLink=29,153,243'
        echo 'ForegroundNegative=218,68,83'
        echo 'ForegroundNeutral=246,116,0'
        echo 'ForegroundNormal=252,252,252'
        echo 'ForegroundPositive=39,174,96'
        echo 'ForegroundVisited=155,89,182'
        echo ''
        echo '[General]'
        echo 'BrowserApplication=!angelfish'
        echo 'ColorSchemeHash=32dc6f7a92bd354a14bcf38f7991e8de66fed1fe'
        echo ''
        echo '[KDE]'
        echo 'LookAndFeelPackage=org.kde.breezedark.desktop'
        echo ''
        echo '[KFileDialog Settings]'
        echo 'Allow Expansion=false'
        echo 'Automatically select filename extension=true'
        echo 'Breadcrumb Navigation=true'
        echo 'Decoration position=2'
        echo 'LocationCombo Completionmode=5'
        echo 'PathCombo Completionmode=5'
        echo 'Show Bookmarks=false'
        echo 'Show Full Path=false'
        echo 'Show Inline Previews=true'
        echo 'Show Preview=false'
        echo 'Show Speedbar=true'
        echo 'Show hidden files=false'
        echo 'Sort by=Name'
        echo 'Sort directories first=true'
        echo 'Sort hidden files last=false'
        echo 'Sort reversed=false'
        echo 'Speedbar Width=138'
        echo 'View Style=DetailTree'
        echo ''
        echo '[WM]'
        echo 'activeBackground=49,54,59'
        echo 'activeBlend=252,252,252'
        echo 'activeForeground=252,252,252'
        echo 'inactiveBackground=42,46,50'
        echo 'inactiveBlend=161,169,177'
        echo 'inactiveForeground=161,169,177'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/kdeglobals

    echo -e "${c_prpl}>> Customizing KDE window manager ..${c_rst}"
    {
        echo '[$Version]'
        echo 'update_info=kwin.upd:replace-scalein-with-scale,kwin.upd:port-minimizeanimation-effect-to-js,kwin.upd:port-scale-effect-to-js,kwin.upd:port-dimscreen-effect-to-js,kwin.upd:auto-bordersize,kwin.upd:animation-speed,kwin.upd:desktop-grid-click-behavior,kwin.upd:no-swap-encourage,kwin.upd:make-translucency-effect-disabled-by-default,kwin.upd:remove-flip-switch-effect,kwin.upd:remove-cover-switch-effect,kwin.upd:remove-cubeslide-effect,kwin.upd:remove-xrender-backend,kwin.upd:enable-scale-effect-by-default,kwin.upd:overview-group-plugin-id,kwin.upd:animation-speed-cleanup,kwin.upd:replace-cascaded-zerocornered'
        echo ''
        echo '[Effect-desktopgrid]'
        echo 'LayoutMode=1'
        echo ''
        echo '[Effect-presentwindows]'
        echo 'LayoutMode=1'
        echo ''
        echo '[Wayland]'
        echo 'InputMethod[$e]=/usr/share/applications/com.github.maliit.keyboard.desktop'
        echo ''
        echo '[Windows]'
        echo 'ElectricBorderMaximize=false'
        echo 'ElectricBorderTiling=false'
        echo ''
        echo '[Xwayland]'
        echo 'Scale=1'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/kwinrc

    echo -e "${c_prpl}>> Customizing KDE applet ..${c_rst}"
    download "https://downloads.coolblock.com/panel/logo.svg" "/home/coolblock/logo.svg" coolblock
    download "https://downloads.coolblock.com/panel/wallpaper.jpg" "/home/coolblock/wallpaper.jpg" coolblock
    {
        echo '[ActionPlugins][0]'
        echo 'RightButton;NoModifier=org.kde.contextmenu'
        echo 'wheel:Vertical;NoModifier=org.kde.switchdesktop'
        echo ''
        echo '[ActionPlugins][1]'
        echo 'RightButton;NoModifier=org.kde.contextmenu'
        echo ''
        echo '[Containments][1]'
        echo 'ItemGeometries-1024x768='
        echo 'ItemGeometriesHorizontal='
        echo 'activityId=b462267a-270f-45b4-8122-14b96ec5a40b'
        echo 'formfactor=0'
        echo 'immutability=1'
        echo 'lastScreen=0'
        echo 'location=0'
        echo 'plugin=org.kde.plasma.folder'
        echo 'wallpaperplugin=org.kde.image'
        echo ''
        echo '[Containments][1][ConfigDialog]'
        echo 'DialogHeight=540'
        echo 'DialogWidth=720'
        echo ''
        echo '[Containments][1][General]'
        echo 'filterMimeTypes=\\0'
        echo 'iconSize=5'
        echo ''
        echo '[Containments][1][Wallpaper][org.kde.image][General]'
        echo 'Image=/home/coolblock/wallpaper.jpg'
        echo 'SlidePaths=/usr/share/wallpapers/'
        echo ''
        echo '[Containments][2]'
        echo 'activityId='
        echo 'formfactor=2'
        echo 'immutability=1'
        echo 'lastScreen=0'
        echo 'location=4'
        echo 'plugin=org.kde.panel'
        echo 'wallpaperplugin=org.kde.image'
        echo ''
        echo '[Containments][2][Applets][19]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.digitalclock'
        echo ''
        echo '[Containments][2][Applets][20]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.showdesktop'
        echo ''
        echo '[Containments][2][Applets][3]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.kickoff'
        echo ''
        echo '[Containments][2][Applets][3][Configuration]'
        echo 'PreloadWeight=100'
        echo 'popupHeight=514'
        echo 'popupWidth=651'
        echo ''
        echo '[Containments][2][Applets][3][Configuration][ConfigDialog]'
        echo 'DialogHeight=378'
        echo 'DialogWidth=720'
        echo ''
        echo '[Containments][2][Applets][3][Configuration][General]'
        echo 'favoritesPortedToKAstats=true'
        echo 'icon=/home/coolblock/logo.svg'
        echo 'menuLabel=COOLBLOCK'
        echo 'systemFavorites=suspend\\,hibernate\\,reboot\\,shutdown'
        echo ''
        echo '[Containments][2][Applets][3][Configuration][Shortcuts]'
        echo 'global=Alt+F1'
        echo ''
        echo '[Containments][2][Applets][3][Shortcuts]'
        echo 'global=Alt+F1'
        echo ''
        echo '[Containments][2][Applets][4]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.pager'
        echo ''
        echo '[Containments][2][Applets][5]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.icontasks'
        echo ''
        echo '[Containments][2][Applets][5][Configuration][General]'
        echo 'launchers=applications:systemsettings.desktop,file:///home/coolblock/.config/autostart/coolblock-browser.desktop'
        echo ''
        echo '[Containments][2][Applets][6]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.marginsseparator'
        echo ''
        echo '[Containments][2][Applets][7]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.systemtray'
        echo ''
        echo '[Containments][2][Applets][7][Configuration]'
        echo 'PreloadWeight=70'
        echo 'SystrayContainmentId=8'
        echo ''
        echo '[Containments][2][General]'
        echo 'AppletOrder=3;4;5;6;7;19;20'
        echo ''
        echo '[Containments][8]'
        echo 'activityId='
        echo 'formfactor=2'
        echo 'immutability=1'
        echo 'lastScreen=0'
        echo 'location=4'
        echo 'plugin=org.kde.plasma.private.systemtray'
        echo 'popupHeight=432'
        echo 'popupWidth=432'
        echo 'wallpaperplugin=org.kde.image'
        echo ''
        echo '[Containments][8][Applets][10][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][11][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][12][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][13][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][14][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][15][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][16][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][17][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][18][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][21][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][22][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][Applets][23]'
        echo 'immutability=1'
        echo 'plugin=org.kde.plasma.networkmanagement'
        echo ''
        echo '[Containments][8][Applets][9][Configuration]'
        echo 'PreloadWeight=42'
        echo ''
        echo '[Containments][8][ConfigDialog]'
        echo 'DialogHeight=540'
        echo 'DialogWidth=720'
        echo ''
        echo '[Containments][8][General]'
        echo 'extraItems=org.kde.plasma.networkmanagement'
        echo 'iconSpacing=6'
        echo 'knownItems=org.kde.plasma.bluetooth,org.kde.kupapplet,org.kde.plasma.volume,org.kde.plasma.networkmanagement,org.kde.plasma.keyboardindicator,org.kde.plasma.nightcolorcontrol,org.kde.plasma.manage-inputmethod,org.kde.plasma.devicenotifier,org.kde.plasma.vault,org.kde.plasma.keyboardlayout,org.kde.plasma.clipboard,org.kde.plasma.mediacontroller,org.kde.plasma.notifications,org.kde.plasma.battery,org.kde.plasma.printmanager,org.kde.kscreen'
        echo 'scaleIconsToFit=true'
        echo 'shownItems=org.kde.plasma.networkmanagement'
        echo ''
        echo '[ScreenMapping]'
        echo 'itemsOnDisabledScreens='
        echo 'screenMapping='
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/plasma-org.kde.plasma.desktop-appletsrc
    {
        echo '#! /usr/bin/env bash'
        echo ''
        echo "/usr/bin/qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript '"
        echo '    var allDesktops = desktops();'
        echo '    for (i=0;i<allDesktops.length;i++)'
        echo '    {'
        echo '        d = allDesktops[i];'
        echo '        d.wallpaperPlugin = "org.kde.image";'
        echo '        d.currentConfigGroup = Array("Wallpaper", "org.kde.image", "General");'
        echo '        d.writeConfig("Image", "file:///home/coolblock/wallpaper.jpg")'
        echo '    }'
        echo "'"
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/wallpaper.sh
    /usr/bin/chmod -v 0750 /home/coolblock/wallpaper.sh
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Name=Coolblock Wallpaper"
        echo "Comment=Coolblock Wallpaper"
        echo "Exec=/home/coolblock/wallpaper.sh"
        echo "X-GNOME-Autostart-enabled=true"
        echo "Terminal=false"
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/autostart/coolblock-wallpaper.desktop

    echo -e "${c_prpl}>> Configuring KDE power management ..${c_rst}"
    {
        echo '[AC]'
        echo 'icon=battery-charging'
        echo ''
        echo '[AC][DimDisplay]'
        echo 'idleTime=300000'
        echo ''
        echo '[Battery]'
        echo 'icon=battery-060'
        echo ''
        echo '[Battery][DPMSControl]'
        echo 'idleTime=300'
        echo 'lockBeforeTurnOff=0'
        echo ''
        echo '[Battery][DimDisplay]'
        echo 'idleTime=120000'
        echo ''
        echo '[Battery][HandleButtonEvents]'
        echo 'lidAction=1'
        echo 'powerButtonAction=16'
        echo 'powerDownAction=16'
        echo ''
        echo '[Battery][SuspendSession]'
        echo 'idleTime=600000'
        echo 'suspendThenHibernate=false'
        echo 'suspendType=1'
        echo ''
        echo '[LowBattery]'
        echo 'icon=battery-low'
        echo ''
        echo '[LowBattery][BrightnessControl]'
        echo 'value=30'
        echo ''
        echo '[LowBattery][DPMSControl]'
        echo 'idleTime=120'
        echo 'lockBeforeTurnOff=0'
        echo ''
        echo '[LowBattery][DimDisplay]'
        echo 'idleTime=60000'
        echo ''
        echo '[LowBattery][HandleButtonEvents]'
        echo 'lidAction=1'
        echo 'powerButtonAction=16'
        echo 'powerDownAction=16'
        echo ''
        echo '[LowBattery][SuspendSession]'
        echo 'idleTime=300000'
        echo 'suspendThenHibernate=false'
        echo 'suspendType=1'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/powermanagementprofilesrc

    echo -e "${c_prpl}>> Configuring KDE screen locker ..${c_rst}"
    {
        echo '[Daemon]'
        echo 'Autolock=false'
        echo 'LockOnResume=false'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/kscreenlockerrc

    echo -e "${c_prpl}>> Configuring KDE welcome screen ..${c_rst}"
    {
        echo '[General]'
        echo 'ShouldShow=false'
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/plasma-welcomerc

    return 0
}

function install_gnome() {

    declare -r user_id=$(/usr/bin/id -u coolblock)

    export DISPLAY=":0"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${user_id}/bus"
    export XDG_RUNTIME_DIR="/run/user/${user_id}"

    echo -e "${c_cyan}>> Installing Gnome (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y gnome-session gdm3 xdotool xdg-utils dbus-x11 policykit-1

    echo -e "${c_prpl}>> Configuring GDM autologin ..${c_rst}"
    /usr/bin/mkdir -pv /etc/gdm3/
    {
        echo "[chooser]"
        echo "Multicast=false"
        echo
        echo "[daemon]"
        echo "AutomaticLoginEnable=true"
        echo "AutomaticLogin=coolblock"
        # echo "WaylandEnable=false"
        echo
        echo "[security]"
        echo "DisallowTCP=true"
        echo
        echo "[xdmcp]"
        echo "Enable=false"
    } > /etc/gdm3/custom.conf

    echo -e "${c_prpl}>> Tweaking Gnome ..${c_rst}"
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.shell disable-user-extensions true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.mutter dynamic-workspaces false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.session idle-delay 0
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.screensaver lock-enabled false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.wm.preferences num-workspaces 1
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.wm.preferences audible-bell false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.wm.preferences action-double-click-titlebar 'none'
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.wm.preferences action-middle-click-titlebar 'none'
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.wm.preferences action-right-click-titlebar 'none'
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.wm.preferences auto-raise true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.interface enable-hot-corners false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.interface cursor-size 0
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.a11y.applications always-show-universal-access-status true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.a11y.applications screen-magnifier-enabled false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.peripherals.touchpad disable-while-typing false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.background picture-uri https://downloads.coolblock.com/panel/wallpaper.jpg
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.background picture-uri-dark https://downloads.coolblock.com/panel/wallpaper.jpg
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.sound event-sounds false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.privacy disable-camera true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.privacy disable-microphone true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.privacy disable-sound-output true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.privacy old-files-age 1
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.privacy usb-protection false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.lockdown disable-print-setup true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.lockdown disable-printing true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.lockdown disable-user-switching true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.lockdown disable-log-out true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.lockdown disable-lock-screen true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.lockdown mount-removable-storage-devices-as-read-only true
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.media-handling automount false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.media-handling automount-open false
    /usr/bin/sudo -E -u coolblock /usr/bin/gsettings set org.gnome.desktop.notifications show-banners false

    # echo -e "${c_cyan}>> Installing Unclutter (if not installed already) ..${c_rst}"
    # /usr/bin/apt update
    # /usr/bin/apt install -y unclutter-xfixes

    # echo -e "${c_cyan}>> Installing Touchegg for screen gestures (if not installed already) ..${c_rst}"
    # echo 'precedence ::ffff:0:0/96  100' > /etc/gai.conf  # fixes ppa hung
    # /usr/bin/add-apt-repository --yes --no-update ppa:touchegg/stable
    # /usr/bin/apt update
    # /usr/bin/apt install -y touchegg
    # /usr/bin/gnome-extensions install https://extensions.gnome.org/extension-data/x11gesturesjoseexposito.github.io.v24.shell-extension.zip

    # echo -e "${c_prpl}>> Configuring screen gestures ..${c_rst}"
    # /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv /home/coolblock/.config/touchegg
    # {
    #     echo '<touchégg>'

    #     echo '  <gesture type="TAP" fingers="1">'
    #     echo '    <action type="MOUSE" button="LEFT"/>'
    #     echo '  </gesture>'

    #     echo '  <gesture type="TAP" fingers="2">'
    #     echo '    <action type="MOUSE" button="RIGHT"/>'
    #     echo '  </gesture>'

    #     echo '  <gesture type="DRAG" fingers="2" direction="ALL">'
    #     echo '    <action type="SCROLL"/>'
    #     echo '  </gesture>'

    #     echo '  <gesture type="SWIPE" fingers="3" direction="DOWN">'
    #     echo '    <action type="KEYSTROKE">CTRL+R</action>'
    #     echo '  </gesture>'

    #     echo '</touchégg>'
    # } > /home/coolblock/.config/touchegg/touchegg.conf
    # /usr/bin/chown -v coolblock:coolblock /home/coolblock/.config/touchegg/touchegg.conf

    # echo -e "${c_prpl}>> Enabling screen gestures ..${c_rst}"
    # /usr/bin/systemctl enable touchegg

    return 0
}

function install_firefox() {

    echo -e "${c_cyan}>> Uninstalling previous Mozilla Firefox (if any) ..${c_rst}"
    /usr/bin/apt remove -y --purge firefox*

    echo -e "${c_cyan}>> Installing Mozilla signing key ..${c_rst}"
    /usr/bin/wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
        | /usr/bin/gpg --dearmor \
        | /usr/bin/tee /etc/apt/keyrings/packages.mozilla.org.gpg >/dev/null
    /usr/bin/chmod 0644 /etc/apt/keyrings/packages.mozilla.org.gpg
    /usr/bin/rm -fv /etc/apt/keyrings/packages.mozilla.org.asc

    echo -e "${c_prpl}>> Setting up APT preferences for Mozilla Firefox ..${c_rst}"
    {
        echo "Package: firefox*"
        echo "Pin: origin packages.mozilla.org"
        echo "Pin-Priority: 1001"
    } | /usr/bin/tee /etc/apt/preferences.d/mozilla

    echo -e "${c_prpl}>> Setting up APT sources for Mozilla Firefox ..${c_rst}"
    {
        echo "Types: deb"
        echo "URIs: https://packages.mozilla.org/apt"
        echo "Suites: mozilla"
        echo "Components: main"
        echo "Signed-By: /etc/apt/keyrings/packages.mozilla.org.gpg"
    } | /usr/bin/tee /etc/apt/sources.list.d/mozilla.sources

    echo -e "${c_prpl}>> Setting up APT unattended upgrades for Mozilla Firefox ..${c_rst}"
    {
        echo 'Unattended-Upgrade::Origins-Pattern { "archive=mozilla"; };'
    } | /usr/bin/tee /etc/apt/apt.conf.d/51unattended-upgrades-firefox

    echo -e "${c_cyan}>> Installing Mozilla Firefox (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y firefox

    echo -e "${c_cyan}>> Downloading browser script ..${c_rst}"
    download "https://downloads.coolblock.com/panel/browser.sh" "${pdir}/browser.sh" coolblock
    if [ "${?}" -ne 0 ]
    then
        return 169
    fi
    /usr/bin/chmod -v 0750 "${pdir}/browser.sh"

    /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv /home/coolblock/.config/autostart
    download "https://downloads.coolblock.com/panel/app.png" "/home/coolblock/app.png" coolblock
    echo -e "${c_prpl}>> Creating autostart entry for Mozilla Firefox in kiosk mode ..${c_rst}"
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Name=Coolblock Browser - Panel"
        echo "Comment=Coolblock Browser - Panel"
        echo "Exec=/home/coolblock/panel/browser.sh firefox"
        echo "X-GNOME-Autostart-enabled=true"
        echo "Terminal=true"
        echo "Icon=/home/coolblock/app.png"
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.config/autostart/coolblock-browser.desktop

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
        echo '            "Install": ["/home/coolblock/panel/certs/localhost.ca.crt"]'
        echo '        }'
        echo '    }'
        echo '}'
    } | /usr/bin/tee /etc/firefox/policies/policies.json
    /usr/bin/chmod -Rv a=rx /etc/firefox
    /usr/bin/chmod -v a-x /etc/firefox/policies/policies.json

    return 0
}

function install_chromium() {

    echo -e "${c_cyan}>> Installing Chromium (if not installed already) ..${c_rst}"
    /usr/bin/apt update
    /usr/bin/apt install -y chromium-browser

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
    if ! /usr/bin/grep -qi "login succeed" <<< "${docker_login}"
    then
        echo -e "${c_red}>> ERROR: Invalid license. Please contact Coolblock staff.${c_rst}" 2>/dev/null
        return 50
    fi
    echo -e "${c_grn}>> License is valid.${c_rst}"

    echo -e "${c_prpl}>> Preparing project structure '${pdir}' ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/mkdir -pv "${pdir}/backup" "${pdir}/certs"

    echo -e "${c_prpl}>> Stopping services (if running) ..${c_rst}"
    if [ -f "${pdir}/docker-compose.yml" ]
    then
        /usr/bin/systemctl stop coolblock-panel.service
        /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Generating certificates (if not already) ..${c_rst}"
    if [ -f "${pdir}/docker-compose.yml" ]
    then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" pull proxy
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d proxy
        /usr/bin/timeout 5 /usr/bin/docker compose -f "${pdir}/docker-compose.yml" logs -f proxy || /usr/bin/true
        /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down proxy
    fi

    echo -e "${c_prpl}>> Backing up mysql database (if available) ..${c_rst}"
    if [[ -f "/home/coolblock/.my.cnf" && -f "${pdir}/docker-compose.yml" ]]
    then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" pull mysql
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d mysql
        echo -e "${c_ylw}>> Waiting for mysql database ..${c_rst}"
        while /usr/bin/true
        do
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
    if [ -f "${pdir}/docker-compose.yml" ]
    then
        /usr/bin/systemctl stop coolblock-panel.service
        /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Downloading Docker deployment file ..${c_rst}"
    download "https://downloads.coolblock.com/panel/docker-compose.yml.tmpl" "${pdir}/docker-compose.yml" coolblock
    if [ "${?}" -ne 0 ]
    then
        return 60
    fi

    echo -e "${c_prpl}>> Rendering Docker image tags in deployment file ..${c_rst}"
    /usr/bin/sudo -u coolblock /usr/bin/sed -i \
        -e "s#__PANEL_WEB_VERSION__#${docker_tags[web]}#g" \
        -e "s#__PANEL_API_VERSION__#${docker_tags[api]}#g" \
        -e "s#__PANEL_PROXY_VERSION__#${docker_tags[proxy]}#g" \
        "${pdir}/docker-compose.yml"

    echo -e "${c_prpl}>> Pulling Docker images (if available) ..${c_rst}"
    if [ -f "${pdir}/.env" ]
    then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" pull
    fi

    echo -e "${c_prpl}>> Backing up existing environment file (if available).. ${c_rst}"
    if [ -f "${pdir}/.env" ]
    then
        /usr/bin/sudo -u coolblock cp -pv "${pdir}/.env" "${pdir}/.env.bak" 2>/dev/null
    fi

    echo -e "${c_prpl}>> Generating secrets (old ones will be kept, if available).. ${c_rst}"
    if [ -f "${pdir}/.env.bak" ]
    then
        old_env=$(/usr/bin/cat "${pdir}/.env.bak")
        jwt_secret=$(/usr/bin/awk -F= '/^CB_PANEL_JWT_SECRET/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        mysql_password=$(/usr/bin/awk -F= '/^MYSQL_PASSWORD/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        mysql_root_password=$(/usr/bin/awk -F= '/^MYSQL_ROOT_PASSWORD/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        influxdb_password=$(/usr/bin/awk -F= '/^DOCKER_INFLUXDB_INIT_PASSWORD/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
        influxdb_token=$(/usr/bin/awk -F= '/^DOCKER_INFLUXDB_INIT_ADMIN_TOKEN/{print $2}' <<< "${old_env}" | /usr/bin/tr -d "'\n")
    else
        jwt_secret=$(generate_password 128 | /usr/bin/tr -d '\n')
        mysql_password=$(generate_password 16 | /usr/bin/tr -d '\n')
        mysql_root_password=$(generate_password 16 | /usr/bin/tr -d '\n')
        influxdb_password=$(generate_password 16 | /usr/bin/tr -d '\n')
        influxdb_token=$(generate_password 32 | /usr/bin/tr -d '\n')
    fi

    echo -e "${c_prpl}>> Downloading environment file ..${c_rst}"
    download "https://downloads.coolblock.com/panel/env.tmpl" "${pdir}/.env" coolblock
    if [ "${?}" -ne 0 ]
    then
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
    if [ "${?}" -ne 0 ]
    then
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
    } | /usr/bin/sudo -u coolblock /usr/bin/tee /home/coolblock/.my.cnf
    /usr/bin/chmod -v 0600 /home/coolblock/.my.cnf

    echo -e "${c_prpl}>> Patching mysql database and restoring users (if applicable) ..${c_rst}"
    if [[ -f "${pdir}/backup/coolblock-panel.sql" && -f "${pdir}/backup/coolblock-panel_users.sql" ]]
    then
        /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down mysql
        /usr/bin/docker volume rm panel_coolblock-panel-web-database-data
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d mysql

        echo -e "${c_ylw}>> Waiting for mysql database ..${c_rst}"
        while /usr/bin/true
        do
            /usr/bin/sleep 1
            echo -e "${c_grn}>> SELECT updated_at FROM users WHERE id=1${c_rst}"
            /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel -Bsqe 'SELECT updated_at FROM users WHERE id=1' && break
        done

        /usr/bin/sudo -u coolblock /usr/bin/mysql --defaults-file=/home/coolblock/.my.cnf coolblock-panel < "${pdir}/backup/coolblock-panel_users.sql"
        /usr/bin/systemctl stop coolblock-panel.service
        /usr/bin/docker compose -f "${pdir}/docker-compose.yml" down
    fi

    echo -e "${c_prpl}>> Initializing database (if applicable) ..${c_rst}"
    if ! /usr/bin/docker volume ls | /usr/bin/grep panel_coolblock-panel-web-database-data
    then
        /usr/bin/sudo -u coolblock /usr/bin/docker compose -f "${pdir}/docker-compose.yml" up -d mysql
        while ! /usr/bin/docker ps | /usr/bin/grep "(healthy)"
        do
            echo -e "${c_ylw}>> Waiting for database to become healthy .."
            /usr/bin/sleep 1
        done
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
        echo "WorkingDirectory=${pdir}"
        echo "ExecStart=/bin/bash -c 'docker compose up --remove-orphans'"
        echo "ExecStop=/bin/bash -c 'docker compose down'"
        echo "Restart=no"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } | /usr/bin/tee /etc/systemd/system/coolblock-panel.service
    # fixes "is marked world-inaccessible" systemd log spam
    /usr/bin/chmod 0644 /etc/systemd/system/coolblock-panel.service

    echo -e "${c_prpl}>> Enabling core services to start on boot ..${c_rst}"
    /usr/bin/systemctl daemon-reload
    /usr/bin/systemctl enable coolblock-panel.service

    return 0
}

function configure_grub() {

    echo -e "${c_prpl}>> Configuring GRUB ..${c_rst}"
    /usr/bin/sed -i \
        -e 's#^GRUB_CMDLINE_LINUX_DEFAULT=.*$#GRUB_CMDLINE_LINUX_DEFAULT="quiet splash ipv6.disable=1 ipv6.disable_ipv6=1"#g' \
        /etc/default/grub

    if ! /usr/sbin/update-grub
    then
        return 212
    fi

    return 0
}

function configure_sysctl() {

    echo -e "${c_prpl}>> Tweaking kernel settings ..${c_rst}"
    {
        echo "# Coolblock Panel - Magic SysRq"
        echo "### DO NOT EDIT ###"
        echo "kernel.sysrq = 0"
        echo "net.ipv6.conf.all.disable_ipv6 = 1"
        echo "net.ipv6.conf.default.disable_ipv6 = 1"
        echo "net.ipv6.conf.lo.disable_ipv6 = 1"
    } | /usr/bin/tee /etc/sysctl.conf
    /usr/sbin/sysctl -p /etc/sysctl.conf
    /usr/sbin/sysctl -w net.ipv6.conf.all.disable_ipv6=1
    /usr/sbin/sysctl -w net.ipv6.conf.default.disable_ipv6=1
    /usr/sbin/sysctl -w net.ipv6.conf.lo.disable_ipv6=1

    return 0
}

function configure_network() {

    echo -e "${c_cyan}>> Configuring network ..${c_rst}"
    if [ "${CONFIGURE_NETWORK:-yes}" == "yes" ]
    then
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
        } | /usr/bin/tee /etc/netplan/99-coolblock.yaml
    else
        echo -e "${c_ylw}>> Skipping network configuration (CONFIGURE_NETWORK=no) ..${c_rst}"
    fi

    return 0
}

function configure_crons() {

    echo -e "${c_cyan}>> Downloading housekeeping script ..${c_rst}"
    download "https://downloads.coolblock.com/panel/housekeeping.sh" "${pdir}/housekeeping.sh" coolblock
    if [ "${?}" -ne 0 ]
    then
        return 156
    fi

    echo -e "${c_prpl}>> Setting up scheduled tasks ..${c_rst}"
    declare -r cron_housekeeping_file=$(mktmp)
    {
        echo "# Coolblock Panel - Crons"
        echo "### DO NOT EDIT ###"
        echo "*/5 * * * * /bin/bash ${pdir}/housekeeping.sh --"
    } | /usr/bin/tee "${cron_housekeeping_file}"
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
    /usr/bin/systemctl disable bluetooth.service
    /usr/bin/systemctl mask bluetooth.service
    /usr/bin/systemctl disable cups.service cups.socket cups.path cups-browsed.service
    /usr/bin/systemctl mask cups.service cups.socket cups.path cups-browsed.service
    /usr/bin/systemctl disable ModemManager.service
    /usr/bin/systemctl mask ModemManager.service
    /usr/bin/systemctl disable ubuntu-advantage.service
    /usr/bin/systemctl mask ubuntu-advantage.service
    /usr/bin/systemctl disable ufw.service
    /usr/bin/systemctl mask ufw.service
    /usr/bin/systemctl disable apport.service
    /usr/bin/systemctl mask apport.service
    /usr/bin/systemctl disable snapd.service snapd.socket snapd.apparmor.service snapd.autoimport.service snapd.core-fixup.service snapd.recovery-chooser-trigger.service snapd.seeded.service snapd.system-shutdown.service
    /usr/bin/systemctl mask snapd.service snapd.socket snapd.apparmor.service snapd.autoimport.service snapd.core-fixup.service snapd.recovery-chooser-trigger.service snapd.seeded.service snapd.system-shutdown.service

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
    } | /usr/bin/tee /etc/modprobe.d/coolblock-blacklist.conf

    echo -e "${c_prpl}>> Uninstalling unnecessary APT packages ..${c_rst}"
    /usr/bin/apt remove -y --purge \
        needrestart* \
        libreoffice* \
        kate* \
        kde-spectacle* \
        kcalc* \
        ark* \
        partitionmanager* \
        usb-creator* \
        kwalletmanager* \
        ksystemlog* \
        plasma-discover* \
        okular* \
        elisa* \
        haruna* \
        neochat* \
        kdeconnect* \
        krdc* \
        konversation* \
        gwenview* \
        skanlite* skanpage* \
        kdegames* kmahjongg* kmines* ksudoku* kpat*

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

    configure_sysctl
    declare -r configure_sysctl_rc="${?}"
    [ "${configure_sysctl_rc}" -ne 0 ] && return "${configure_sysctl_rc}"

    install_prerequisites
    declare -r install_prerequisites_rc="${?}"
    [ "${install_prerequisites_rc}" -ne 0 ] && return "${install_prerequisites_rc}"

    install_docker
    declare -r install_docker_rc="${?}"
    [ "${install_docker_rc}" -ne 0 ] && return "${install_docker_rc}"

    create_user
    declare -r create_user_rc="${?}"
    [ "${create_user_rc}" -ne 0 ] && return "${create_user_rc}"

    install_kde
    declare -r install_kde_rc="${?}"
    [ "${install_kde_rc}" -ne 0 ] && return "${install_kde_rc}"

    # install_gnome
    # declare -r install_gnome_rc="${?}"
    # [ "${install_gnome_rc}" -ne 0 ] && return "${install_gnome_rc}"

    install_panel
    declare -r install_panel_rc="${?}"
    [ "${install_panel_rc}" -ne 0 ] && return "${install_panel_rc}"

    install_firefox
    declare -r install_firefox_rc="${?}"
    [ "${install_firefox_rc}" -ne 0 ] && return "${install_firefox_rc}"

    # install_chromium
    # declare -r install_chromium_rc="${?}"
    # [ "${install_chromium_rc}" -ne 0 ] && return "${install_chromium_rc}"

    configure_crons
    declare -r configure_crons_rc="${?}"
    [ "${configure_crons_rc}" -ne 0 ] && return "${configure_crons_rc}"

    configure_network
    declare -r configure_network_rc="${?}"
    [ "${configure_network_rc}" -ne 0 ] && return "${configure_network_rc}"

    configure_grub
    declare -r configure_grub_rc="${?}"
    [ "${configure_grub_rc}" -ne 0 ] && return "${configure_grub_rc}"

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

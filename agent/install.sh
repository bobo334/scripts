#!/bin/sh

NZ_BASE_PATH="/opt/nezha"
NZ_AGENT_PATH="${NZ_BASE_PATH}/agent"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
}

is_alpine() {
    if [ -f /etc/alpine-release ]; then
        return 0
    elif [ -f /etc/os-release ] && grep -qi alpine /etc/os-release; then
        return 0
    elif command -v apk >/dev/null 2>&1 && ! command -v apt >/dev/null 2>&1 && ! command -v yum >/dev/null 2>&1; then
        return 0
    elif uname -v | grep -qi alpine; then
        return 0
    else
        return 1
    fi
}

has_systemd() {
    [ -d /run/systemd/system ]
}

has_openrc() {
    [ -d /etc/init.d/ ] && [ -x /sbin/openrc-run ]
}

sudo() {
    myEUID=$(id -ru)
    if [ "$myEUID" -ne 0 ]; then
        if command -v sudo > /dev/null 2>&1; then
            command sudo "$@"
        else
            err "ERROR: sudo is not installed on the system, the action cannot be proceeded."
            exit 1
        fi
    else
        "$@"
    fi
}

deps_check() {
    local deps="curl unzip grep"
    local _err=0
    local missing=""

    for dep in $deps; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            _err=1
            missing="${missing} $dep"
        fi
    done

    if [ "$_err" -ne 0 ]; then
        err "Missing dependencies:$missing. Please install them and try again."
        if is_alpine; then
            info "For Alpine Linux, you can install dependencies with:"
            info "apk add curl unzip grep"
        fi
        exit 1
    fi
}

geo_check() {
    api_list="https://blog.cloudflare.com/cdn-cgi/trace https://developers.cloudflare.com/cdn-cgi/trace"
    ua="Mozilla/5.0 (X11; Linux x86_64; rv:60.0) Gecko/20100101 Firefox/81.0"
    set -- "$api_list"
    for url in $api_list; do
        text="$(curl -A "$ua" -m 10 -s "$url")"
        endpoint="$(echo "$text" | sed -n 's/.*h=\([^ ]*\).*/\1/p')"
        if echo "$text" | grep -qw 'CN'; then
            isCN=true
            break
        elif echo "$url" | grep -q "$endpoint"; then
            break
        fi
    done
}

env_check() {
    mach=$(uname -m)
    case "$mach" in
        amd64|x86_64)
            os_arch="amd64"
            ;;
        i386|i686)
            os_arch="386"
            ;;
        aarch64|arm64)
            os_arch="arm64"
            ;;
        *arm*)
            os_arch="arm"
            ;;
        s390x)
            os_arch="s390x"
            ;;
        riscv64)
            os_arch="riscv64"
            ;;
        mips)
            os_arch="mips"
            ;;
        mipsel|mipsle)
            os_arch="mipsle"
            ;;
        *)
            err "Unknown architecture: $mach"
            exit 1
            ;;
    esac

    system=$(uname)
    case "$system" in
        *Linux*)
            os="linux"
            ;;
        *Darwin*)
            os="darwin"
            ;;
        *FreeBSD*)
            os="freebsd"
            ;;
        *)
            err "Unknown architecture: $system"
            exit 1
            ;;
    esac
}

init() {
    deps_check
    env_check

    if [ -z "$CN" ]; then
        geo_check
        if [ -n "$isCN" ]; then
            CN=true
        fi
    fi

    if [ -z "$CN" ]; then
        GITHUB_URL="github.com"
    else
        GITHUB_URL="gitee.com"
    fi
}

install_openrc_service() {
    SERVICE_FILE="/etc/init.d/nezha-agent"
    
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

depend() {
    need net
}

start() {
    ebegin "Starting nezha-agent"
    start-stop-daemon --start --background \\
        --make-pidfile --pidfile /run/nezha-agent.pid \\
        --exec ${NZ_AGENT_PATH}/nezha-agent -- \\
        -c "$path"
    eend \$?
}

stop() {
    ebegin "Stopping nezha-agent"
    start-stop-daemon --stop \\
        --pidfile /run/nezha-agent.pid
    eend \$?
}
EOF

    chmod +x "$SERVICE_FILE"
    
    rc-update add nezha-agent default
}

install_systemd_service() {
    if is_alpine; then
        "${NZ_AGENT_PATH}"/nezha-agent service -c "$path" uninstall >/dev/null 2>&1 || true
        _cmd="env $env $NZ_AGENT_PATH/nezha-agent service -c $path install"
        if ! eval "$_cmd"; then
            err "Install nezha-agent service failed"
            "${NZ_AGENT_PATH}"/nezha-agent service -c "$path" uninstall >/dev/null 2>&1 || true
            exit 1
        fi
    else
        sudo "${NZ_AGENT_PATH}"/nezha-agent service -c "$path" uninstall >/dev/null 2>&1
        _cmd="sudo env $env $NZ_AGENT_PATH/nezha-agent service -c $path install"
        if ! eval "$_cmd"; then
            err "Install nezha-agent service failed"
            sudo "${NZ_AGENT_PATH}"/nezha-agent service -c "$path" uninstall >/dev/null 2>&1
            exit 1
        fi
    fi
}

install() {
    echo "Installing..."

    if [ -z "$CN" ]; then
        NZ_AGENT_URL="https://${GITHUB_URL}/nezhahq/agent/releases/latest/download/nezha-agent_${os}_${os_arch}.zip"
    else
        if is_alpine; then
            _version=$(curl -m 10 -sL "https://gitee.com/api/v5/repos/naibahq/agent/releases/latest" | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
        else
            _version=$(curl -m 10 -sL "https://gitee.com/api/v5/repos/naibahq/agent/releases/latest" | awk -F '"' '{for(i=1;i<=NF;i++){if($i=="tag_name"){print $(i+2)}}}')
        fi
        NZ_AGENT_URL="https://${GITHUB_URL}/naibahq/agent/releases/download/${_version}/nezha-agent_${os}_${os_arch}.zip"
    fi

    if command -v wget >/dev/null 2>&1; then
        _cmd="wget --timeout=60 -O /tmp/nezha-agent_${os}_${os_arch}.zip \"$NZ_AGENT_URL\" >/dev/null 2>&1"
    elif command -v curl >/dev/null 2>&1; then
        _cmd="curl --max-time 60 -fsSL \"$NZ_AGENT_URL\" -o /tmp/nezha-agent_${os}_${os_arch}.zip >/dev/null 2>&1"
    fi

    if ! eval "$_cmd"; then
        err "Download nezha-agent release failed, check your network connectivity"
        exit 1
    fi

    if is_alpine; then
        mkdir -p $NZ_AGENT_PATH
        unzip -qo /tmp/nezha-agent_${os}_${os_arch}.zip -d $NZ_AGENT_PATH &&
            rm -rf /tmp/nezha-agent_${os}_${os_arch}.zip
    else
        sudo mkdir -p $NZ_AGENT_PATH
        sudo unzip -qo /tmp/nezha-agent_${os}_${os_arch}.zip -d $NZ_AGENT_PATH &&
            sudo rm -rf /tmp/nezha-agent_${os}_${os_arch}.zip
    fi

    path="$NZ_AGENT_PATH/config.yml"
    if [ -f "$path" ]; then
        if is_alpine; then
            random=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 5)
        else
            random=$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 5)
        fi
        path=$(printf "%s" "$NZ_AGENT_PATH/config-$random.yml")
    fi

    if [ -z "$NZ_SERVER" ]; then
        err "NZ_SERVER should not be empty"
        exit 1
    fi

    if [ -z "$NZ_CLIENT_SECRET" ]; then
        err "NZ_CLIENT_SECRET should not be empty"
        exit 1
    fi

    env="NZ_UUID=$NZ_UUID NZ_SERVER=$NZ_SERVER NZ_CLIENT_SECRET=$NZ_CLIENT_SECRET NZ_TLS=$NZ_TLS NZ_DISABLE_AUTO_UPDATE=$NZ_DISABLE_AUTO_UPDATE NZ_DISABLE_FORCE_UPDATE=$DISABLE_FORCE_UPDATE NZ_DISABLE_COMMAND_EXECUTE=$NZ_DISABLE_COMMAND_EXECUTE NZ_SKIP_CONNECTION_COUNT=$NZ_SKIP_CONNECTION_COUNT"

    if is_alpine; then
        if has_openrc; then
            "${NZ_AGENT_PATH}"/nezha-agent service -c "$path" uninstall >/dev/null 2>&1 || true
            install_openrc_service
            service nezha-agent start
        else
            "${NZ_AGENT_PATH}"/nezha-agent service -c "$path" uninstall >/dev/null 2>&1 || true
            _cmd="env $env $NZ_AGENT_PATH/nezha-agent service -c $path install"
            if ! eval "$_cmd"; then
                err "Install nezha-agent service failed"
                "${NZ_AGENT_PATH}"/nezha-agent service -c "$path" uninstall >/dev/null 2>&1 || true
                exit 1
            fi
        fi
    else
        install_systemd_service
    fi

    success "nezha-agent successfully installed"
}

uninstall() {
    if is_alpine; then
        if has_openrc; then
            service nezha-agent stop 2>/dev/null || true
            rc-update del nezha-agent 2>/dev/null || true
            rm -f /etc/init.d/nezha-agent
            rm -f /run/nezha-agent.pid
        else
            find "$NZ_AGENT_PATH" -type f -name "*config*.yml" | while IFS= read -r file; do
                "$NZ_AGENT_PATH/nezha-agent" service -c "$file" uninstall
                rm "$file"
            done
        fi
    else
        find "$NZ_AGENT_PATH" -type f -name "*config*.yml" | while read -r file; do
            sudo "$NZ_AGENT_PATH/nezha-agent" service -c "$file" uninstall
            sudo rm "$file"
        done
    fi
    info "Uninstallation completed."
}

if [ "$1" = "uninstall" ]; then
    uninstall
    exit
fi

init
install
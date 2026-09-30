#!/usr/bin/env bash
#
# Project Singularity installer for Linux.
#
# Sets up a FiveM server with Project Singularity as the monitor resource:
# FXServer artifact, panel release, framework database, optional Apache
# reverse proxy and a systemd service. The rest happens in the browser wizard.
#
# Usage:
#   bash <(curl -s https://raw.githubusercontent.com/Sp3arHead/Project-Singularity-Dist/main/setup.sh) [options]
#
# Everything this script creates is removed again if a step fails.
# Passwords, keys and tokens are never written to the log file.

set -Eeuo pipefail
umask 027


#MARK: Constants
readonly DIST_REPO="Sp3arHead/Project-Singularity-Dist"
readonly RELEASE_ASSET="monitor.zip"
#GitHub API base of the release repository, overridable for mirrors and tests
readonly DIST_API="${SINGULARITY_DIST_API:-https://api.github.com/repos/${DIST_REPO}}"
readonly ARTIFACT_LIST_URL="${SINGULARITY_ARTIFACT_LIST_URL:-https://artifacts.jgscripts.com/json}"
readonly CFX_LISTING_URL="https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/"
readonly CFX_CHANGELOG_URL="https://changelogs-live.fivem.net/api/changelog/versions/linux/server"
readonly DEFAULT_DIR="/opt/fivem"
readonly PANEL_PORT=40120
readonly GAME_PORT=30120
readonly DB_NAME="singularity_framework"
readonly DB_USER="sg_framework"
readonly SERVICE_NAME="singularity"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
#Runs update-guard.sh in its own unit, so it survives the restart of the panel
#service (systemd kills every process left in a service's cgroup on restart).
readonly GUARD_UNIT="singularity-update-guard"
readonly GUARD_PATH_FILE="/etc/systemd/system/${GUARD_UNIT}.path"
readonly GUARD_SERVICE_FILE="/etc/systemd/system/${GUARD_UNIT}.service"
readonly APACHE_SITE="singularity"
readonly ARTIFACT_LIST_SIZE=10
readonly MAX_MONITOR_BACKUPS=3
readonly NET_TIMEOUT=30
readonly NET_RETRIES=3
readonly NET_RETRY_DELAY=5
readonly SUPPORTED_OS="debian:11 debian:12 ubuntu:22.04 ubuntu:24.04"


#MARK: Options
#the folder of an existing installation replaces the default
DEFAULT_INSTALL_DIR="$DEFAULT_DIR"
OPT_DIR=""
OPT_BUILD=""
OPT_TAG=""
OPT_NO_APACHE=0
OPT_NO_MARIADB=0
OPT_YES=0

usage() {
    cat <<'EOF'
Project Singularity installer for Linux

Usage: setup.sh [options]

Options:
  --dir <path>     Installation folder (default: /opt/fivem)
  --build <n>      FXServer artifact build number (default: recommended build)
  --tag <tag>      Panel release tag (default: newest release, pre-releases included)
  --no-apache      Do not install or configure Apache, the panel is reached via its port
  --no-mariadb     Do not install MariaDB; an existing MariaDB/MySQL server is required
  --yes            Accept all defaults without asking
  --help           Show this help

If Project Singularity is already installed, the installer offers to update
or to uninstall it.

Supported systems: Debian 11/12, Ubuntu 22.04/24.04.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) OPT_DIR="${2:-}"; shift 2 ;;
        --dir=*) OPT_DIR="${1#*=}"; shift ;;
        --build) OPT_BUILD="${2:-}"; shift 2 ;;
        --build=*) OPT_BUILD="${1#*=}"; shift ;;
        --tag) OPT_TAG="${2:-}"; shift 2 ;;
        --tag=*) OPT_TAG="${1#*=}"; shift ;;
        --no-apache) OPT_NO_APACHE=1; shift ;;
        --no-mariadb) OPT_NO_MARIADB=1; shift ;;
        --yes|-y) OPT_YES=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [[ -n "$OPT_BUILD" && ! "$OPT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "--build must be a build number, for example 35945." >&2
    exit 2
fi


#MARK: Logging
#The log starts in a temp file and moves next to the install folder once it is known.
LOG_FILE="$(mktemp)"
WORK_DIR="$(mktemp -d)"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }
info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; log "INFO  $*"; }
ok() { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; log "OK    $*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; log "WARN  $*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; log "ERROR $*"; exit 1; }

#Runs a command with its output in the log only. Never pass secrets as arguments.
run() {
    log "RUN   $*"
    "$@" >>"$LOG_FILE" 2>&1
}

move_log_next_to() {
    local target
    target="$(dirname "$1")/singularity-install.log"
    $SUDO mkdir -p "$(dirname "$target")"
    $SUDO cp "$LOG_FILE" "$target"
    rm -f "$LOG_FILE"
    LOG_FILE="$target"
    $SUDO chmod 640 "$LOG_FILE"
    #the rest of the run appends as the invoking user through tee
    if [[ -n "$SUDO" ]]; then $SUDO chown "$(id -un)" "$LOG_FILE"; fi
}


#MARK: Prompts
#Reads from the terminal, stdin may be the script itself.
ask() {
    local prompt="$1" default="$2" answer=""
    if [[ $OPT_YES -eq 1 ]]; then
        printf '%s\n' "$default"
        return
    fi
    read -r -p "$prompt [$default]: " answer </dev/tty || true
    printf '%s\n' "${answer:-$default}"
}

confirm() {
    local prompt="$1" default="${2:-y}" answer=""
    if [[ $OPT_YES -eq 1 ]]; then
        [[ "$default" == "y" ]]
        return
    fi
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    read -r -p "$prompt $hint: " answer </dev/tty || true
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

random_secret() {
    #alphanumeric only, so it never needs quoting in SQL, JSON or the shell.
    #tr always ends with SIGPIPE once head has enough, so pipefail is off here.
    (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1")
}


#MARK: Network
#Small requests: whole request limited to NET_TIMEOUT seconds.
fetch() {
    curl -fsSL --connect-timeout "$NET_TIMEOUT" --max-time "$NET_TIMEOUT" \
        --retry "$NET_RETRIES" --retry-delay "$NET_RETRY_DELAY" --retry-all-errors \
        -H 'User-Agent: project-singularity-installer' "$1"
}

#Large downloads: connection limited to NET_TIMEOUT seconds, and aborted if
#the transfer stalls for NET_TIMEOUT seconds.
download() {
    local url="$1" dest="$2"
    log "GET   $url"
    curl -fSL --connect-timeout "$NET_TIMEOUT" --speed-limit 1 --speed-time "$NET_TIMEOUT" \
        --retry "$NET_RETRIES" --retry-delay "$NET_RETRY_DELAY" --retry-all-errors \
        -H 'User-Agent: project-singularity-installer' \
        --progress-bar -o "$dest" "$url"
}


#MARK: Rollback
#Everything created by this run is recorded here and undone in reverse order.
INSTALL_OK=0
SUDO=""
CREATED_PATHS=()
CREATED_DB=0
CREATED_DB_USER=0
CREATED_SERVICE=0
SERVICE_UNIT_BACKUP=""
SERVICE_WAS_ACTIVE=0
#other services stopped because they held a port, started again on rollback
STOPPED_UNITS=()
#processes started by hand that were stopped, they cannot be started again
STOPPED_PROCESSES=()
CREATED_GUARD_UNITS=0
GUARD_UNITS_BACKUP=""
CREATED_APACHE_SITE=0
CREATED_CERT_DOMAIN=""
MONITOR_PATH=""
MONITOR_BACKUP=""
MONITOR_INSTALLED=0

mysql_root() {
    #SQL is passed on stdin so it never shows up in the process list
    $SUDO mysql --protocol=socket -uroot "$@"
}

#The panel connects over TCP to 127.0.0.1, which MariaDB may not map to 'localhost'
readonly DB_USER_HOSTS=("localhost" "127.0.0.1")

rollback() {
    set +e
    warn "Installation failed, rolling back the changes of this run."

    #A service that was running before is only started again at the very end,
    #once its files are back in place.
    if [[ $CREATED_SERVICE -eq 1 || -n "$SERVICE_UNIT_BACKUP" ]]; then
        run $SUDO systemctl stop "$SERVICE_NAME"
        if [[ -n "$SERVICE_UNIT_BACKUP" ]]; then
            $SUDO cp "$SERVICE_UNIT_BACKUP" "$SERVICE_FILE"
            run $SUDO systemctl daemon-reload
            log "restored the previous service unit"
        else
            run $SUDO systemctl disable "$SERVICE_NAME"
            $SUDO rm -f "$SERVICE_FILE"
            run $SUDO systemctl daemon-reload
            run $SUDO systemctl reset-failed "$SERVICE_NAME"
            log "removed service $SERVICE_NAME"
        fi
    fi
    if [[ $CREATED_GUARD_UNITS -eq 1 || -n "$GUARD_UNITS_BACKUP" ]]; then
        run $SUDO systemctl disable --now "${GUARD_UNIT}.path"
        if [[ -n "$GUARD_UNITS_BACKUP" ]]; then
            $SUDO cp "$GUARD_UNITS_BACKUP/${GUARD_UNIT}.path" "$GUARD_PATH_FILE"
            $SUDO cp "$GUARD_UNITS_BACKUP/${GUARD_UNIT}.service" "$GUARD_SERVICE_FILE"
            run $SUDO systemctl daemon-reload
            run $SUDO systemctl enable --now "${GUARD_UNIT}.path"
            log "restored the previous update guard units"
        else
            $SUDO rm -f "$GUARD_PATH_FILE" "$GUARD_SERVICE_FILE"
            run $SUDO systemctl daemon-reload
            log "removed the update guard units"
        fi
    fi

    if [[ -n "$CREATED_CERT_DOMAIN" ]]; then
        run $SUDO certbot delete --non-interactive --cert-name "$CREATED_CERT_DOMAIN"
    fi
    if [[ $CREATED_APACHE_SITE -eq 1 ]]; then
        run $SUDO a2dissite "$APACHE_SITE" "${APACHE_SITE}-le-ssl"
        $SUDO rm -f "/etc/apache2/sites-available/${APACHE_SITE}.conf" "/etc/apache2/sites-available/${APACHE_SITE}-le-ssl.conf"
        run $SUDO systemctl reload apache2
        log "removed the Apache site $APACHE_SITE"
    fi

    if [[ $CREATED_DB_USER -eq 1 ]]; then
        local db_host
        for db_host in "${DB_USER_HOSTS[@]}"; do
            printf "DROP USER IF EXISTS '%s'@'%s';\n" "$DB_USER" "$db_host" | mysql_root >>"$LOG_FILE" 2>&1
        done
        log "dropped database user $DB_USER"
    fi
    if [[ $CREATED_DB -eq 1 ]]; then
        printf 'DROP DATABASE IF EXISTS `%s`;\n' "$DB_NAME" | mysql_root >>"$LOG_FILE" 2>&1
        log "dropped database $DB_NAME"
    fi

    if [[ $MONITOR_INSTALLED -eq 1 && -n "$MONITOR_PATH" ]]; then
        $SUDO rm -rf "$MONITOR_PATH"
        if [[ -n "$MONITOR_BACKUP" ]] && $SUDO test -d "$MONITOR_BACKUP"; then
            $SUDO mv "$MONITOR_BACKUP" "$MONITOR_PATH"
            log "restored the previous monitor folder"
        fi
    fi

    local i
    for ((i = ${#CREATED_PATHS[@]} - 1; i >= 0; i--)); do
        $SUDO rm -rf "${CREATED_PATHS[$i]}"
        log "removed ${CREATED_PATHS[$i]}"
    done

    local unit
    for unit in "${STOPPED_UNITS[@]}"; do
        run $SUDO systemctl start "$unit"
        log "started $unit again"
    done
    if [[ ${#STOPPED_PROCESSES[@]} -gt 0 ]]; then
        warn "These programs were stopped for the installation and must be started again by hand: ${STOPPED_PROCESSES[*]}"
    fi

    if [[ $SERVICE_WAS_ACTIVE -eq 1 && $CREATED_SERVICE -eq 0 ]]; then
        run $SUDO systemctl start "$SERVICE_NAME"
        log "started the previously running service again"
    fi

    warn "Rollback finished. Details: $LOG_FILE"
}

on_exit() {
    local code=$?
    if [[ $INSTALL_OK -ne 1 ]]; then
        rollback
    fi
    rm -rf "$WORK_DIR"
    exit "$code"
}
trap on_exit EXIT
trap 'log "ERROR command failed (exit $?) at line $LINENO: $BASH_COMMAND"' ERR
trap 'die "Interrupted."' INT TERM

#Creates a folder and records it for the rollback if it did not exist.
make_dir() {
    if ! $SUDO test -d "$1"; then
        $SUDO mkdir -p "$1"
        CREATED_PATHS+=("$1")
        log "created $1"
    fi
}


#MARK: Checks
check_os() {
    local id="" version=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release && echo "${ID:-}")"
        version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
    fi
    log "OS: ${id:-unknown} ${version:-unknown}, kernel $(uname -r), arch $(uname -m)"
    if [[ "$(uname -m)" != "x86_64" ]]; then
        die "FXServer for Linux only runs on x86_64, this machine is $(uname -m)."
    fi
    if [[ " $SUPPORTED_OS " != *" $id:$version "* ]]; then
        warn "This system (${id:-unknown} ${version:-unknown}) is not supported. Supported: Debian 11/12, Ubuntu 22.04/24.04."
        confirm "Continue anyway?" "y" || die "Aborted by user."
    else
        ok "System: $id $version"
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        die "apt-get was not found. This installer needs a Debian based system."
    fi
}

check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        info "Some steps need root, sudo may ask for your password."
        sudo -v </dev/tty || die "sudo is required to install packages and the service."
    else
        die "Run this script as root, or install sudo."
    fi
    SERVICE_USER="${SUDO_USER:-$(id -un)}"
    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
    ok "Privileges: $( [[ -z "$SUDO" ]] && echo root || echo sudo ), service user: $SERVICE_USER"
}

install_tools() {
    local tools=(curl unzip tar xz-utils git ca-certificates jq iproute2 procps)
    local missing=() pkg
    for pkg in "${tools[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing tools: ${missing[*]}"
        run $SUDO apt-get update
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
    ok "Tools present"
}

port_in_use() {
    ss -Hltnu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]$1\$"
}

#"<pid> <program>" of the process listening on a port, empty if unknown
port_owner() {
    $SUDO ss -Hltnup 2>/dev/null \
        | awk -v p="$1" '$5 ~ "[:.]" p "$" {print; exit}' \
        | sed -nE 's/.*\(\("([^"]+)",pid=([0-9]+),.*/\2 \1/p' || true
}

#The system service a process belongs to, empty for anything started by hand
process_unit() {
    $SUDO cat "/proc/$1/cgroup" 2>/dev/null \
        | sed -nE 's#^[0-9]+:[^:]*:/system\.slice/([^/]+\.service)(/.*)?$#\1#p' | head -n1 || true
}

#Ends a process started by hand and every process it started (the game server)
stop_process_tree() {
    local pid="$1" children i
    children="$($SUDO pgrep -P "$pid" 2>/dev/null | tr '\n' ' ' || true)"
    $SUDO kill -TERM "$pid" $children 2>/dev/null || true
    for ((i = 0; i < 30; i++)); do
        $SUDO kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    $SUDO kill -KILL "$pid" $children 2>/dev/null || true
    sleep 1
}

wait_port_free() {
    local i
    for ((i = 0; i < 30; i++)); do
        port_in_use "$1" || return 0
        sleep 1
    done
    return 1
}

#A running server (an older install, txAdmin, a panel started by hand) usually
#holds the ports. Say what it is and offer to stop it instead of just failing.
free_port() {
    local port="$1" owner pid prog unit cmd
    owner="$(port_owner "$port")"
    [[ -n "$owner" ]] || die "Port $port is already in use. Stop the program using it and run the installer again."
    pid="${owner%% *}"
    prog="${owner#* }"
    unit="$(process_unit "$pid")"
    cmd="$($SUDO tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | cut -c1-120 || true)"
    log "port $port is used by pid $pid ($prog), unit '${unit:-none}', command: $cmd"

    if [[ -n "$unit" ]]; then
        warn "Port $port is used by $prog (pid $pid) of the service $unit."
        confirm "Stop $unit for the installation? It is started again if the installation fails." "y" \
            || die "Port $port is in use by $unit. Stop it and run the installer again."
        run $SUDO systemctl stop "$unit"
        STOPPED_UNITS+=("$unit")
    elif $SUDO grep -qa 'pm_id=' "/proc/$pid/environ" 2>/dev/null; then
        local pm_id
        pm_id="$($SUDO tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^pm_id=//p' | head -n1 || true)"
        die "Port $port is used by $prog (pid $pid), which runs under pm2. Stop it with: pm2 stop ${pm_id:-<id>}, then run the installer again."
    elif [[ "$prog" == *FXServer* || "$prog" == ld-musl* || "$cmd" == *FXServer* ]]; then
        warn "Port $port is used by a running FXServer (pid $pid): $cmd"
        warn "It was started by hand (screen, tmux or a console), so it cannot be started again automatically."
        confirm "Stop this FXServer and its game server for the installation?" "n" \
            || die "Port $port is in use by FXServer (pid $pid). Stop it and run the installer again."
        stop_process_tree "$pid"
        STOPPED_PROCESSES+=("FXServer(pid $pid)")
        log "stopped FXServer pid $pid"
    else
        die "Port $port is used by $prog (pid $pid). Stop it and run the installer again."
    fi

    wait_port_free "$port" || die "Port $port is still in use after stopping $prog. Stop it by hand and run the installer again."
    ok "Port $port is free now"
}

check_ports() {
    #a previous installation of this panel may be running, stop it for now
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "Stopping the running $SERVICE_NAME service for the update."
        SERVICE_WAS_ACTIVE=1
        run $SUDO systemctl stop "$SERVICE_NAME"
    fi
    local port
    for port in "$PANEL_PORT" "$GAME_PORT"; do
        if port_in_use "$port"; then
            free_port "$port"
        fi
    done
    ok "Ports $PANEL_PORT and $GAME_PORT are free"
}

#A service stopped for the ports would take them back at the next boot.
disable_stopped_units() {
    local unit
    for unit in "${STOPPED_UNITS[@]}"; do
        systemctl is-enabled --quiet "$unit" 2>/dev/null || continue
        if confirm "$unit was stopped for this installation and would start again at boot, competing for the same ports. Disable it?" "y"; then
            run $SUDO systemctl disable "$unit"
            ok "Disabled $unit"
        else
            warn "$unit stays enabled; it will conflict with $SERVICE_NAME at the next boot."
        fi
    done
}

check_install_dir() {
    INSTALL_DIR="$(realpath -m "$INSTALL_DIR")"
    [[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != "/" ]] || die "Invalid installation folder: $INSTALL_DIR"
    #the path ends up in JSON and systemd files, and FXServer breaks on non-ASCII paths
    [[ "$INSTALL_DIR" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "The installation folder may only contain letters, numbers, dots, dashes, underscores and slashes."
    local parent
    parent="$(dirname "$INSTALL_DIR")"
    while ! $SUDO test -d "$parent"; do parent="$(dirname "$parent")"; done
    $SUDO test -w "$parent" || die "No write permission in $parent."
    if $SUDO test -d "$INSTALL_DIR"; then
        $SUDO test -w "$INSTALL_DIR" || die "No write permission in $INSTALL_DIR."
        if [[ -n "$($SUDO ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
            warn "$INSTALL_DIR is not empty, existing files are kept and the artifact is updated in place."
        fi
    fi
}


#MARK: Existing install
EXISTING_DIR=""

#An installation is recognised by its service unit, which points to run.sh
#in the install folder.
detect_existing_install() {
    $SUDO test -f "$SERVICE_FILE" || return 0
    local exec_line
    exec_line="$($SUDO grep -m1 '^ExecStart=' "$SERVICE_FILE" || true)"
    if [[ "$exec_line" =~ [[:space:]](/[^[:space:]]+)/run\.sh ]]; then
        EXISTING_DIR="${BASH_REMATCH[1]}"
    else
        EXISTING_DIR="(unknown folder)"
    fi
    log "found an existing installation: $EXISTING_DIR"
}

#Returns 0 to continue with an install into the existing folder.
#Uninstall and cancel end the script.
handle_existing_install() {
    [[ -n "$EXISTING_DIR" ]] || return 0
    local state
    state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    info "Project Singularity is already installed in $EXISTING_DIR (service $SERVICE_NAME: $state)."
    local choice="1"
    if [[ $OPT_YES -ne 1 ]]; then
        echo "  1) Update / reinstall in the same folder"
        echo "  2) Uninstall"
        echo "  3) Cancel"
        choice="$(ask "Choose" "1")"
    fi
    case "$choice" in
        1) [[ "$EXISTING_DIR" == /* ]] && DEFAULT_INSTALL_DIR="$EXISTING_DIR"; return 0 ;;
        2) uninstall_existing ;;
        3) info "Cancelled, nothing was changed." ;;
        *) die "Invalid choice: $choice" ;;
    esac
    #nothing to roll back: an uninstall cannot be undone and cancel changed nothing
    INSTALL_OK=1
    exit 0
}

uninstall_existing() {
    if [[ "$EXISTING_DIR" == /* ]]; then
        move_log_next_to "$EXISTING_DIR"
    fi
    info "Uninstalling Project Singularity"

    run $SUDO systemctl stop "$SERVICE_NAME" || true
    run $SUDO systemctl disable "$SERVICE_NAME" || true
    $SUDO rm -f "$SERVICE_FILE"
    run $SUDO systemctl daemon-reload
    #systemd keeps a failed state in memory even without the unit file
    run $SUDO systemctl reset-failed "$SERVICE_NAME" || true
    ok "Service $SERVICE_NAME removed"

    run $SUDO systemctl disable --now "${GUARD_UNIT}.path" || true
    $SUDO rm -f "$GUARD_PATH_FILE" "$GUARD_SERVICE_FILE"
    run $SUDO systemctl daemon-reload
    run $SUDO systemctl reset-failed "${GUARD_UNIT}.service" || true

    local conf="/etc/apache2/sites-available/${APACHE_SITE}.conf"
    if $SUDO test -f "$conf"; then
        local domain
        domain="$($SUDO awk '/^[[:space:]]*ServerName/ {print $2; exit}' "$conf")"
        run $SUDO a2dissite "$APACHE_SITE" "${APACHE_SITE}-le-ssl" || true
        $SUDO rm -f "$conf" "/etc/apache2/sites-available/${APACHE_SITE}-le-ssl.conf"
        if [[ -n "$domain" ]] && $SUDO test -d "/etc/letsencrypt/live/$domain"; then
            run $SUDO certbot delete --non-interactive --cert-name "$domain" || true
        fi
        run $SUDO systemctl reload apache2 || true
        ok "Apache site removed"
    fi

    if [[ "$EXISTING_DIR" == /* ]] && $SUDO test -d "$EXISTING_DIR"; then
        if confirm "Delete $EXISTING_DIR with the server files, server-data and the panel data?" "y"; then
            $SUDO rm -rf "$EXISTING_DIR"
            ok "Deleted $EXISTING_DIR"
        else
            warn "Kept $EXISTING_DIR"
        fi
    fi

    if command -v mysql >/dev/null 2>&1 && echo "SELECT 1;" | mysql_root >/dev/null 2>&1; then
        warn "The database $DB_NAME holds the framework data (players, inventories, ...)."
        if confirm "Also delete the database $DB_NAME and the user $DB_USER?" "n"; then
            local db_host
            {
                printf 'DROP DATABASE IF EXISTS `%s`;\n' "$DB_NAME"
                for db_host in "${DB_USER_HOSTS[@]}"; do
                    printf "DROP USER IF EXISTS '%s'@'%s';\n" "$DB_USER" "$db_host"
                done
            } | mysql_root
            ok "Database $DB_NAME and user $DB_USER deleted"
        else
            ok "Database $DB_NAME kept, a new installation can reuse it"
        fi
    fi

    log "uninstall finished"
    echo
    echo "  Project Singularity was uninstalled. MariaDB, Apache and the log file were kept."
    echo "  Log file: $LOG_FILE"
    echo
}


#MARK: MariaDB
setup_mariadb() {
    if command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1; then
        ok "MariaDB/MySQL server found"
    else
        if [[ $OPT_NO_MARIADB -eq 1 ]]; then
            die "No MariaDB/MySQL server found and --no-mariadb was given. The framework needs a database, install one first."
        fi
        if ! confirm "MariaDB is not installed. Install it now?" "y"; then
            die "A database server is required because the framework needs a database later. Install MariaDB and run the installer again."
        fi
        info "Installing MariaDB"
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server
        ok "MariaDB installed"
    fi
    run $SUDO systemctl enable --now mariadb || run $SUDO systemctl enable --now mysql \
        || die "Could not start the database server."
    echo "SELECT 1;" | mysql_root >/dev/null 2>&1 \
        || die "Cannot connect to the database server as root through the local socket."
}

create_database() {
    local db_exists user_exists
    db_exists="$(printf "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='%s';\n" "$DB_NAME" | mysql_root -N)"
    user_exists="$(printf "SELECT COUNT(*) FROM mysql.user WHERE User='%s';\n" "$DB_USER" | mysql_root -N)"

    #reinstall: keep the existing database, the panel config already has the password
    if [[ "$db_exists" != "0" || "$user_exists" != "0" ]] \
        && $SUDO test -f "$HB_STORE_FILE" && $SUDO grep -q '"frameworkPassword"' "$HB_STORE_FILE"; then
        ok "Database $DB_NAME already exists, keeping it"
        DB_PASSWORD=""
        return
    fi

    #left over from an uninstall that kept the database: its password is gone
    #with the old panel config, so the user gets a new one
    if [[ "$db_exists" != "0" || "$user_exists" != "0" ]]; then
        warn "Database $DB_NAME or user $DB_USER already exists without a panel configuration (for example after an uninstall that kept the database)."
        confirm "Reuse it? The user $DB_USER gets a new password, the data is kept." "y" \
            || die "Remove the database $DB_NAME and the user $DB_USER, or run the installer again and reuse them."
    fi

    DB_PASSWORD="$(random_secret 32)"
    if [[ "$db_exists" == "0" ]]; then
        printf 'CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$DB_NAME" | mysql_root
        CREATED_DB=1
        log "created database $DB_NAME"
    else
        log "reusing the existing database $DB_NAME"
    fi
    [[ "$user_exists" == "0" ]] && CREATED_DB_USER=1
    local db_host
    {
        for db_host in "${DB_USER_HOSTS[@]}"; do
            #IF NOT EXISTS + ALTER covers both a new and a reused user
            printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY '%s';\n" "$DB_USER" "$db_host" "$DB_PASSWORD"
            printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$DB_USER" "$db_host" "$DB_PASSWORD"
            printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%s';\n" "$DB_NAME" "$DB_USER" "$db_host"
        done
        printf "FLUSH PRIVILEGES;\n"
    } | mysql_root
    if [[ "$user_exists" == "0" ]]; then
        log "created database user $DB_USER with privileges on $DB_NAME only"
    else
        log "set a new password for the existing database user $DB_USER"
    fi
    ok "Database $DB_NAME with user $DB_USER"
}


#MARK: Apache
APACHE_DOMAIN=""
APACHE_EMAIL=""
USE_APACHE=0

choose_apache() {
    [[ $OPT_NO_APACHE -eq 1 ]] && { log "Apache skipped (--no-apache)"; return; }
    if ! command -v apache2 >/dev/null 2>&1; then
        if ! confirm "Apache is not installed. Install it as a reverse proxy for the panel?" "y"; then
            log "Apache declined, the panel is reached via port $PANEL_PORT"
            return
        fi
        info "Installing Apache"
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y apache2
        ok "Apache installed"
    fi
    APACHE_DOMAIN="$(ask "Domain for the panel (leave empty for none)" "")"
    APACHE_DOMAIN="${APACHE_DOMAIN,,}"
    if [[ -z "$APACHE_DOMAIN" ]]; then
        log "no domain given, no virtual host is created"
        return
    fi
    [[ "$APACHE_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
        || die "Invalid domain: $APACHE_DOMAIN"
    APACHE_EMAIL="$(ask "E-mail for the Let's Encrypt certificate (leave empty for none)" "")"
    USE_APACHE=1
}

setup_apache() {
    [[ $USE_APACHE -eq 1 ]] || return 0
    local conf="/etc/apache2/sites-available/${APACHE_SITE}.conf"
    [[ -e "$conf" ]] && die "$conf already exists. Remove it or run with --no-apache."

    run $SUDO a2enmod proxy proxy_http proxy_wstunnel rewrite headers
    $SUDO tee "$conf" >/dev/null <<EOF
# Project Singularity panel, created by setup.sh
<VirtualHost *:80>
    ServerName ${APACHE_DOMAIN}

    ProxyPreserveHost On
    ProxyRequests Off
    RequestHeader set X-Forwarded-Proto expr=%{REQUEST_SCHEME}

    # WebSocket (socket.io)
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule ^/?(.*) ws://127.0.0.1:${PANEL_PORT}/\$1 [P,L]

    ProxyPass / http://127.0.0.1:${PANEL_PORT}/
    ProxyPassReverse / http://127.0.0.1:${PANEL_PORT}/
</VirtualHost>
EOF
    CREATED_APACHE_SITE=1
    run $SUDO a2ensite "$APACHE_SITE"
    run $SUDO apache2ctl configtest || die "The Apache configuration test failed."
    run $SUDO systemctl reload apache2
    ok "Apache virtual host for $APACHE_DOMAIN"

    info "Requesting a certificate for $APACHE_DOMAIN"
    if ! command -v certbot >/dev/null 2>&1; then
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-apache
    fi
    local email_args=(--register-unsafely-without-email)
    [[ -n "$APACHE_EMAIL" ]] && email_args=(-m "$APACHE_EMAIL")
    run $SUDO certbot --apache --non-interactive --agree-tos --redirect "${email_args[@]}" -d "$APACHE_DOMAIN" \
        || die "certbot could not get a certificate. Check that $APACHE_DOMAIN points to this server and port 80 is reachable."
    CREATED_CERT_DOMAIN="$APACHE_DOMAIN"
    ok "Certificate installed"
}


#MARK: Artifact
ARTIFACT_BUILD=""
ARTIFACT_URL=""

choose_artifact() {
    info "Loading the list of FXServer builds"
    local recommended="" broken_json="{}" listing="" jg_json=""

    if jg_json="$(fetch "$ARTIFACT_LIST_URL")" && [[ -n "$jg_json" ]]; then
        recommended="$(jq -r '.recommendedArtifact // empty' <<<"$jg_json")"
        broken_json="$(jq -c '.brokenArtifacts // {}' <<<"$jg_json")"
        log "artifact list: recommended $recommended from $ARTIFACT_LIST_URL"
    else
        warn "$ARTIFACT_LIST_URL is not reachable, falling back to the official Cfx source."
        local cfx_json
        if cfx_json="$(fetch "$CFX_CHANGELOG_URL")"; then
            recommended="$(jq -r '.recommended // empty' <<<"$cfx_json")"
        fi
    fi

    #build number <tab> download url, newest first
    if listing="$(fetch "$CFX_LISTING_URL")"; then
        listing="$(grep -oE '\./[0-9]+-[0-9a-f]+/fx\.tar\.xz' <<<"$listing" \
            | sed -E "s#^\./(([0-9]+)-[0-9a-f]+/fx\.tar\.xz)#\2\t${CFX_LISTING_URL}\1#" \
            | sort -t$'\t' -k1,1nr | awk -F'\t' '!seen[$1]++')"
    else
        listing=""
    fi
    if [[ -z "$listing" ]]; then
        #last resort: the recommended build from the artifact list itself
        local link=""
        [[ -n "$jg_json" ]] && link="$(jq -r '.linuxDownloadLink // empty' <<<"$jg_json")"
        [[ -n "$link" && -n "$recommended" ]] || die "No artifact source is reachable (${ARTIFACT_LIST_URL}, ${CFX_LISTING_URL})."
        listing="$(printf '%s\t%s\n' "$recommended" "$link")"
    fi

    #drop builds known to be broken, keep the newest ones plus the recommended one
    local builds=() urls=() build url
    while IFS=$'\t' read -r build url; do
        [[ -z "$build" ]] && continue
        #the listing is sorted newest first: stop once the list is full and
        #the recommended and requested builds were passed
        if [[ ${#builds[@]} -ge $ARTIFACT_LIST_SIZE ]] \
            && { [[ -z "$recommended" ]] || [[ "$build" -lt "$recommended" ]]; } \
            && { [[ -z "$OPT_BUILD" ]] || [[ "$build" -lt "$OPT_BUILD" ]]; }; then
            break
        fi
        if [[ "$(jq -r --arg b "$build" 'has($b)' <<<"$broken_json")" == "true" ]]; then continue; fi
        if [[ ${#builds[@]} -lt $ARTIFACT_LIST_SIZE || "$build" == "$recommended" || "$build" == "$OPT_BUILD" ]]; then
            builds+=("$build"); urls+=("$url")
        fi
    done <<<"$listing"
    [[ ${#builds[@]} -gt 0 ]] || die "The artifact list is empty."

    if [[ -n "$OPT_BUILD" ]]; then
        local i
        for i in "${!builds[@]}"; do
            if [[ "${builds[$i]}" == "$OPT_BUILD" ]]; then
                ARTIFACT_BUILD="$OPT_BUILD"; ARTIFACT_URL="${urls[$i]}"
            fi
        done
        [[ -n "$ARTIFACT_BUILD" ]] || die "Build $OPT_BUILD was not found or is known to be broken."
        ok "Artifact build $ARTIFACT_BUILD (--build)"
        return
    fi

    local default_index=0 i label
    for i in "${!builds[@]}"; do
        [[ "${builds[$i]}" == "$recommended" ]] && default_index=$i
    done
    echo "Available FXServer builds:"
    for i in "${!builds[@]}"; do
        [[ $i -ge $ARTIFACT_LIST_SIZE && "${builds[$i]}" != "$recommended" ]] && continue
        label=""
        [[ "${builds[$i]}" == "$recommended" ]] && label=" (recommended)"
        printf '  %2d) %s%s\n' "$((i + 1))" "${builds[$i]}" "$label"
    done
    local choice
    choice="$(ask "Choose a build" "$((default_index + 1))")"
    [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#builds[@]} ]] || die "Invalid choice: $choice"
    ARTIFACT_BUILD="${builds[$((choice - 1))]}"
    ARTIFACT_URL="${urls[$((choice - 1))]}"
    ok "Artifact build $ARTIFACT_BUILD"
}

install_artifact() {
    info "Downloading FXServer build $ARTIFACT_BUILD"
    download "$ARTIFACT_URL" "$WORK_DIR/fx.tar.xz" || die "The artifact download failed."
    #neither source publishes checksums, so the archive is only checked for integrity
    log "no checksum published by the artifact source, verifying the archive instead"
    tar -tJf "$WORK_DIR/fx.tar.xz" >/dev/null 2>&1 || die "The downloaded artifact is damaged."
    run $SUDO tar -xJf "$WORK_DIR/fx.tar.xz" -C "$INSTALL_DIR"
    $SUDO test -f "$INSTALL_DIR/run.sh" || die "The artifact does not contain run.sh."
    ok "FXServer extracted to $INSTALL_DIR"
}


#MARK: Panel release
RELEASE_TAG=""
RELEASE_ASSET_URL=""

resolve_release() {
    local api json
    if [[ -n "$OPT_TAG" ]]; then
        api="${DIST_API}/releases/tags/${OPT_TAG}"
        json="$(fetch "$api")" || die "Release $OPT_TAG was not found in $DIST_REPO."
    else
        api="${DIST_API}/releases?per_page=20"
        json="$(fetch "$api")" || die "Could not load the releases of $DIST_REPO."
        #newest first, pre-releases included, drafts are not visible without a token
        json="$(jq -c '[.[] | select(.draft == false)] | sort_by(.published_at) | reverse | .[0] // empty' <<<"$json")"
        [[ -n "$json" ]] || die "No release of Project Singularity was found in $DIST_REPO."
    fi
    RELEASE_TAG="$(jq -r '.tag_name' <<<"$json")"
    RELEASE_ASSET_URL="$(jq -r --arg n "$RELEASE_ASSET" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$json" | head -n1)"
    [[ -n "$RELEASE_ASSET_URL" ]] || die "Release $RELEASE_TAG has no $RELEASE_ASSET asset."
    ok "Panel release $RELEASE_TAG"
}

install_panel() {
    MONITOR_PATH="$INSTALL_DIR/alpine/opt/cfx-server/citizen/system_resources/monitor"
    info "Downloading Project Singularity $RELEASE_TAG"
    download "$RELEASE_ASSET_URL" "$WORK_DIR/$RELEASE_ASSET" || die "The panel download failed."
    unzip -tq "$WORK_DIR/$RELEASE_ASSET" >/dev/null 2>&1 || die "The downloaded $RELEASE_ASSET is damaged."

    #backups live outside system_resources so FXServer never sees them as resources
    if $SUDO test -d "$MONITOR_PATH"; then
        local backup_dir="$INSTALL_DIR/backups"
        make_dir "$backup_dir"
        MONITOR_BACKUP="$backup_dir/monitor.bak.$(date '+%Y%m%d-%H%M%S')"
        $SUDO mv "$MONITOR_PATH" "$MONITOR_BACKUP"
        log "moved the existing monitor folder to $MONITOR_BACKUP"
    fi
    MONITOR_INSTALLED=1
    $SUDO mkdir -p "$MONITOR_PATH"
    run $SUDO unzip -q "$WORK_DIR/$RELEASE_ASSET" -d "$MONITOR_PATH"
    $SUDO test -f "$MONITOR_PATH/fxmanifest.lua" || die "$RELEASE_ASSET does not contain fxmanifest.lua."
    ok "Panel installed as the monitor resource"
}

#Keeps the newest MAX_MONITOR_BACKUPS backups. Runs only after a successful
#install, so a rollback can always restore the latest one.
rotate_backups() {
    local backup_dir="$INSTALL_DIR/backups" old
    $SUDO test -d "$backup_dir" || return 0
    while IFS= read -r old; do
        [[ -z "$old" ]] && continue
        $SUDO rm -rf "$old"
        log "deleted old backup $old"
    done < <($SUDO find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name 'monitor.bak.*' | sort -r | tail -n +$((MAX_MONITOR_BACKUPS + 1)))
}


#MARK: Server data & config
setup_server_data() {
    SERVER_DATA="$INSTALL_DIR/server-data"
    make_dir "$SERVER_DATA"
    make_dir "$SERVER_DATA/resources"
    if ! $SUDO test -f "$SERVER_DATA/server.cfg"; then
        $SUDO tee "$SERVER_DATA/server.cfg" >/dev/null <<EOF
# Minimal server.cfg created by the Project Singularity installer.
# The rest of the configuration is added by the setup wizard in the browser.
endpoint_add_tcp "0.0.0.0:${GAME_PORT}"
endpoint_add_udp "0.0.0.0:${GAME_PORT}"
sv_licenseKey "changeme"
set resources_path "resources"
EOF
        log "created $SERVER_DATA/server.cfg"
    else
        log "kept the existing $SERVER_DATA/server.cfg"
    fi
    ok "Server data folder $SERVER_DATA"
}

SETUP_TOKEN=""

write_panel_config() {
    TXDATA="$INSTALL_DIR/txData"
    local profile="$TXDATA/default"
    make_dir "$TXDATA"
    make_dir "$profile"
    #watched by the update guard path unit, see setup_update_guard
    make_dir "$TXDATA/updates"

    if $SUDO test -f "$profile/config.json"; then
        log "kept the existing panel configuration $profile/config.json"
    else
        SETUP_TOKEN="$(random_secret 48)"
        #autoStart stays off until the setup wizard is completed
        $SUDO tee "$profile/config.json" >/dev/null <<EOF
{
  "version": 3,
  "server": {
    "dataPath": "${SERVER_DATA}",
    "artifactsPath": "${INSTALL_DIR}",
    "autoStart": false
  },
  "panel": {
    "port": ${PANEL_PORT}
  },
  "setup": {
    "token": "${SETUP_TOKEN}"
  }
}
EOF
        $SUDO chmod 600 "$profile/config.json"
        log "wrote the panel configuration (setup token not logged)"
    fi

    if [[ -n "$DB_PASSWORD" ]]; then
        $SUDO tee "$HB_STORE_FILE" >/dev/null <<EOF
{
  "framework": {
    "kind": "none",
    "enabled": false,
    "connection": {
      "host": "127.0.0.1",
      "port": 3306,
      "user": "${DB_USER}",
      "database": "${DB_NAME}"
    }
  },
  "frameworkPassword": "${DB_PASSWORD}"
}
EOF
        $SUDO chmod 600 "$HB_STORE_FILE"
        log "wrote the framework database access (password not logged)"
    fi
    DB_PASSWORD=""
    ok "Panel configuration written"
}


#MARK: Service
setup_service() {
    local env_url=""
    [[ -n "$APACHE_DOMAIN" ]] && env_url="Environment=SINGULARITY_PANEL_URL=https://${APACHE_DOMAIN}"

    if [[ -f "$SERVICE_FILE" ]]; then
        #only recorded once the copy exists, so the rollback never restores nothing
        $SUDO cp "$SERVICE_FILE" "$WORK_DIR/${SERVICE_NAME}.service.bak"
        SERVICE_UNIT_BACKUP="$WORK_DIR/${SERVICE_NAME}.service.bak"
        log "backed up the existing service unit"
    else
        CREATED_SERVICE=1
    fi

    $SUDO tee "$SERVICE_FILE" >/dev/null <<EOF
# Project Singularity, created by setup.sh
[Unit]
Description=Project Singularity (FiveM server with the Singularity panel)
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${SERVER_DATA}
Environment=SINGULARITY_DATA_PATH=${TXDATA}
Environment=SINGULARITY_UPDATE_GUARD=systemd
${env_url}
ExecStart=/usr/bin/env bash ${INSTALL_DIR}/run.sh
#always: the panel exits with code 0 to finish a panel update
Restart=always
RestartSec=10
KillSignal=SIGINT
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF
    #umask 027 would make the unit unreadable for everyone but root
    $SUDO chmod 644 "$SERVICE_FILE"
    run $SUDO systemctl daemon-reload
    run $SUDO systemctl enable "$SERVICE_NAME"
    ok "Service $SERVICE_NAME created"
    setup_update_guard
}

#The panel writes $TXDATA/updates/guard.request right before it restarts to
#finish an update; the path unit then starts update-guard.sh as its own unit,
#which rolls the update back if the new version does not come up in time.
setup_update_guard() {
    if [[ -f "$GUARD_PATH_FILE" && -f "$GUARD_SERVICE_FILE" ]]; then
        $SUDO mkdir -p "$WORK_DIR/guard-units.bak"
        $SUDO cp "$GUARD_PATH_FILE" "$GUARD_SERVICE_FILE" "$WORK_DIR/guard-units.bak/"
        GUARD_UNITS_BACKUP="$WORK_DIR/guard-units.bak"
        log "backed up the existing update guard units"
    else
        CREATED_GUARD_UNITS=1
    fi

    $SUDO tee "$GUARD_SERVICE_FILE" >/dev/null <<EOF
# Project Singularity, created by setup.sh
[Unit]
Description=Project Singularity update guard (rolls back a failed panel update)

[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=/bin/sh ${TXDATA}/updates/update-guard.sh --request ${TXDATA}/updates/guard.request
#longer than the panel's largest readyTimeoutSeconds plus the rollback itself
TimeoutStartSec=30min
EOF

    $SUDO tee "$GUARD_PATH_FILE" >/dev/null <<EOF
# Project Singularity, created by setup.sh
[Unit]
Description=Project Singularity update guard trigger

[Path]
PathExists=${TXDATA}/updates/guard.request
Unit=${GUARD_UNIT}.service

[Install]
WantedBy=multi-user.target
EOF
    $SUDO chmod 644 "$GUARD_SERVICE_FILE" "$GUARD_PATH_FILE"
    run $SUDO systemctl daemon-reload
    run $SUDO systemctl enable --now "${GUARD_UNIT}.path"
    ok "Update guard ${GUARD_UNIT}.path enabled"
}

set_permissions() {
    run $SUDO chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
    run $SUDO chmod 750 "$INSTALL_DIR" "$SERVER_DATA" "$TXDATA"
    ok "Folder permissions 750 for $SERVICE_USER"
}

start_and_verify() {
    info "Starting the service"
    run $SUDO systemctl restart "$SERVICE_NAME"
    local i
    for ((i = 0; i < 90; i++)); do
        if curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:${PANEL_PORT}/"; then
            ok "The panel answers on port $PANEL_PORT"
            return
        fi
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then break; fi
        sleep 2
    done
    run $SUDO journalctl -u "$SERVICE_NAME" -n 50 --no-pager
    die "The panel did not start. The last service log lines are in $LOG_FILE."
}


#MARK: Main
main() {
    echo
    echo "  Project Singularity installer"
    echo
    log "Project Singularity installer started, options: dir='${OPT_DIR}' build='${OPT_BUILD}' tag='${OPT_TAG}' no-apache=${OPT_NO_APACHE} no-mariadb=${OPT_NO_MARIADB} yes=${OPT_YES}"

    check_os
    check_privileges
    install_tools
    detect_existing_install
    handle_existing_install

    INSTALL_DIR="${OPT_DIR:-$(ask "Installation folder" "$DEFAULT_INSTALL_DIR")}"
    check_install_dir
    move_log_next_to "$INSTALL_DIR"
    ok "Installation folder $INSTALL_DIR"
    HB_STORE_FILE="$INSTALL_DIR/txData/hb_store.json"

    check_ports
    setup_mariadb
    choose_apache
    choose_artifact
    resolve_release

    #An empty folder that already exists is treated as created by this run,
    #so a rollback removes it with everything extracted into it.
    if $SUDO test -d "$INSTALL_DIR" && [[ -z "$($SUDO ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
        CREATED_PATHS+=("$INSTALL_DIR")
        log "$INSTALL_DIR exists but is empty, it is removed again on rollback"
    else
        make_dir "$INSTALL_DIR"
    fi
    install_artifact
    install_panel
    setup_server_data
    create_database
    write_panel_config
    setup_apache
    setup_service
    set_permissions
    start_and_verify
    rotate_backups
    disable_stopped_units

    INSTALL_OK=1
    log "installation finished"

    local host
    if [[ -n "$APACHE_DOMAIN" ]]; then
        host="https://${APACHE_DOMAIN}"
    else
        host="http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PANEL_PORT}"
    fi
    local wizard="${host}/setup"
    [[ -n "$SETUP_TOKEN" ]] && wizard="${wizard}?token=${SETUP_TOKEN}"

    echo
    echo "  Project Singularity is installed."
    echo
    echo "  Installation folder : $INSTALL_DIR"
    echo "  Setup wizard        : $wizard"
    echo "  Panel port          : $PANEL_PORT"
    echo "  Game server port    : $GAME_PORT"
    echo "  Database            : $DB_NAME (user $DB_USER)"
    echo "  Service             : $SERVICE_NAME (systemctl status $SERVICE_NAME)"
    echo "  Log file            : $LOG_FILE"
    echo
    if [[ -n "$SETUP_TOKEN" ]]; then
        echo "  The wizard link contains a one-time token, keep it private."
    fi
    if [[ -z "$APACHE_DOMAIN" ]]; then
        echo "  Passkeys need HTTPS or localhost. Over plain http the wizard uses a password instead."
    fi
    echo
}

main "$@"

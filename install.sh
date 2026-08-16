#!/usr/bin/env bash
#
# One-command WireGuard installer for Ubuntu/Debian.
#
#   - Installs and configures WireGuard as a systemd service
#   - Accepts clients on several UDP ports at once (53, 9200, 9201, ...)
#   - Delivers the client config to Telegram as a .conf file plus a QR code
#   - Architecture agnostic: works on aarch64 and x86_64 alike
#
# Usage:
#   curl -fsSL <raw-url>/install.sh | sudo bash -s -- \
#       --token 123456:AA... --chat -1001234567890 --ports 53,9200,9201
#
# Re-running is safe: server keys and existing peers are preserved.
#
set -euo pipefail

WG_DIR=/etc/wireguard
WG_IF=wg0
ENV_FILE="$WG_DIR/installer.env"
PEERS_FILE="$WG_DIR/peers.json"
SYSCTL_FILE=/etc/sysctl.d/99-wireguard.conf
WG_PEER_BIN=/usr/local/bin/wg-peer

# ---- defaults (overridable by flags, env, or an existing installer.env) ----
PORTS="${PORTS:-51820}"
NODE_NAME="${NODE_NAME:-}"
ENDPOINT="${ENDPOINT:-}"
WG_SUBNET="${WG_SUBNET:-10.13.13.0/24}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1, 1.0.0.1}"
MTU="${MTU:-1420}"
PEER_NAME="${PEER_NAME:-client}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
DO_UNINSTALL=0
PEER_EXPLICIT=0   # was --peer passed on this invocation?

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$GRN$BLD" "$RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: install.sh [options]

Required (unless already saved in /etc/wireguard/installer.env):
  --token <token>      Telegram bot token from @BotFather
  --chat <id>          Telegram chat id (negative for groups)

Optional:
  --ports <list>       Comma-separated UDP ports clients may use
                       (default: 51820).  Example: 53,9200,9201,443
  --name <name>        Label for this server (default: its public IP)
  --endpoint <ip|host> Override the auto-detected public address
  --subnet <cidr>      Tunnel subnet, /24 (default: 10.13.13.0/24)
  --dns <servers>      DNS pushed to clients (default: 1.1.1.1, 1.0.0.1)
  --mtu <n>            Client MTU (default: 1420)
  --peer <name>        Name of the peer created at install (default: client)
  --uninstall          Remove WireGuard config, service and helper
  -h, --help           Show this help
USAGE
}

# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)     TG_BOT_TOKEN="${2:-}"; shift 2 ;;
        --chat)      TG_CHAT_ID="${2:-}";   shift 2 ;;
        --ports)     PORTS="${2:-}";        shift 2 ;;
        --name)      NODE_NAME="${2:-}";    shift 2 ;;
        --endpoint)  ENDPOINT="${2:-}";     shift 2 ;;
        --subnet)    WG_SUBNET="${2:-}";    shift 2 ;;
        --dns)       CLIENT_DNS="${2:-}";   shift 2 ;;
        --mtu)       MTU="${2:-}";          shift 2 ;;
        --peer)      PEER_NAME="${2:-}"; PEER_EXPLICIT=1; shift 2 ;;
        --uninstall) DO_UNINSTALL=1;        shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           die "unknown option: $1  (try --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "must run as root (use sudo)"

# --------------------------------------------------------------------------
# uninstall
# --------------------------------------------------------------------------
if [[ $DO_UNINSTALL -eq 1 ]]; then
    log "Uninstalling WireGuard configuration"
    # PostDown removes the firewall rules this installer added
    systemctl disable --now "wg-quick@$WG_IF" 2>/dev/null || true
    rm -rf "$WG_DIR"
    rm -f "$SYSCTL_FILE" "$WG_PEER_BIN"
    sysctl --system >/dev/null 2>&1 || true
    log "Removed config, service and helper."
    log "apt packages (wireguard, qrencode, jq...) were left installed."
    exit 0
fi

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
log "Preflight checks"

[[ -r /etc/os-release ]] || die "cannot read /etc/os-release; unsupported system"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
    *ubuntu*|*debian*) : ;;
    *) die "this installer supports Ubuntu/Debian only (found: ${PRETTY_NAME:-unknown})" ;;
esac
log "OS: ${PRETTY_NAME:-unknown} ($(uname -m))"

# Carry forward previously saved settings so a bare re-run keeps working.
if [[ -f "$ENV_FILE" ]]; then
    log "Existing install detected; reusing saved settings for unset options"
    # shellcheck disable=SC1090
    ( . "$ENV_FILE" ) >/dev/null 2>&1 || die "$ENV_FILE is malformed"
    # Read one saved value in a subshell so it cannot clobber current settings.
    # shellcheck disable=SC1090
    saved() { ( . "$ENV_FILE"; printf '%s' "${!1:-}" ); }
    [[ -n "$TG_BOT_TOKEN" ]] || TG_BOT_TOKEN="$(saved TG_BOT_TOKEN)"
    [[ -n "$TG_CHAT_ID"   ]] || TG_CHAT_ID="$(saved TG_CHAT_ID)"
    [[ -n "$NODE_NAME"    ]] || NODE_NAME="$(saved NODE_NAME)"
    [[ -n "$ENDPOINT"     ]] || ENDPOINT="$(saved ENDPOINT)"

    # For options with a non-empty default we cannot tell "unset" from
    # "explicitly set to the default", so restore the saved value whenever the
    # current one is still the default. Without this, a bare re-run would
    # silently revert hand-edits made in installer.env.
    restore_if_default() {           # $1=var name  $2=default value
        local cur="${!1}" prev
        [[ "$cur" == "$2" ]] || return 0
        prev="$(saved "$1")"
        [[ -n "$prev" ]] && printf -v "$1" '%s' "$prev"
        return 0
    }
    restore_if_default PORTS      "51820"
    restore_if_default WG_SUBNET  "10.13.13.0/24"
    restore_if_default CLIENT_DNS "1.1.1.1, 1.0.0.1"
    restore_if_default MTU        "1420"
    # Keep the original peer name unless this run explicitly overrides it,
    # otherwise a bare re-run would create a second peer named "client".
    if [[ $PEER_EXPLICIT -eq 0 ]]; then
        prev="$(saved PEER_NAME)"
        [[ -n "$prev" ]] && PEER_NAME="$prev"
    fi
fi
: "${prev:=}"   # keep set -u happy when the block above did not run

[[ -n "$TG_BOT_TOKEN" ]] || die "--token is required (Telegram bot token)"
[[ -n "$TG_CHAT_ID"   ]] || die "--chat is required (Telegram chat id)"

# Validate and normalise the port list.
declare -a PORT_LIST=()
IFS=',' read -ra _raw <<<"$PORTS"
for p in "${_raw[@]}"; do
    p="${p//[[:space:]]/}"
    [[ -z "$p" ]] && continue
    [[ "$p" =~ ^[0-9]+$ ]] || die "invalid port: '$p'"
    (( p >= 1 && p <= 65535 )) || die "port out of range: $p"
    # skip duplicates
    for e in "${PORT_LIST[@]:-}"; do [[ "$e" == "$p" ]] && continue 2; done
    PORT_LIST+=("$p")
done
(( ${#PORT_LIST[@]} > 0 )) || die "no valid ports given"
PORTS="$(IFS=','; echo "${PORT_LIST[*]}")"

# wg-peer derives the server address from this; here we only validate the shape.
[[ "$WG_SUBNET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.0/24$ ]] \
    || die "--subnet must be a /24 like 10.13.13.0/24 (got: $WG_SUBNET)"

# --------------------------------------------------------------------------
# packages
#
# Installed before the kernel probe on purpose: the probe needs `ip` from
# iproute2, and probing without it reports a missing tool as an unsupported
# kernel, which sends you chasing the wrong problem.
# --------------------------------------------------------------------------
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    wireguard wireguard-tools iproute2 iptables qrencode curl jq >/dev/null
log "Packages installed"

# --------------------------------------------------------------------------
# kernel WireGuard support: fail here rather than halfway through
# --------------------------------------------------------------------------
command -v ip >/dev/null 2>&1 \
    || die "'ip' (iproute2) is missing even after install; cannot continue."
modprobe wireguard 2>/dev/null || true
if ! ip link add wgprobe type wireguard 2>/dev/null; then
    die "kernel does not support WireGuard.
     Most KVM VPSs and Ubuntu 20.04+ are fine; OpenVZ/LXC hosts often are not.
     Check your kernel (uname -r) or ask your provider."
fi
ip link del wgprobe 2>/dev/null || true
log "Kernel WireGuard: OK"

# --------------------------------------------------------------------------
# network detection
# --------------------------------------------------------------------------
detect_wan_if() {
    ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
detect_public_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        ip="$(curl -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
    done
    return 1
}

WAN_IF="$(detect_wan_if)"
[[ -n "$WAN_IF" ]] || die "could not determine the outbound network interface"
log "WAN interface: $WAN_IF"

if [[ -z "$ENDPOINT" ]]; then
    ENDPOINT="$(detect_public_ip)" \
        || die "could not detect the public IP; pass --endpoint <ip> explicitly"
fi
log "Public endpoint: $ENDPOINT"
[[ -n "$NODE_NAME" ]] || NODE_NAME="$ENDPOINT"

# --------------------------------------------------------------------------
# IP forwarding (persistent)
# --------------------------------------------------------------------------
log "Enabling IP forwarding"
cat >"$SYSCTL_FILE" <<'SYSCTL'
# Added by the WireGuard installer
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system >/dev/null

# --------------------------------------------------------------------------
# keys and state
# --------------------------------------------------------------------------
umask 077
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

if [[ ! -f "$WG_DIR/server_private.key" ]]; then
    log "Generating server keypair"
    wg genkey > "$WG_DIR/server_private.key"
    wg pubkey < "$WG_DIR/server_private.key" > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key" "$WG_DIR/server_public.key"
else
    log "Reusing existing server keypair (peers stay valid)"
fi

[[ -f "$PEERS_FILE" ]] || echo '{"peers":[]}' > "$PEERS_FILE"
chmod 600 "$PEERS_FILE"

# --------------------------------------------------------------------------
# save settings
# --------------------------------------------------------------------------
cat >"$ENV_FILE" <<ENVEOF
# Written by the WireGuard installer. Safe to edit; re-run install.sh after.
TG_BOT_TOKEN='$TG_BOT_TOKEN'
TG_CHAT_ID='$TG_CHAT_ID'
NODE_NAME='$NODE_NAME'
ENDPOINT='$ENDPOINT'
PORTS='$PORTS'
WG_SUBNET='$WG_SUBNET'
CLIENT_DNS='$CLIENT_DNS'
MTU='$MTU'
WAN_IF='$WAN_IF'
PEER_NAME='$PEER_NAME'
ENVEOF
chmod 600 "$ENV_FILE"

# --------------------------------------------------------------------------
# install the wg-peer helper
# --------------------------------------------------------------------------
log "Installing wg-peer helper"
cat >"$WG_PEER_BIN" <<'WGPEER_EOF'
#!/usr/bin/env bash
#
# wg-peer - manage WireGuard peers on this server.
# Installed by install.sh; state lives in /etc/wireguard.
#
set -euo pipefail

WG_DIR=/etc/wireguard
WG_IF=wg0
WG_PORT=51820
ENV_FILE="$WG_DIR/installer.env"
PEERS_FILE="$WG_DIR/peers.json"
CONF="$WG_DIR/$WG_IF.conf"

[[ $EUID -eq 0 ]] || { echo "wg-peer must be run as root" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE - run install.sh first" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

[[ "$WG_SUBNET" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$ ]] || {
    echo "bad WG_SUBNET in $ENV_FILE" >&2; exit 1; }
SUBNET_BASE="${BASH_REMATCH[1]}"
SERVER_IP="$SUBNET_BASE.1"

die() { echo "error: $*" >&2; exit 1; }

# Configs and QR images contain private keys; make sure the scratch directory
# is removed on every exit path, including die().
_TMPDIR=""
# Must return 0 explicitly: as the last command in an EXIT trap, a falsy
# test would become this script's exit status and break `set -e` callers.
cleanup() {
    if [[ -n "${_TMPDIR:-}" ]]; then rm -rf "$_TMPDIR"; fi
    return 0
}
trap cleanup EXIT

# Exit code used when a peer was created but Telegram delivery failed.
EXIT_TG_FAILED=3

primary_port() { echo "${PORTS%%,*}"; }

port_list() { local IFS=','; read -ra a <<<"$PORTS"; printf '%s\n' "${a[@]}"; }

# ---------------------------------------------------------------- rendering
# wg0.conf is a generated artifact: server key + peers.json are the truth.
render_conf() {
    local tmp; tmp="$(mktemp)"
    {
        echo "# Generated by wg-peer - do not edit by hand."
        echo "# Change settings in $ENV_FILE, then: wg-peer render"
        echo
        echo "[Interface]"
        echo "Address = $SERVER_IP/24"
        echo "ListenPort = $WG_PORT"
        echo "PrivateKey = $(cat "$WG_DIR/server_private.key")"
        echo

        # Multi-port: redirect each public UDP port to the single listener.
        while read -r p; do
            [[ -z "$p" || "$p" == "$WG_PORT" ]] && continue
            echo "PostUp = iptables -t nat -A PREROUTING -i $WAN_IF -p udp --dport $p -j REDIRECT --to-port $WG_PORT"
        done < <(port_list)

        # Accept the *redirected* port. Inserted at the top so it precedes
        # restrictive default REJECT rules (Oracle Cloud images ship one).
        echo "PostUp = iptables -I INPUT 1 -p udp --dport $WG_PORT -j ACCEPT"
        echo "PostUp = iptables -I FORWARD 1 -i %i -j ACCEPT"
        echo "PostUp = iptables -I FORWARD 1 -o %i -j ACCEPT"
        echo "PostUp = iptables -t nat -A POSTROUTING -s $WG_SUBNET -o $WAN_IF -j MASQUERADE"

        # Mirror image, tolerant of already-absent rules.
        echo "PostDown = iptables -t nat -D POSTROUTING -s $WG_SUBNET -o $WAN_IF -j MASQUERADE || true"
        echo "PostDown = iptables -D FORWARD -o %i -j ACCEPT || true"
        echo "PostDown = iptables -D FORWARD -i %i -j ACCEPT || true"
        echo "PostDown = iptables -D INPUT -p udp --dport $WG_PORT -j ACCEPT || true"
        while read -r p; do
            [[ -z "$p" || "$p" == "$WG_PORT" ]] && continue
            echo "PostDown = iptables -t nat -D PREROUTING -i $WAN_IF -p udp --dport $p -j REDIRECT --to-port $WG_PORT || true"
        done < <(port_list)

        jq -r '.peers[] |
            "\n[Peer]\n# name = \(.name)\nPublicKey = \(.pub)\nPresharedKey = \(.psk)\nAllowedIPs = \(.ip)/32"' \
            "$PEERS_FILE"
    } >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CONF"
}

# Apply peer changes without tearing the interface down, so live tunnels
# belonging to other peers are not interrupted.
sync_live() {
    if ip link show "$WG_IF" >/dev/null 2>&1; then
        wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
    fi
}

next_ip() {
    local used n ip
    used="$(jq -r '.peers[].ip' "$PEERS_FILE")"
    for n in $(seq 2 254); do
        ip="$SUBNET_BASE.$n"
        grep -qx "$ip" <<<"$used" || { echo "$ip"; return 0; }
    done
    die "no free addresses left in $WG_SUBNET"
}

peer_exists() { jq -e --arg n "$1" '.peers[]|select(.name==$n)' "$PEERS_FILE" >/dev/null 2>&1; }

client_conf() {
    local name="$1" port="${2:-$(primary_port)}"
    peer_exists "$name" || die "no such peer: $name"
    local priv psk ip
    priv="$(jq -r --arg n "$name" '.peers[]|select(.name==$n)|.priv' "$PEERS_FILE")"
    psk="$(jq -r  --arg n "$name" '.peers[]|select(.name==$n)|.psk'  "$PEERS_FILE")"
    ip="$(jq -r   --arg n "$name" '.peers[]|select(.name==$n)|.ip'   "$PEERS_FILE")"
    cat <<CONFEOF
[Interface]
PrivateKey = $priv
Address    = $ip/32
DNS        = $CLIENT_DNS
MTU        = $MTU

[Peer]
PublicKey           = $(cat "$WG_DIR/server_public.key")
PresharedKey        = $psk
Endpoint            = $ENDPOINT:$port
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CONFEOF
}

# ---------------------------------------------------------------- telegram
tg_api() {
    local method="$1"; shift
    curl -fsS --max-time 30 \
        "https://api.telegram.org/bot$TG_BOT_TOKEN/$method" "$@" 2>/dev/null
}

tg_send() {
    local name="$1" port="${2:-$(primary_port)}"
    local conf qr failed=""

    _TMPDIR="$(mktemp -d)"; chmod 700 "$_TMPDIR"
    conf="$_TMPDIR/${NODE_NAME}-${name}.conf"
    qr="$_TMPDIR/qr.png"
    client_conf "$name" "$port" >"$conf"
    qrencode -t PNG -o "$qr" <"$conf"

    local ports_pretty; ports_pretty="$(port_list | paste -sd', ' -)"
    local text
    text="$(printf '\xF0\x9F\x9F\xA2 %s\nIP: %s\npeer: %s\nports: %s' \
        "$NODE_NAME" "$ENDPOINT" "$name" "$ports_pretty")"

    tg_api sendMessage -d chat_id="$TG_CHAT_ID" --data-urlencode text="$text" \
        >/dev/null || failed+=" sendMessage"
    tg_api sendDocument -F chat_id="$TG_CHAT_ID" -F document=@"$conf" \
        >/dev/null || failed+=" sendDocument"
    tg_api sendPhoto -F chat_id="$TG_CHAT_ID" -F photo=@"$qr" \
        -F caption="$NODE_NAME - $ENDPOINT:$port ($name)" \
        >/dev/null || failed+=" sendPhoto"

    rm -rf "$_TMPDIR"; _TMPDIR=""

    if [[ -z "$failed" ]]; then
        echo "Sent '$name' to Telegram."
        return 0
    fi
    {
        echo "warning: Telegram delivery failed ($(echo "$failed" | xargs))."
        echo "         The peer '$name' WAS created and works - only delivery failed."
        echo "         Check TG_BOT_TOKEN / TG_CHAT_ID in $ENV_FILE, then retry:"
        echo "             wg-peer send $name"
        echo "         Or read the config here and now:"
        echo "             wg-peer qr $name"
    } >&2
    return "$EXIT_TG_FAILED"
}

# ---------------------------------------------------------------- commands
cmd_add() {
    local name="${1:-}"; [[ -n "$name" ]] || die "usage: wg-peer add <name>"
    peer_exists "$name" && die "peer '$name' already exists"
    local priv pub psk ip tmp
    priv="$(wg genkey)"; pub="$(wg pubkey <<<"$priv")"; psk="$(wg genpsk)"
    ip="$(next_ip)"
    tmp="$(mktemp)"
    jq --arg n "$name" --arg i "$ip" --arg pr "$priv" --arg pu "$pub" --arg ps "$psk" \
       '.peers += [{name:$n, ip:$i, priv:$pr, pub:$pu, psk:$ps}]' \
       "$PEERS_FILE" >"$tmp"
    mv "$tmp" "$PEERS_FILE"; chmod 600 "$PEERS_FILE"
    render_conf
    sync_live
    echo "Added peer '$name' ($ip)."
    # The peer exists regardless; propagate delivery failure as EXIT_TG_FAILED
    # so callers can tell "created and delivered" from "created only".
    local rc=0
    tg_send "$name" || rc="$EXIT_TG_FAILED"
    return "$rc"
}

cmd_remove() {
    local name="${1:-}"; [[ -n "$name" ]] || die "usage: wg-peer remove <name>"
    peer_exists "$name" || die "no such peer: $name"
    local pub tmp
    pub="$(jq -r --arg n "$name" '.peers[]|select(.name==$n)|.pub' "$PEERS_FILE")"
    ip link show "$WG_IF" >/dev/null 2>&1 && wg set "$WG_IF" peer "$pub" remove || true
    tmp="$(mktemp)"
    jq --arg n "$name" '.peers |= map(select(.name != $n))' "$PEERS_FILE" >"$tmp"
    mv "$tmp" "$PEERS_FILE"; chmod 600 "$PEERS_FILE"
    render_conf
    sync_live
    echo "Removed peer '$name'."
}

cmd_list() {
    if ! ip link show "$WG_IF" >/dev/null 2>&1; then
        echo "interface $WG_IF is down"
        jq -r '.peers[] | "  \(.name)\t\(.ip)\t(offline)"' "$PEERS_FILE"
        return
    fi
    local now; now="$(date +%s)"
    printf '%-16s %-14s %-14s %s\n' NAME ADDRESS HANDSHAKE TRANSFER
    while IFS=$'\t' read -r pub _psk _ep allowed hs rx tx _keep; do
        [[ -z "${pub:-}" ]] && continue
        local name ago
        name="$(jq -r --arg p "$pub" '.peers[]|select(.pub==$p)|.name' "$PEERS_FILE")"
        [[ -z "$name" ]] && name="(unknown)"
        if [[ "${hs:-0}" == "0" ]]; then
            ago="never"
        else
            ago="$(( now - hs ))s ago"
        fi
        printf '%-16s %-14s %-14s %s\n' \
            "$name" "${allowed%%/*}" "$ago" \
            "$(numfmt --to=iec "${rx:-0}")/$(numfmt --to=iec "${tx:-0}")"
    done < <(wg show "$WG_IF" dump | tail -n +2)
}

cmd_config() { client_conf "${1:?usage: wg-peer config <name> [port]}" "${2:-}"; }
cmd_send()   { tg_send     "${1:?usage: wg-peer send <name> [port]}"   "${2:-}"; }

cmd_qr() {
    local name="${1:?usage: wg-peer qr <name> [port]}"
    client_conf "$name" "${2:-}" | qrencode -t ANSIUTF8
}

cmd_render() {
    render_conf
    sync_live
    echo "Regenerated $CONF"
    echo "Note: PostUp/PostDown firewall changes need: systemctl restart wg-quick@$WG_IF"
}

case "${1:-}" in
    add)     shift; cmd_add    "$@" ;;
    remove)  shift; cmd_remove "$@" ;;
    list)    shift; cmd_list   "$@" ;;
    config)  shift; cmd_config "$@" ;;
    send)    shift; cmd_send   "$@" ;;
    qr)      shift; cmd_qr     "$@" ;;
    render)  shift; cmd_render "$@" ;;
    *)
        cat <<'HELP'
Usage: wg-peer <command>

  add <name>            Create a peer, apply it live, send it to Telegram
  remove <name>         Revoke a peer immediately
  list                  Show peers with handshake times and transfer
  config <name> [port]  Print a client config (optionally for another port)
  send <name> [port]    Re-send a peer's config to Telegram
  qr <name> [port]      Print the QR code in the terminal
  render                Regenerate wg0.conf from saved state
HELP
        exit 1 ;;
esac
WGPEER_EOF
chmod 755 "$WG_PEER_BIN"

# --------------------------------------------------------------------------
# render config and start
# --------------------------------------------------------------------------
log "Writing $WG_DIR/$WG_IF.conf"
"$WG_PEER_BIN" render >/dev/null \
    || die "failed to generate $WG_DIR/$WG_IF.conf (run '$WG_PEER_BIN render' to see why)"

log "Starting wg-quick@$WG_IF"
# Deliberately not silenced: hiding systemctl's stderr here once turned a
# clear failure into a silent exit.
systemctl enable "wg-quick@$WG_IF" >/dev/null \
    || die "could not enable wg-quick@$WG_IF (is this system running systemd?)"
systemctl restart "wg-quick@$WG_IF" \
    || die "wg-quick@$WG_IF failed to start. Inspect: journalctl -xeu wg-quick@$WG_IF"
systemctl is-active --quiet "wg-quick@$WG_IF" \
    || die "wg-quick@$WG_IF is not active. Inspect: journalctl -xeu wg-quick@$WG_IF"

# --------------------------------------------------------------------------
# first peer
# --------------------------------------------------------------------------
TG_DELIVERED=0
PEER_COUNT="$(jq '.peers|length' "$PEERS_FILE")"
if jq -e --arg n "$PEER_NAME" '.peers[]|select(.name==$n)' "$PEERS_FILE" >/dev/null 2>&1; then
    log "Peer '$PEER_NAME' already exists; not creating a duplicate"
    TG_DELIVERED=2   # pre-existing: nothing was sent this run
elif (( PEER_COUNT > 0 )) && (( PEER_EXPLICIT == 0 )); then
    # Peers already exist and no --peer was requested: adding one would make
    # a plain re-run non-idempotent.
    log "$PEER_COUNT peer(s) already configured; not adding another"
    log "Add one deliberately with: wg-peer add <name>"
    TG_DELIVERED=2
else
    log "Creating peer '$PEER_NAME'"
    if "$WG_PEER_BIN" add "$PEER_NAME"; then
        TG_DELIVERED=1
    else
        TG_DELIVERED=0
    fi
fi

# --------------------------------------------------------------------------
# summary
# --------------------------------------------------------------------------
PRIMARY="${PORTS%%,*}"
case "$TG_DELIVERED" in
    1) DELIVERY="Client config and QR code have been ${GRN}sent to Telegram${RST}." ;;
    2) DELIVERY="Peer already existed; nothing was sent this run.
Re-send it with:  ${BLD}wg-peer send $PEER_NAME${RST}" ;;
    *) DELIVERY="${RED}Telegram delivery FAILED${RST} - the server works, but the config was not sent.
Fix the token/chat id in $ENV_FILE, then:  ${BLD}wg-peer send $PEER_NAME${RST}
Or read it right now with:                 ${BLD}wg-peer qr $PEER_NAME${RST}" ;;
esac

cat <<SUMMARY

${GRN}${BLD}WireGuard is up.${RST}

  server      ${BLD}$NODE_NAME${RST}  ($ENDPOINT)
  endpoint    $ENDPOINT:$PRIMARY
  all ports   $PORTS
  subnet      $WG_SUBNET
  peer        $PEER_NAME

$DELIVERY

Next steps:
  ${BLD}wg-peer list${RST}                       peers, handshakes, transfer
  ${BLD}wg-peer add <name>${RST}                 add another device
  ${BLD}wg-peer qr $PEER_NAME${RST}              print the QR in this terminal
  ${BLD}wg-peer config $PEER_NAME 9201${RST}     same keys, different port

${YLW}Remember:${RST} your cloud firewall must allow inbound UDP on: $PORTS
On Oracle Cloud that is the VCN Security List / NSG ingress rules -
this script cannot configure it for you.
SUMMARY

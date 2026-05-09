#!/usr/bin/env bash
# One-shot installer for the juancastillom-analytics stack on Proxmox.
# Run on the Proxmox host as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/juancstlm/juancastillom-analytics/main/install.sh)"

set -euo pipefail

REPO_URL="https://github.com/juancstlm/juancastillom-analytics.git"
INSTALL_DIR="/opt/juancastillom-analytics"

# Defaults — override via prompts
DEFAULT_HOSTNAME="analytics"
DEFAULT_STORAGE="local-lvm"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_DISK="32"
DEFAULT_RAM="2048"
DEFAULT_CORES="2"
DEFAULT_TEMPLATE_STORAGE="local"
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

# ---------- helpers ----------

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
  # ask <var> <prompt> <default>
  local __var=$1 __prompt=$2 __default=${3:-}
  local __reply
  if [[ -n "$__default" ]]; then
    read -r -p "$__prompt [$__default]: " __reply
    __reply="${__reply:-$__default}"
  else
    read -r -p "$__prompt: " __reply
  fi
  printf -v "$__var" '%s' "$__reply"
}

ask_secret() {
  # ask_secret <var> <prompt>
  local __var=$1 __prompt=$2 __reply
  read -r -s -p "$__prompt: " __reply
  echo
  printf -v "$__var" '%s' "$__reply"
}

# ---------- preflight ----------

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v pct >/dev/null || die "pct not found — this must run on a Proxmox host."
command -v pveam >/dev/null || die "pveam not found — Proxmox tooling missing."

log "juancastillom-analytics installer"
echo

# ---------- prompts: container ----------

DEFAULT_VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
ask VMID      "VMID"                "$DEFAULT_VMID"
ask HOSTNAME  "Hostname"            "$DEFAULT_HOSTNAME"
ask STORAGE   "Container storage"   "$DEFAULT_STORAGE"
ask BRIDGE    "Network bridge"      "$DEFAULT_BRIDGE"
ask DISK      "Disk size (GB)"      "$DEFAULT_DISK"
ask RAM       "RAM (MB)"            "$DEFAULT_RAM"
ask CORES     "CPU cores"           "$DEFAULT_CORES"
ask IP_MODE   "Network (dhcp/static)" "dhcp"

if [[ "$IP_MODE" == "static" ]]; then
  ask STATIC_IP "Static IP with CIDR (e.g. 192.168.1.50/24)" ""
  ask GATEWAY   "Gateway"                                    ""
  NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=$STATIC_IP,gw=$GATEWAY"
else
  NET_CONFIG="name=eth0,bridge=$BRIDGE,ip=dhcp"
fi

if pct status "$VMID" >/dev/null 2>&1 || qm status "$VMID" >/dev/null 2>&1; then
  die "VMID $VMID already in use. Pick a different VMID or destroy the existing one."
fi

ask_secret ROOT_PASSWORD "Root password for the new LXC"
[[ -n "$ROOT_PASSWORD" ]] || die "Root password cannot be empty."

# ---------- prompts: app secrets ----------

echo
log "Application secrets (press enter to auto-generate where offered)"

ask APP_SECRET_INPUT "APP_SECRET (blank to auto-generate)" ""
if [[ -z "$APP_SECRET_INPUT" ]]; then
  APP_SECRET=$(openssl rand -base64 48 | tr -d '\n')
else
  APP_SECRET="$APP_SECRET_INPUT"
fi

ask DB_PASSWORD_INPUT "DB_PASSWORD (blank to auto-generate)" ""
if [[ -z "$DB_PASSWORD_INPUT" ]]; then
  DB_PASSWORD=$(openssl rand -hex 24)
else
  DB_PASSWORD="$DB_PASSWORD_INPUT"
fi

ask_secret TUNNEL_TOKEN "Cloudflare Tunnel token (from Zero Trust dashboard)"
[[ -n "$TUNNEL_TOKEN" ]] || die "TUNNEL_TOKEN cannot be empty."

ask TRACKER_SCRIPT_NAME "Tracker script filename (without .js)" "script"

# ---------- template ----------

TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"
if [[ ! -f "$TEMPLATE_PATH" ]]; then
  log "Downloading LXC template $TEMPLATE"
  pveam update >/dev/null
  pveam download "$DEFAULT_TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ---------- create LXC ----------

log "Creating LXC $VMID ($HOSTNAME)"
pct create "$VMID" "$DEFAULT_TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "$NET_CONFIG" \
  --features "keyctl=1,nesting=1" \
  --unprivileged 1 \
  --onboot 1 \
  --password "$ROOT_PASSWORD"

log "Starting LXC $VMID"
pct start "$VMID"

# Wait for network
log "Waiting for network inside LXC"
for _ in $(seq 1 30); do
  if pct exec "$VMID" -- bash -c 'getent hosts deb.debian.org >/dev/null 2>&1'; then
    break
  fi
  sleep 2
done

# ---------- provision inside LXC ----------

log "Installing Docker and dependencies inside LXC"
pct exec "$VMID" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
'

log "Cloning repo into $INSTALL_DIR"
pct exec "$VMID" -- bash -c "
set -euo pipefail
mkdir -p $(dirname $INSTALL_DIR)
if [[ ! -d $INSTALL_DIR ]]; then
  git clone $REPO_URL $INSTALL_DIR
fi
"

log "Writing .env"
# Pipe via stdin so secrets never appear on the command line / process table
pct exec "$VMID" -- bash -c "cat > $INSTALL_DIR/.env" <<EOF
DB_PASSWORD=$DB_PASSWORD
APP_SECRET=$APP_SECRET
TUNNEL_TOKEN=$TUNNEL_TOKEN
TRACKER_SCRIPT_NAME=$TRACKER_SCRIPT_NAME
EOF
pct exec "$VMID" -- chmod 600 "$INSTALL_DIR/.env"

log "Bringing up the stack"
pct exec "$VMID" -- bash -c "cd $INSTALL_DIR && docker compose up -d"

# ---------- done ----------

echo
log "Done."
cat <<EOF

Next steps:
  1. In Cloudflare Zero Trust -> Networks -> Tunnels, ensure your tunnel has a
     Public Hostname mapping:
       analytics.juancastillom.com  ->  http://umami:3000
  2. Open https://analytics.juancastillom.com and log in with admin / umami.
     Change the admin password immediately.
  3. Add each website under Settings -> Websites and embed the tracker:
       <script defer
         src="https://analytics.juancastillom.com/${TRACKER_SCRIPT_NAME}.js"
         data-website-id="WEBSITE-UUID"></script>

Manage the LXC:
  pct enter $VMID
  cd $INSTALL_DIR && docker compose ps
EOF

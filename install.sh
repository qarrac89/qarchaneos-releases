#!/usr/bin/env bash
# Installe QarchaneOS dans un conteneur LXC Debian 13 sur Proxmox VE.
#
# Usage (hôte Proxmox, en root), depuis le paquet de publication :
#   cd release && bash install.sh
#
# Après publication des fichiers :
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/qarrac89/qarchaneos-releases/main/install.sh)"
#
# Variables optionnelles :
#   CTID             identifiant du conteneur (auto si vide)
#   CORES MEMORY SWAP DISK   ressources (2 / 2048 / 512 / 16 par défaut)
#   BRIDGE IP GATEWAY        réseau (vmbr0 / dhcp / auto)
#   TEMPLATE_STORAGE ROOTFS_STORAGE   stockages (auto-détectés)
#   CT_HOSTNAME      nom du conteneur (qarchaneos)
#   SSH_PUBLIC_KEY   clé publique à autoriser (défaut : ~/.ssh/id_ed25519.pub)
#   BIN_URL          URL du binaire (dernière publication par défaut)
#   LOCAL_BIN        binaire local (détecté à côté du script si présent)
#   BIN_SHA256       empreinte SHA-256 (lue depuis BIN_URL.sha256 si absente)
set -euo pipefail

RELEASE_REPO="${RELEASE_REPO:-qarrac89/qarchaneos-releases}"
BIN_URL="${BIN_URL:-https://github.com/${RELEASE_REPO}/releases/latest/download/qarchane-linux-amd64}"

# Le paquet de publication place le binaire à côté de l'installeur : il est
# alors utilisé tel quel, sans téléchargement.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
LOCAL_BIN="${LOCAL_BIN:-}"
if [ -z "$LOCAL_BIN" ] && [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/qarchane-linux-amd64" ]; then
  LOCAL_BIN="$SCRIPT_DIR/qarchane-linux-amd64"
fi

[ "$(id -u)" -eq 0 ] || { echo "Exécutez ce script en root (shell Proxmox)." >&2; exit 1; }
command -v pct >/dev/null 2>&1 || { echo "Ce script doit tourner sur un hôte Proxmox VE." >&2; exit 1; }

CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"
SWAP="${SWAP:-512}"
DISK="${DISK:-16}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"
GATEWAY="${GATEWAY:-}"
CT_HOSTNAME="${CT_HOSTNAME:-qarchaneos}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"
BIN_SHA256="${BIN_SHA256:-}"

if [ -z "$BIN_SHA256" ]; then
  if [ -n "$LOCAL_BIN" ] && [ -f "${LOCAL_BIN}.sha256" ]; then
    BIN_SHA256="$(awk '{print $1}' "${LOCAL_BIN}.sha256" | head -n 1)"
  elif [ -z "$LOCAL_BIN" ]; then
    BIN_SHA256="$(curl -fsSL "${BIN_URL}.sha256" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
  fi
fi

detect_storage() {
  local content="$1" fallback="$2" found
  found=$(pvesm status --content "$content" 2>/dev/null | awk 'NR>1 {print $1; exit}' || true)
  if [ -n "$found" ]; then echo "$found"; else echo "$fallback"; fi
}

TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$(detect_storage vztmpl local)}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-$(detect_storage rootdir local-lvm)}"

echo "→ Mise à jour du catalogue de templates…"
pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam available --section system 2>/dev/null | awk '/debian-13/ {print $2; exit}')
if [ -z "$TEMPLATE" ]; then
  echo "Aucun template Debian 13 disponible. Vérifiez 'pveam available'." >&2
  exit 1
fi
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  echo "→ Téléchargement du template $TEMPLATE…"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

if [ -z "${CTID:-}" ]; then
  CTID=100
  # Un identifiant peut être occupé par un conteneur ou par une machine
  # virtuelle QEMU : les deux doivent être vérifiés.
  while pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; do
    CTID=$((CTID + 1))
  done
fi

if [ "$IP" = "dhcp" ]; then
  NET="name=eth0,bridge=$BRIDGE,ip=dhcp"
elif [ -n "$GATEWAY" ]; then
  NET="name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GATEWAY"
else
  NET="name=eth0,bridge=$BRIDGE,ip=$IP"
fi

echo "→ Création du conteneur $CTID ($CT_HOSTNAME)…"
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
  --rootfs "$ROOTFS_STORAGE:$DISK" \
  --net0 "$NET" \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 --start 1

if [ -f "$SSH_PUBLIC_KEY" ]; then
  pct push "$CTID" "$SSH_PUBLIC_KEY" /root/qarchane-authorized.pub
  pct exec "$CTID" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && cat /root/qarchane-authorized.pub >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && rm -f /root/qarchane-authorized.pub'
else
  echo "→ Aucune clé publique SSH trouvée ($SSH_PUBLIC_KEY) ; utilisez la console Proxmox." >&2
fi

echo "→ Installation de QarchaneOS dans le conteneur…"
INNER=$(mktemp)
cat > "$INNER" <<'INNER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
BIN_URL="$1"
BIN_SHA256="${2:-}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl tar

getent group qarchane >/dev/null || groupadd --system qarchane
if ! id qarchane >/dev/null 2>&1; then
  useradd --system --gid qarchane --home-dir /var/lib/qarchaneos \
    --shell /usr/sbin/nologin qarchane
fi

install -d -o root -g qarchane -m 0750 /opt/qarchaneos
install -d -o qarchane -g qarchane -m 0750 /var/lib/qarchaneos
install -d -o root -g qarchane -m 0750 /etc/qarchane

if [ -f /root/qarchane-linux-amd64 ]; then
  install -m 0755 /root/qarchane-linux-amd64 /opt/qarchaneos/qarchane
  rm -f /root/qarchane-linux-amd64
else
  curl -fsSL -o /opt/qarchaneos/qarchane "$BIN_URL"
  chmod 0755 /opt/qarchaneos/qarchane
fi
if [ -n "$BIN_SHA256" ]; then
  echo "$BIN_SHA256  /opt/qarchaneos/qarchane" | sha256sum -c -
else
  echo "Attention : aucune empreinte SHA-256 ; le binaire n'est pas vérifié." >&2
fi

cat > /etc/qarchane/qarchane.env <<'EOF'
QARCHANE_DIR=/opt/qarchaneos
QARCHANE_DATA_DIR=/var/lib/qarchaneos
QARCHANE_HELPER_SOCKET=/run/qarchane/helper.sock
RUST_LOG=info
EOF
chmod 0640 /etc/qarchane/qarchane.env
chown root:qarchane /etc/qarchane/qarchane.env

cat > /var/lib/qarchaneos/qarchane.toml <<'EOF'
[server]
listen = "127.0.0.1:8899"
data_dir = "/var/lib/qarchaneos"
worker_threads = 2
EOF
chown qarchane:qarchane /var/lib/qarchaneos/qarchane.toml
chmod 0640 /var/lib/qarchaneos/qarchane.toml

cat > /etc/systemd/system/qarchane-helper.service <<'EOF'
[Unit]
Description=QarchaneOS privileged installer helper
Documentation=https://github.com/qarrac89/QarchaneOS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=qarchane
RuntimeDirectory=qarchane
RuntimeDirectoryMode=0770
EnvironmentFile=/etc/qarchane/qarchane.env
ExecStart=/opt/qarchaneos/qarchane --config /var/lib/qarchaneos/qarchane.toml helper
Restart=always
RestartSec=3
UMask=0007
NoNewPrivileges=true
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER CAP_SETUID CAP_SETGID CAP_KILL
# Le service d'installation réduit les privilèges de ses applications
# (serveur de voix) : ces capacités ambiantes lui sont indispensables.
AmbientCapabilities=CAP_SETUID CAP_SETGID
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectHostname=true
ProtectClock=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
# Le helper installe le service vocal dans systemd.
ReadWritePaths=/opt/qarchaneos /var/lib/qarchaneos /run/qarchane /etc/systemd/system
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/qarchane.service <<'EOF'
[Unit]
Description=QarchaneOS
Documentation=https://github.com/qarrac89/QarchaneOS
After=network-online.target qarchane-helper.service
Wants=network-online.target qarchane-helper.service

[Service]
Type=simple
User=qarchane
Group=qarchane
EnvironmentFile=/etc/qarchane/qarchane.env
ExecStart=/opt/qarchaneos/qarchane --config /var/lib/qarchaneos/qarchane.toml serve
Restart=always
RestartSec=3
TimeoutStopSec=30
KillMode=mixed
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectKernelLogs=true
ProtectHostname=true
ProtectClock=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
ReadWritePaths=/var/lib/qarchaneos
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now qarchane-helper.service
systemctl enable --now qarchane.service
INNER_SCRIPT

if [ -n "$LOCAL_BIN" ]; then
  [ -f "$LOCAL_BIN" ] || { echo "Binaire introuvable : $LOCAL_BIN" >&2; exit 1; }
  pct push "$CTID" "$LOCAL_BIN" /root/qarchane-linux-amd64
fi

pct push "$CTID" "$INNER" /root/qarchane-install.sh
pct exec "$CTID" -- bash /root/qarchane-install.sh "$BIN_URL" "${BIN_SHA256:-}"
rm -f "$INNER"

CT_IP=""
for _ in $(seq 1 60); do
  CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  [ -n "$CT_IP" ] && break
  sleep 1
done

echo ""
echo "✅ QarchaneOS est installé dans le conteneur $CTID."
echo "   Interface : http://${CT_IP:-<IP-du-conteneur>}:8899"
echo "   Au premier accès, créez le compte administrateur."

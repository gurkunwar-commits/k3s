#!/usr/bin/env bash
#
# Install k3s server (head / control-plane node).
#
# Usage (on the head VM):
#   cp .env.example .env   # edit values first
#   sudo ./boot.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CLUSTER_ENV:-${SCRIPT_DIR}/.env}"

readonly K3S_INSTALL_URL="https://get.k3s.io"
readonly K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
readonly K3S_SERVICE="k3s"
readonly TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"

log()  { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root: sudo $0"
    exit 1
  fi
}

load_config() {
  if [[ ! -f "$ENV_FILE" ]]; then
    err "Config not found: $ENV_FILE"
    err "Copy .env.example to .env and set your IPs/domain."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$ENV_FILE"

  : "${HEAD_PRIVATE_IP:?Set HEAD_PRIVATE_IP in .env}"
  : "${HEAD_PUBLIC_IP:?Set HEAD_PUBLIC_IP in .env}"

  K3S_CHANNEL="${K3S_CHANNEL:-stable}"
  K3S_VERSION="${K3S_VERSION:-}"
  CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-}"
  API_HOST="${API_HOST:-$CLUSTER_DOMAIN}"
  FLANNEL_IFACE="${FLANNEL_IFACE:-}"
  KUBE_USER="${KUBE_USER:-}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { err "'$1' is required but not installed."; exit 1; }
}

install_node_prereqs() {
  # Longhorn needs an iSCSI initiator and NFS client on every node, and it needs
  # multipathd to not claim its block devices (otherwise mke2fs reports the
  # device is "in use by the system" and volumes never format).
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing node prerequisites (open-iscsi, nfs-common)"
    DEBIAN_FRONTEND=noninteractive apt-get update -y -qq || warn "apt-get update failed; continuing"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq open-iscsi nfs-common \
      || warn "Prerequisite install failed; Longhorn volumes may not work."
    systemctl enable --now iscsid 2>/dev/null || true
  else
    warn "Non-apt host: install open-iscsi + nfs-common manually for Longhorn."
  fi
  blacklist_multipath
}

blacklist_multipath() {
  # Keep multipathd from grabbing Longhorn's iSCSI devices.
  command -v multipath >/dev/null 2>&1 || return 0
  if ! grep -q "longhorn-blacklist" /etc/multipath.conf 2>/dev/null; then
    log "Excluding SCSI devices from multipathd (Longhorn compatibility)"
    cat >>/etc/multipath.conf <<'MP'

# longhorn-blacklist: keep multipathd from claiming Longhorn iSCSI devices
blacklist {
    devnode "^sd[a-z0-9]+"
}
MP
    systemctl restart multipathd 2>/dev/null || true
  fi
}

configure_firewall() {
  # The k3s installer does not firewall the host. Restrict the Kubernetes API
  # (6443) and the kubelet (10250) to the private network by dropping them on
  # the public interface. Idempotent and persisted across reboot.
  local pub_if port
  pub_if="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
  pub_if="${pub_if:-eth0}"
  for port in 6443 10250; do
    if ! iptables -C INPUT -i "$pub_if" -p tcp --dport "$port" -j DROP 2>/dev/null; then
      iptables -I INPUT 1 -i "$pub_if" -p tcp --dport "$port" \
        -m comment --comment "k3s-block-public-${port}" -j DROP
    fi
  done
  persist_firewall
  log "Firewall: API/kubelet dropped on public interface ${pub_if}"
}

persist_firewall() {
  mkdir -p /etc/iptables
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4
  else
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
    fi
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || warn "Could not persist firewall rules."
  fi
}

write_k3s_config() {
  mkdir -p /etc/rancher/k3s

  local tls_sans
  tls_sans=$(cat <<EOF
  - ${HEAD_PRIVATE_IP}
  - ${HEAD_PUBLIC_IP}
  - 127.0.0.1
  - localhost
EOF
)
  [[ -n "${API_HOST:-}" ]] && tls_sans+=$'\n'"  - ${API_HOST}"
  [[ -n "${BASE_DOMAIN:-}" && "${BASE_DOMAIN}" != "${API_HOST:-}" ]] && \
    tls_sans+=$'\n'"  - ${BASE_DOMAIN}"
  [[ -n "${CLUSTER_DOMAIN:-}" && "${CLUSTER_DOMAIN}" != "${API_HOST:-}" && "${CLUSTER_DOMAIN}" != "${BASE_DOMAIN:-}" ]] && \
    tls_sans+=$'\n'"  - ${CLUSTER_DOMAIN}"

  cat >/etc/rancher/k3s/config.yaml <<EOF
# Admin kubeconfig readable only by root (0600). setup_kubeconfig() installs a
# per-user copy for KUBE_USER.
write-kubeconfig-mode: "0600"
# Encrypt Secrets at rest in the datastore (AES-CBC via a generated key).
secrets-encryption: true
# Disable the bundled local-path provisioner: Longhorn is the storage layer, and
# leaving local-path installed creates a second default StorageClass (k3s
# re-applies its default annotation on every restart, so demoting it does not
# stick). Longhorn then remains the single default StorageClass.
disable:
  - local-storage
bind-address: 0.0.0.0
advertise-address: ${HEAD_PRIVATE_IP}
node-ip: ${HEAD_PRIVATE_IP}
node-external-ip: ${HEAD_PUBLIC_IP}
tls-san:
${tls_sans}
EOF

  if [[ -n "$FLANNEL_IFACE" ]]; then
    echo "flannel-iface: ${FLANNEL_IFACE}" >>/etc/rancher/k3s/config.yaml
  fi

  log "Wrote /etc/rancher/k3s/config.yaml"
}

install_k3s_server() {
  export INSTALL_K3S_CHANNEL="$K3S_CHANNEL"
  [[ -n "$K3S_VERSION" ]] && export INSTALL_K3S_VERSION="$K3S_VERSION"

  if systemctl is-active --quiet "$K3S_SERVICE" 2>/dev/null; then
    warn "k3s is already running; reinstalling/upgrading in place."
  fi

  log "Installing k3s server"
  log "Private IP: ${HEAD_PRIVATE_IP}"
  log "Public IP:  ${HEAD_PUBLIC_IP}"
  [[ -n "${API_HOST:-}" ]] && log "API host:   ${API_HOST}"

  curl -sfL "$K3S_INSTALL_URL" | sh -
}

wait_for_api() {
  local retries=60
  export KUBECONFIG="$K3S_KUBECONFIG"

  log "Waiting for Kubernetes API..."
  while (( retries > 0 )); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
      log "Kubernetes API is ready."
      return 0
    fi
    sleep 2
    (( retries-- )) || true
  done

  err "Timed out waiting for Kubernetes API."
  systemctl status "$K3S_SERVICE" --no-pager || true
  journalctl -u "$K3S_SERVICE" -n 50 --no-pager || true
  exit 1
}

resolve_kube_user() {
  if [[ -n "$KUBE_USER" ]]; then
    printf '%s' "$KUBE_USER"
  elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    printf '%s' "$SUDO_USER"
  else
    printf '%s' "root"
  fi
}

setup_kubeconfig() {
  local user home api_host kube_dir kube_config
  user="$(resolve_kube_user)"
  home="$(getent passwd "$user" | cut -d: -f6)"

  if [[ -z "$home" ]]; then
    warn "Could not resolve home for user '$user'; skipping kubeconfig copy."
    return
  fi

  api_host="${API_HOST:-${CLUSTER_DOMAIN:-$HEAD_PUBLIC_IP}}"
  kube_dir="${home}/.kube"
  kube_config="${kube_dir}/config"

  install -d -m 700 -o "$user" -g "$user" "$kube_dir"
  cp "$K3S_KUBECONFIG" "$kube_config"
  chown "$user:$user" "$kube_config"
  chmod 600 "$kube_config"

  # The API server (6443) is private-only (firewalled on the public interface),
  # so the on-host admin kubeconfig must point at the loopback address, which
  # always works locally. k3s may write either 127.0.0.1 or 0.0.0.0; normalise
  # to 127.0.0.1. For remote admin, use the private endpoint printed in the
  # summary (https://${HEAD_PRIVATE_IP}:6443) over the private network / VPN.
  sed -i -E "s|server: https://0\.0\.0\.0:6443|server: https://127.0.0.1:6443|" "$kube_config"

  # write-kubeconfig-mode is 0600, so the k3s `kubectl` wrapper cannot read the
  # root-owned /etc/rancher/k3s/k3s.yaml as this user. Point the user's shell at
  # their own readable copy.
  local profile="${home}/.bashrc"
  if [[ -f "$profile" ]] && ! grep -q "KUBECONFIG=\$HOME/.kube/config" "$profile" 2>/dev/null; then
    printf '\nexport KUBECONFIG=$HOME/.kube/config\n' >>"$profile"
    chown "$user:$user" "$profile"
  fi
  log "kubeconfig installed at ${kube_config} (server: https://127.0.0.1:6443; KUBECONFIG exported for ${user})"
}

print_summary() {
  local token join_url api_host
  token="$(cat "$TOKEN_FILE" 2>/dev/null || true)"
  join_url="https://${HEAD_PRIVATE_IP}:6443"
  api_host="${API_HOST:-${CLUSTER_DOMAIN:-$HEAD_PUBLIC_IP}}"

  cat <<EOF

k3s head node installation complete.

API access:
  https://${api_host}:6443

Worker join URL (private network only):
  ${join_url}

Add this token to worker/.env as K3S_TOKEN, then run worker/boot.sh on each worker:

Node token (keep secret):
  ${token:-<unavailable>}

Verify:
  kubectl get nodes -o wide

EOF
}

main() {
  require_root
  load_config
  require_command curl

  install_node_prereqs
  write_k3s_config
  install_k3s_server
  wait_for_api
  configure_firewall
  setup_kubeconfig
  print_summary
}

main "$@"

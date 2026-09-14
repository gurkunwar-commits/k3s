#!/usr/bin/env bash
#
# Install k3s agent and join the head node via private IP.
#
# Usage (on each worker VM):
#   cp .env.example .env
#   # set HEAD_PRIVATE_IP and K3S_TOKEN from the head node
#   sudo ./boot.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CLUSTER_ENV:-${SCRIPT_DIR}/.env}"

readonly K3S_INSTALL_URL="https://get.k3s.io"
readonly K3S_SERVICE="k3s-agent"

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
    err "Copy .env.example to .env and set HEAD_PRIVATE_IP and K3S_TOKEN."
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$ENV_FILE"

  : "${HEAD_PRIVATE_IP:?Set HEAD_PRIVATE_IP in .env}"
  : "${K3S_TOKEN:?Set K3S_TOKEN in .env (from the head node)}"

  K3S_CHANNEL="${K3S_CHANNEL:-stable}"
  K3S_VERSION="${K3S_VERSION:-}"
  K3S_NODE_NAME="${K3S_NODE_NAME:-$(hostname -s)}"
  FLANNEL_IFACE="${FLANNEL_IFACE:-}"
  WORKER_PRIVATE_IP="${WORKER_PRIVATE_IP:-}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { err "'$1' is required but not installed."; exit 1; }
}

detect_private_ip() {
  if [[ -n "$WORKER_PRIVATE_IP" ]]; then
    printf '%s' "$WORKER_PRIVATE_IP"
    return
  fi

  # Prefer an RFC1918 private address. On cloud hosts `hostname -I` lists the
  # PUBLIC IP first, so taking field 1 blindly would advertise the node on the
  # public interface — set WORKER_PRIVATE_IP to override this heuristic.
  local ip=""
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    warn "No RFC1918 private IP detected; using ${ip}. Set WORKER_PRIVATE_IP if that is public."
  fi
  printf '%s' "$ip"
}

install_node_prereqs() {
  # Longhorn needs an iSCSI initiator and NFS client on every node, and needs
  # multipathd to leave its block devices alone (else volume formatting fails).
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
  # Drop the kubelet port (10250) on the public interface; it is only needed on
  # the private cluster network. Idempotent and persisted across reboot.
  local pub_if
  pub_if="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
  pub_if="${pub_if:-eth0}"
  if ! iptables -C INPUT -i "$pub_if" -p tcp --dport 10250 -j DROP 2>/dev/null; then
    iptables -I INPUT 1 -i "$pub_if" -p tcp --dport 10250 \
      -m comment --comment "k3s-block-public-kubelet" -j DROP
  fi
  mkdir -p /etc/iptables
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || iptables-save >/etc/iptables/rules.v4
  else
    command -v apt-get >/dev/null 2>&1 && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || true
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || warn "Could not persist firewall rules."
  fi
  log "Firewall: kubelet dropped on public interface ${pub_if}"
}

write_k3s_config() {
  local node_ip="$1"
  mkdir -p /etc/rancher/k3s

  cat >/etc/rancher/k3s/config.yaml <<EOF
node-ip: ${node_ip}
EOF

  if [[ -n "$FLANNEL_IFACE" ]]; then
    echo "flannel-iface: ${FLANNEL_IFACE}" >>/etc/rancher/k3s/config.yaml
  fi
}

install_k3s_agent() {
  local node_ip join_url
  node_ip="$(detect_private_ip)"
  join_url="https://${HEAD_PRIVATE_IP}:6443"

  if [[ -z "$node_ip" ]]; then
    err "Could not detect this node's private IP. Set WORKER_PRIVATE_IP in .env."
    exit 1
  fi

  write_k3s_config "$node_ip"

  export INSTALL_K3S_CHANNEL="$K3S_CHANNEL"
  [[ -n "$K3S_VERSION" ]] && export INSTALL_K3S_VERSION="$K3S_VERSION"
  export K3S_URL="$join_url"
  export K3S_TOKEN
  export K3S_NODE_NAME

  if systemctl is-active --quiet "$K3S_SERVICE" 2>/dev/null; then
    warn "k3s-agent is already running; reinstalling/upgrading in place."
  fi

  log "Joining cluster at ${join_url}"
  log "Node name:  ${K3S_NODE_NAME}"
  log "Node IP:    ${node_ip}"

  curl -sfL "$K3S_INSTALL_URL" | sh -
}

wait_for_agent() {
  local retries=30
  log "Waiting for k3s-agent to start..."

  while (( retries > 0 )); do
    if systemctl is-active --quiet "$K3S_SERVICE"; then
      log "k3s-agent is running."
      return 0
    fi
    sleep 2
    (( retries-- )) || true
  done

  err "k3s-agent did not start in time."
  systemctl status "$K3S_SERVICE" --no-pager || true
  journalctl -u "$K3S_SERVICE" -n 50 --no-pager || true
  exit 1
}

print_summary() {
  cat <<EOF

k3s worker joined successfully.

Node:     ${K3S_NODE_NAME}
Joined:   https://${HEAD_PRIVATE_IP}:6443

On the head node, verify with:
  kubectl get nodes -o wide

EOF
}

main() {
  require_root
  load_config
  require_command curl

  install_node_prereqs
  install_k3s_agent
  wait_for_agent
  configure_firewall
  print_summary
}

main "$@"

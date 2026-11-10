#!/usr/bin/env bash
# =============================================================================
# Kubernetes Worker Node Startup Script
# Based on: https://devopscube.com/setup-kubernetes-cluster-kubeadm/
#
# Purpose: Prepares a VM to act as a Kubernetes worker node, then joins the
#          cluster using a kubeadm join token+hash from the master node.
#
# Run as: Root (GCP/AWS/Azure VM startup script or manually via sudo bash)
#
# Usage:
#   Option A — pass join details as env vars (recommended for startup scripts):
#     KUBE_JOIN_TOKEN=<token> \
#     KUBE_JOIN_CA_CERT_HASH=<sha256:hash> \
#     KUBE_MASTER_IP=<master-internal-ip> \
#     bash worker-startup.sh
#
#   Option B — pass the raw join command string:
#     KUBE_JOIN_COMMAND="kubeadm join <master-ip>:6443 --token <token> \
#       --discovery-token-ca-cert-hash sha256:<hash>" \
#     bash worker-startup.sh
#
#   Option C — interactive (prompted at runtime):
#     bash worker-startup.sh
#
# To get the join command from the master node:
#   sudo cat /var/log/kubeadm-join-command.txt
#   OR regenerate: sudo kubeadm token create --print-join-command
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Versions — keep in sync with master-startup.sh
# ---------------------------------------------------------------------------
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"   # env-overridable; bare run = 1.35 — keep in sync with master-startup.sh
KUBERNETES_PATCH="${KUBERNETES_PATCH:-}"           # optional exact patch pin, e.g. 1.34.5 — deterministic N-1 source for the upgrade drill
CRICTL_VERSION="v1.35.0"           # pinned per manual validation
CONTAINERD_VERSION="1.7.23"
CNI_PLUGINS_VERSION="v1.6.2"
# Join command is NOT hard-coded — it carries a live, short-lived token + CA hash.
# Supply it at runtime via the KUBE_JOIN_COMMAND env var (Option B), the individual
# KUBE_* components (Option A), or the interactive prompt (Option C). See header.
KUBE_JOIN_COMMAND="${KUBE_JOIN_COMMAND:-}"
# CR-01 injection seams: the paths below are written via plain shell redirects
# (or `tee`), which PATH-mocking cannot intercept. They default to the canonical
# host paths for real runs, but are env-overridable so the unit cases
# (tests/cases/setup_*.sh) can redirect every filesystem write into their
# sandbox instead of mutating real host state.
LOG_FILE="${LOG_FILE:-/var/log/k8s-worker-startup.log}"
APT_KEYRINGS_DIR="${APT_KEYRINGS_DIR:-/etc/apt/keyrings}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# WR-01: fail fast on a version/patch stream mismatch. The apt repo stream is
# selected by KUBERNETES_VERSION while the exact pin comes from KUBERNETES_PATCH;
# nothing else checks they agree, and a mismatch would otherwise fail deep into
# the bootstrap (after swap/sysctl/containerd/apt-sources mutations) leaving a
# half-provisioned node that needs a full teardown.
if [[ -n "$KUBERNETES_PATCH" && "$KUBERNETES_PATCH" != "${KUBERNETES_VERSION}."* ]]; then
  die "KUBERNETES_PATCH=${KUBERNETES_PATCH} is not in the KUBERNETES_VERSION=${KUBERNETES_VERSION} stream (set both, e.g. KUBERNETES_VERSION=1.34 KUBERNETES_PATCH=1.34.5)"
fi

# Guard: skip re-join if this node is already part of a cluster.
# Prevents accidental re-initialization on VM restart.
is_already_joined() {
  [ -f /etc/kubernetes/kubelet.conf ]
}

# ---------------------------------------------------------------------------
# 1. System prerequisites
# (Identical to master — both node types need the same kernel configuration)
# ---------------------------------------------------------------------------
setup_system() {
  log "=== Step 1: System prerequisites ==="

  # Disable swap — kubelet refuses to start if swap is active
  swapoff -a
  sed -i '/\bswap\b/d' /etc/fstab

  # overlay: containerd overlay filesystem driver
  # br_netfilter: allows iptables to intercept bridged traffic for kube-proxy
  cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system

  log "System prerequisites done."
}

# ---------------------------------------------------------------------------
# 2. Container Runtime: containerd
# ---------------------------------------------------------------------------
install_containerd() {
  log "=== Step 2: Install containerd ${CONTAINERD_VERSION} ==="

  apt-get update -qq
  apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  # IMPORTANT: kubeadm requires a CRI-enabled runtime on the expected socket.
  # Avoid silently installing a newer major containerd package that may not
  # serve CRI v1 on `unix:///var/run/containerd/containerd.sock`.
  local available_version
  available_version="$(apt-cache madison containerd.io 2>/dev/null | awk '{print $3}' | grep -E "^${CONTAINERD_VERSION}([~+.-]|$)" | head -n 1 || true)"
  if [ -z "${available_version}" ]; then
    available_version="$(apt-cache madison containerd.io 2>/dev/null | awk '{print $3}' | grep -E '^1\.7\.' | head -n 1 || true)"
  fi
  [ -n "${available_version}" ] || die "No compatible containerd.io 1.7.x package found in apt repositories."
  apt-get install -y -qq "containerd.io=${available_version}"

  # SystemdCgroup = true — must match the master's containerd config and kubelet
  # cgroup driver. Mismatch causes kubelet to fail with "failed to run Kubelet".
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  # Ensure CRI plugin is not disabled (some vendor configs disable it explicitly).
  sed -i 's/^\s*disabled_plugins\s*=.*/disabled_plugins = []/' /etc/containerd/config.toml

  systemctl enable --now containerd
  log "containerd installed and running."
}

# ---------------------------------------------------------------------------
# Runtime readiness gates
# ---------------------------------------------------------------------------
wait_for_cri() {
  log "Waiting for container runtime (CRI) to be ready..."
  systemctl restart containerd

  local i
  for i in {1..60}; do
    if crictl info >/dev/null 2>&1; then
      log "CRI is ready."
      return 0
    fi
    sleep 1
  done

  log "containerd status:"
  systemctl --no-pager -l status containerd || true
  die "CRI did not become ready (crictl info failed)."
}

# ---------------------------------------------------------------------------
# 3. crictl — CRI CLI tool for debugging container runtimes
# ---------------------------------------------------------------------------
install_crictl() {
  log "=== Step 3: Install crictl ${CRICTL_VERSION} ==="

  curl -fsSLo /tmp/crictl.tar.gz \
    "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  tar -C /usr/local/bin -xzf /tmp/crictl.tar.gz
  rm -f /tmp/crictl.tar.gz

  cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF
  log "crictl ${CRICTL_VERSION} installed."
}

# ---------------------------------------------------------------------------
# 4. CNI plugins
# ---------------------------------------------------------------------------
install_cni_plugins() {
  log "=== Step 4: Install CNI plugins ${CNI_PLUGINS_VERSION} ==="

  mkdir -p /opt/cni/bin
  curl -fsSLo /tmp/cni-plugins.tgz \
    "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz"
  tar -C /opt/cni/bin -xzf /tmp/cni-plugins.tgz
  rm -f /tmp/cni-plugins.tgz
  log "CNI plugins installed."
}

# ---------------------------------------------------------------------------
# 5. kubeadm, kubelet, kubectl
# ---------------------------------------------------------------------------
install_kubernetes_tools() {
  log "=== Step 5: Install kubeadm / kubelet / kubectl (k8s ${KUBERNETES_VERSION}) ==="

  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key" \
    | gpg --dearmor -o "${APT_KEYRINGS_DIR}/kubernetes-apt-keyring.gpg"

  echo "deb [signed-by=${APT_KEYRINGS_DIR}/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" \
    > "${APT_SOURCES_DIR}/kubernetes.list"

  apt-get update -qq
  # Optional exact-patch pin: when KUBERNETES_PATCH is set (e.g. 1.34.5) install that
  # exact patch so the N-1 upgrade-drill source is deterministic; otherwise install the
  # latest patch in the selected minor stream (current baseline behaviour). The pins are
  # separate argv words passed straight to apt-get — never eval'd (mirrors WR-03).
  if [[ -n "$KUBERNETES_PATCH" ]]; then
    apt-get install -y -qq \
      "kubelet=${KUBERNETES_PATCH}-*" "kubeadm=${KUBERNETES_PATCH}-*" "kubectl=${KUBERNETES_PATCH}-*"
  else
    apt-get install -y -qq kubelet kubeadm kubectl
  fi

  # Pin to prevent unintended upgrades that would break cluster version skew policy
  apt-mark hold kubelet kubeadm kubectl

  systemctl enable --now kubelet
  log "kubeadm / kubelet / kubectl installed and held."
}

# ---------------------------------------------------------------------------
# 6. Join the cluster
# ---------------------------------------------------------------------------
join_cluster() {
  log "=== Step 6: Join cluster ==="

  local -a jc=()

  # kubeadm join preflight requires CRI v1 on the runtime socket.
  wait_for_cri

  # Priority 1: full join command provided as env var
  if [[ -n "${KUBE_JOIN_COMMAND:-}" ]]; then
    # WR-03: do NOT eval the string. Word-split it into an array so shell
    # metacharacters in the (candidate- or metadata-supplied) value become
    # inert argv elements rather than executable shell (e.g. a trailing
    # `; rm -rf /var/lib/etcd` lands as literal args to kubeadm, not a command).
    # Then sanity-check the shape before running it.
    read -ra jc <<<"$KUBE_JOIN_COMMAND"
    [[ "${jc[0]:-}" == "kubeadm" && "${jc[1]:-}" == "join" ]] || \
      die "KUBE_JOIN_COMMAND must start with 'kubeadm join' (got: ${jc[*]:-<empty>})"

  # Priority 2: individual token components provided as env vars
  elif [[ -n "${KUBE_MASTER_IP:-}" && -n "${KUBE_JOIN_TOKEN:-}" && -n "${KUBE_JOIN_CA_CERT_HASH:-}" ]]; then
    jc=(kubeadm join "${KUBE_MASTER_IP}:6443"
      --token "$KUBE_JOIN_TOKEN"
      --discovery-token-ca-cert-hash "$KUBE_JOIN_CA_CERT_HASH"
      --cri-socket unix:///var/run/containerd/containerd.sock)

  # Priority 3: interactive prompt (useful for manual runs)
  else
    log "No join parameters found in environment. Prompting interactively..."
    read -rp "Enter master node internal IP: " master_ip
    read -rp "Enter kubeadm join token: " token
    read -rp "Enter CA cert hash (sha256:...): " ca_hash

    [[ -z "$master_ip" || -z "$token" || -z "$ca_hash" ]] && \
      die "Master IP, token, and CA hash are all required."

    jc=(kubeadm join "${master_ip}:6443"
      --token "$token"
      --discovery-token-ca-cert-hash "$ca_hash"
      --cri-socket unix:///var/run/containerd/containerd.sock)
  fi

  # WR-04: redact the bootstrap token + CA hash before logging — the join
  # credentials must not land in the world-readable startup log.
  log "Executing: $(printf '%s' "${jc[*]}" | sed -E 's/(--token[ =])[^ ]+/\1<redacted>/g; s/(--discovery-token-ca-cert-hash[ =])[^ ]+/\1<redacted>/g')"
  # WR-03: invoke the array directly — no eval, no re-parsing of the string.
  "${jc[@]}" | tee -a "$LOG_FILE"

  log "Node successfully joined the cluster."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "======================================================"
  log "Starting Kubernetes Worker Node Startup Script"
  log "======================================================"

  if is_already_joined; then
    log "Node already joined a cluster — skipping kubeadm join."
    log "To re-join, run: kubeadm reset && rm -f /etc/kubernetes/kubelet.conf"
    exit 0
  fi

  setup_system
  install_containerd
  install_crictl
  install_cni_plugins
  install_kubernetes_tools
  join_cluster

  log "======================================================"
  log "Worker node setup complete!"
  log "Verify on master: kubectl get nodes"
  log "======================================================"
}

# Run main only when executed directly (bash worker-startup.sh / sudo bash ...), NOT
# when sourced. Sourcing leaves the bootstrap functions (install_kubernetes_tools, ...)
# callable in isolation so tests/cases can exercise them without running the full
# bootstrap. Behaviour-preserving: a direct invocation still runs main exactly as before.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi


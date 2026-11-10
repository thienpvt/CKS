#!/usr/bin/env bash
# =============================================================================
# Kubernetes Control Plane (Master) Node Startup Script
# Based on: https://devopscube.com/setup-kubernetes-cluster-kubeadm/
#
# Purpose: Bootstraps a Kubernetes control-plane node using kubeadm.
# Run as: Root (GCP/AWS/Azure VM startup script or manually via sudo bash)
#
# Key design decisions:
#   - CRICTL_VERSION pinned to v1.35.0 per manual validation.
#   - advertiseAddress is auto-detected from the VM's primary internal NIC
#     so the script is portable across different VM internal IPs.
#   - CNI: Calico (v3.29) — works with the 192.168.0.0/16 pod CIDR used here.
#   - containerd is used as the CRI (industry standard since Docker shim removal).
#   - kubeadm init uses a config file (kubeadm-config.yaml) rather than CLI
#     flags so every parameter is explicit and auditable.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Versions — update here to pin a different release
# ---------------------------------------------------------------------------
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.35}"   # env-overridable; bare run = 1.35 (maps to pkgs.k8s.io repo stream)
KUBERNETES_PATCH="${KUBERNETES_PATCH:-}"           # optional exact patch pin, e.g. 1.34.5 — deterministic N-1 source for the upgrade drill
CRICTL_VERSION="v1.35.0"           # must match kubelet CRI-tools expectation
CALICO_VERSION="v3.29.0"
CONTAINERD_VERSION="1.7.23"        # latest stable containerd 1.7 LTS
CNI_PLUGINS_VERSION="v1.6.2"

POD_CIDR="192.168.0.0/16"          # Calico default; change if using Flannel (10.244.0.0/16)
SERVICE_CIDR="10.96.0.0/12"        # Kubernetes default

# CR-01 injection seams: the paths below are written via plain shell redirects
# (or `tee`), which PATH-mocking cannot intercept. They default to the canonical
# host paths for real runs, but are env-overridable so the unit cases
# (tests/cases/setup_*.sh) can redirect every filesystem write into their
# sandbox instead of mutating real host state.
LOG_FILE="${LOG_FILE:-/var/log/k8s-master-startup.log}"
KUBEADM_INIT_LOG="${KUBEADM_INIT_LOG:-/var/log/kubeadm-init.log}"
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

# Detect the primary internal IP of this VM.
# Tries GCP metadata first; falls back to the first address on the main NIC.
# This value is injected into kubeadm's localAPIEndpoint so that the API
# server advertises the correct internal address to other cluster members.
get_internal_ip() {
  # GCP metadata endpoint
  local ip
  ip=$(curl -sf --max-time 2 \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip" 2>/dev/null) && {
      echo "$ip"; return
    }
  # AWS / generic fallback — first IP from hostname -I
  hostname -I | awk '{print $1}'
}

# Guard: skip re-initialization if control-plane is already running.
# Useful when a VM restarts after initial bootstrap.
is_already_initialized() {
  [ -f /etc/kubernetes/admin.conf ]
}

# ---------------------------------------------------------------------------
# 1. System prerequisites
# ---------------------------------------------------------------------------
setup_system() {
  log "=== Step 1: System prerequisites ==="

  # Disable swap permanently — kubelet requires swap to be off.
  swapoff -a
  sed -i '/\bswap\b/d' /etc/fstab

  # Load required kernel modules.
  # overlay: needed by containerd for the overlayfs storage driver.
  # br_netfilter: enables iptables to see bridged traffic (needed for kube-proxy).
  cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  # Sysctl: let iptables process bridged IPv4/IPv6 traffic and enable IP forwarding.
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

  # Install required packages for apt over HTTPS
  apt-get update -qq
  apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release

  # Docker's official GPG key (containerd is distributed through Docker's repo)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  # IMPORTANT: kubeadm requires a CRI-enabled runtime on the expected socket.
  # Some containerd major versions / distro packages may not expose CRI on
  # `unix:///var/run/containerd/containerd.sock`, which makes kubeadm preflight fail.
  # We therefore *only* install containerd 1.7.x (or explicitly pinned) here.
  local available_version
  available_version="$(apt-cache madison containerd.io 2>/dev/null | awk '{print $3}' | grep -E "^${CONTAINERD_VERSION}([~+.-]|$)" | head -n 1 || true)"
  if [ -z "${available_version}" ]; then
    available_version="$(apt-cache madison containerd.io 2>/dev/null | awk '{print $3}' | grep -E '^1\.7\.' | head -n 1 || true)"
  fi
  [ -n "${available_version}" ] || die "No compatible containerd.io 1.7.x package found in apt repositories."
  apt-get install -y -qq "containerd.io=${available_version}"

  # Generate and patch default config:
  #   SystemdCgroup = true — ensures containerd and kubelet share the same
  #   cgroup driver (systemd), preventing kubelet startup failures.
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
# 3. crictl — CRI command-line tool for debugging container runtimes
# ---------------------------------------------------------------------------
install_crictl() {
  log "=== Step 3: Install crictl ${CRICTL_VERSION} ==="

  curl -fsSLo /tmp/crictl.tar.gz \
    "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
  tar -C /usr/local/bin -xzf /tmp/crictl.tar.gz
  rm -f /tmp/crictl.tar.gz

  # Point crictl at containerd's unix socket
  cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF
  log "crictl ${CRICTL_VERSION} installed."
}

# ---------------------------------------------------------------------------
# 4. CNI plugins (required by containerd for pod networking)
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

  # Kubernetes changed to per-minor-version apt repos starting from v1.28
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

  # Pin versions to prevent unintended upgrades
  apt-mark hold kubelet kubeadm kubectl

  systemctl enable --now kubelet
  log "kubeadm / kubelet / kubectl installed and held."
}

# ---------------------------------------------------------------------------
# 6. Initialize control-plane with kubeadm
# ---------------------------------------------------------------------------
init_control_plane() {
  log "=== Step 6: Initialize control-plane with kubeadm ==="

  local internal_ip
  internal_ip=$(get_internal_ip)
  log "Detected internal IP: ${internal_ip}"

  # kubeadm preflight requires CRI v1 to be served by the runtime socket.
  wait_for_cri

  # Write kubeadm config file.
  # Using a config file instead of CLI flags makes the exact API parameters
  # visible, auditable, and reproducible.
  cat > /tmp/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  # advertiseAddress MUST be the internal IP of this VM so that worker nodes
  # (and other control-plane nodes) can reach the API server on the correct
  # interface. Using 0.0.0.0 would bind all interfaces but could advertise
  # the wrong IP in multi-homed environments.
  advertiseAddress: ${internal_ip}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# systemd cgroup driver must match containerd's cgroup driver
cgroupDriver: systemd
EOF

  kubeadm init --config /tmp/kubeadm-config.yaml --upload-certs \
    | tee "$KUBEADM_INIT_LOG"

  log "kubeadm init complete."
}

# ---------------------------------------------------------------------------
# 7. Configure kubectl for the ubuntu / default admin user
# ---------------------------------------------------------------------------
setup_kubectl() {
  log "=== Step 7: Configure kubectl ==="

  # Setup for root
  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config

  # Setup for the first non-root user (ubuntu on GCP, ec2-user on AWS, etc.)
  local admin_user
  admin_user=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "ubuntu")
  if id "$admin_user" &>/dev/null; then
    # WR-07: resolve the home dir straight from the passwd record — never eval
    # a string built from an NSS-supplied username (the codebase's own WR-03
    # no-eval discipline; the home dir is already in the getent record).
    local user_home
    user_home=$(getent passwd "$admin_user" | cut -d: -f6)
    [ -n "$user_home" ] || die "could not resolve home directory for ${admin_user}"
    mkdir -p "${user_home}/.kube"
    cp /etc/kubernetes/admin.conf "${user_home}/.kube/config"
    chown -R "${admin_user}:${admin_user}" "${user_home}/.kube"
    log "kubectl configured for user: ${admin_user}"
  fi
}

# ---------------------------------------------------------------------------
# 8. Install Calico CNI
# ---------------------------------------------------------------------------
install_calico() {
  log "=== Step 8: Install Calico CNI ${CALICO_VERSION} ==="

  # kubectl must be available; use the admin kubeconfig created in step 7
  export KUBECONFIG=/etc/kubernetes/admin.conf

  kubectl create -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

  # Download and patch the custom-resources manifest to match our POD_CIDR.
  # Calico defaults to 192.168.0.0/16 so no patch needed unless you changed it.
  curl -fsSLo /tmp/calico-custom-resources.yaml \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

  # Replace the default CIDR if it differs from POD_CIDR
  sed -i "s|192.168.0.0/16|${POD_CIDR}|g" /tmp/calico-custom-resources.yaml
  kubectl create -f /tmp/calico-custom-resources.yaml

  log "Calico CNI applied — pods will become ready once Calico controllers start."
}

# ---------------------------------------------------------------------------
# 9. Print join command for worker nodes
# ---------------------------------------------------------------------------
print_join_command() {
  log "=== Step 9: Worker node join command ==="

  local join_cmd
  join_cmd=$(kubeadm token create --print-join-command)

  # Save to a well-known file so automation can retrieve it
  echo "$join_cmd" > /var/log/kubeadm-join-command.txt
  chmod 600 /var/log/kubeadm-join-command.txt

  log "Join command saved to /var/log/kubeadm-join-command.txt"
  log "--- JOIN COMMAND (token + CA hash redacted) ---"
  # WR-04: the bootstrap token + CA hash are live cluster-join credentials. The
  # full command lives in the chmod-600 file above; the world-readable startup
  # log gets a redacted form so the secret is not duplicated into a 0644 file.
  log "$(printf '%s' "$join_cmd" | sed -E 's/(--token[ =])[^ ]+/\1<redacted>/g; s/(--discovery-token-ca-cert-hash[ =])[^ ]+/\1<redacted>/g')"
  log "Retrieve the real value with: sudo cat /var/log/kubeadm-join-command.txt"
  log "--------------------"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "======================================================"
  log "Starting Kubernetes Master Node Startup Script"
  log "======================================================"

  if is_already_initialized; then
    log "Control-plane already initialized — skipping kubeadm init."
    print_join_command
    exit 0
  fi

  setup_system
  install_containerd
  install_crictl
  install_cni_plugins
  install_kubernetes_tools
  init_control_plane
  setup_kubectl
  install_calico
  print_join_command

  log "======================================================"
  log "Master node setup complete!"
  log "Retrieve worker join command: cat /var/log/kubeadm-join-command.txt"
  log "======================================================"
}

# Run main only when executed directly (bash master-startup.sh / sudo bash ...), NOT
# when sourced. Sourcing leaves the bootstrap functions (install_kubernetes_tools, ...)
# callable in isolation so tests/cases can exercise them without running the full
# bootstrap. Behaviour-preserving: a direct invocation still runs main exactly as before.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi


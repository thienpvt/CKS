#!/usr/bin/env bash
# Reuse reviewed cka-packs installers; adapt only containerd and Calico for EC2.
set -euo pipefail

check_platform() {
  [[ "$*" == 'ubuntu 26.04 x86_64 0' ]] || {
    printf '%s\n' 'node-setup requires Ubuntu 26.04 amd64 as root' >&2; return 1;
  }
}

check_runtime() {
  [[ "$1" =~ ^containerd[[:space:]]+[^[:space:]]+[[:space:]]+v?2\. ]] || {
    printf '%s\n' 'node-setup requires containerd 2.x' >&2; return 1;
  }
}

runtime_config() {
  local config
  config=$(containerd config default)
  [[ "$config" == *'SystemdCgroup = false'* ]] || {
    printf '%s\n' 'Unexpected containerd config; refusing to guess cgroup settings' >&2; return 1;
  }
  printf '%s\n' "$config" | sed 's/SystemdCgroup = false/SystemdCgroup = true/g'
}

ubuntu_containerd() {
  apt-get update -qq
  apt-get install -y containerd ca-certificates curl gnupg lsb-release apparmor apparmor-utils ec2-instance-connect
  check_runtime "$(containerd --version)"
  install -d -m 0755 /etc/containerd /etc/apt/keyrings
  runtime_config > /etc/containerd/config.toml
  systemctl enable --now containerd
  systemctl restart containerd
}

ubuntu_calico() (
  # Always encapsulate across EC2 nodes; no VPC routes or source/dest-check changes.
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT
  export KUBECONFIG=/etc/kubernetes/admin.conf
  curl -fsSLo "$tmp/operator.yaml" 'https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml'
  curl -fsSLo "$tmp/resources.yaml" 'https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/custom-resources.yaml'
  grep -q 'encapsulation: VXLANCrossSubnet' "$tmp/resources.yaml" || {
    printf '%s\n' 'Unexpected Calico manifest; refusing to guess network settings' >&2; return 1;
  }
  sed -i -e 's/encapsulation: VXLANCrossSubnet/encapsulation: VXLAN/' \
    -e '/^  calicoNetwork:$/a\    bgp: Disabled' "$tmp/resources.yaml"
  kubectl create -f "$tmp/operator.yaml"
  local crd
  for crd in installations.operator.tigera.io apiservers.operator.tigera.io \
    goldmanes.operator.tigera.io whiskers.operator.tigera.io; do
    # The operator creates CRDs asynchronously; wait for existence before Established.
    local deadline=$((SECONDS + 300))
    until kubectl get crd "$crd" >/dev/null 2>&1; do
      (( SECONDS < deadline )) || { printf 'Timed out waiting for %s\n' "$crd" >&2; return 1; }
      sleep 2
    done
    # A new CRD may exist before status.conditions; kubectl wait can fail immediately.
    until kubectl wait --for=condition=Established "crd/$crd" --timeout=5s; do
      (( SECONDS < deadline )) || { printf 'Timed out waiting for %s\n' "$crd" >&2; return 1; }
      sleep 2
    done
  done
  kubectl create -f "$tmp/resources.yaml"
)

install_calico() { ubuntu_calico; }

untaint_master() {
  local taints
  taints=$(kubectl --kubeconfig=/etc/kubernetes/admin.conf get node cks-master \
    -o jsonpath='{range .spec.taints[*]}{.key}{":"}{.effect}{"\n"}{end}') || return
  if grep -qx 'node-role.kubernetes.io/control-plane:NoSchedule' <<< "$taints"; then
    kubectl --kubeconfig=/etc/kubernetes/admin.conf taint node cks-master \
      node-role.kubernetes.io/control-plane:NoSchedule-
  fi
}

bootstrap() {
  local role="${1:-}" setup="${2:-}"
  case "$role" in master|worker) ;; *) printf '%s\n' 'Usage: node-setup.sh master|worker /absolute/setup/path' >&2; return 1 ;; esac
  [[ "$setup" == /* && -r "$setup/$role-startup.sh" ]] || {
    printf '%s\n' "missing readable script: $setup/$role-startup.sh" >&2; return 1;
  }
  umask 022 # Apt's _apt user must read generated repository/keyring files.
  # Source only operator-supplied, reviewed code. Original scripts have main guards.
  source "$setup/$role-startup.sh"
  install_containerd() { ubuntu_containerd; }
  install_calico() { ubuntu_calico; }
  ( main "$role" ) # Original main exits early when the node is already initialized.
  if [[ "$role" == master ]]; then untaint_master; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# == 2 ]] || { printf '%s\n' 'Usage: node-setup.sh master|worker /absolute/setup/path' >&2; exit 1; }
  source /etc/os-release
  check_platform "$ID" "$VERSION_ID" "$(uname -m)" "$(id -u)"
  bootstrap "$@"
fi

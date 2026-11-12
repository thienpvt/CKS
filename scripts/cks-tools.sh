#!/usr/bin/env bash
# Separate from kubeadm bootstrap: install tools without installing lab policies.
set -euo pipefail

verify_asset() {
  python3 -I - "$1" "$2" <<'PY'
import hashlib, pathlib, re, sys
root, name = pathlib.Path(sys.argv[1]), sys.argv[2]
entries = []
for line in (root / 'checksums').read_text().splitlines():
    parts = line.split()
    if len(parts) == 2 and parts[1].lstrip('*') == name:
        entries.append(parts[0])
if len(entries) != 1 or not re.fullmatch('[0-9a-fA-F]{64}', entries[0]):
    sys.exit('Missing or ambiguous SHA256 entry: ' + name)
with (root / name).open('rb') as stream:
    actual = hashlib.file_digest(stream, 'sha256').hexdigest()
if actual != entries[0].lower():
    sys.exit('SHA256 mismatch: ' + name)
print(actual + '  ' + name)
PY
}

download() {
  local url="$1" name="$2" sha="$3"
  STAGE=$(mktemp -d "$WORK/release.XXXXXX")
  curl --fail --silent --show-error --location --retry 3 --max-time 600 \
    --proto '=https' --proto-redir '=https' "$url" -o "$STAGE/$name"
  printf '%s  %s\n' "$sha" "$name" > "$STAGE/checksums"
  verify_asset "$STAGE" "$name" >> /opt/cks/releases.sha256
}

unpack() {
  mkdir "$STAGE/unpacked"
  tar -xzf "$STAGE/$1" --no-same-owner --no-same-permissions -C "$STAGE/unpacked"
}

install_tools() (
  [[ $(id -u) == 0 && $(uname -m) == x86_64 ]] || {
    printf 'Run as root on Ubuntu 26.04 amd64\n' >&2; exit 1;
  }
  source /etc/os-release
  [[ "$ID $VERSION_ID" == 'ubuntu 26.04' ]] || exit 1
  [[ -r /etc/kubernetes/manifests/etcd.yaml ]] || {
    printf 'Run on the control-plane after cluster bootstrap\n' >&2; exit 1;
  }
  grep -q 'image: registry.k8s.io/etcd:3.6.6-0' /etc/kubernetes/manifests/etcd.yaml || {
    printf 'etcd changed; pin matching etcdctl before installing\n' >&2; exit 1;
  }
  umask 022
  apt-get -o Acquire::Retries=3 update -qq
  apt-get -o Acquire::Retries=3 install -y ca-certificates curl python3 jq apparmor-utils util-linux
  install -d -m 0755 /opt/cks /opt/cks/charts /opt/cks/images /opt/cks/trivy /usr/local/bin
  WORK=$(mktemp -d)
  trap 'rm -rf -- "$WORK"' EXIT

  download https://github.com/etcd-io/etcd/releases/download/v3.6.6/etcd-v3.6.6-linux-amd64.tar.gz \
    etcd.tar.gz 887afaa4a99f22d802ccdfbe65730a5e79aa5c9ce2c8799c67e9d804c50ecedb
  unpack etcd.tar.gz
  install -m 0755 "$STAGE/unpacked/etcd-v3.6.6-linux-amd64/etcdctl" /usr/local/bin/etcdctl
  install -m 0755 "$STAGE/unpacked/etcd-v3.6.6-linux-amd64/etcdutl" /usr/local/bin/etcdutl

  download https://github.com/aquasecurity/kube-bench/releases/download/v0.16.0/kube-bench_0.16.0_linux_amd64.tar.gz \
    bench.tar.gz 82dbc7e598740dc9344d41f8ad0b8210d57c4c00bdb2c5f1d8a69a2b98baddcf
  unpack bench.tar.gz
  install -m 0755 "$STAGE/unpacked/kube-bench" /usr/local/bin/kube-bench
  install -d -m 0755 /etc/kube-bench
  cp -R "$STAGE/unpacked/cfg" /etc/kube-bench/

  download https://github.com/aquasecurity/trivy/releases/download/v0.76.2/trivy_0.76.2_Linux-64bit.tar.gz \
    trivy.tar.gz bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
  unpack trivy.tar.gz
  install -m 0755 "$STAGE/unpacked/trivy" /usr/local/bin/trivy

  # Keep detached-key signing behavior consistent with the offline acceptance check.
  download https://github.com/sigstore/cosign/releases/download/v2.6.3/cosign-linux-amd64 \
    cosign 7c78a7f2efc00088bd788a758db6e0928e79f3e0eb83eb5d3c499ed98da4c4f4
  install -m 0755 "$STAGE/cosign" /usr/local/bin/cosign

  download https://github.com/controlplaneio/kubesec/releases/download/v2.15.0/kubesec_linux_amd64.tar.gz \
    kubesec.tar.gz 69a03d83c53112499971755de4741d149d9ed0ab5cdea4682efb5cf95c6ef8e7
  unpack kubesec.tar.gz
  install -m 0755 "$STAGE/unpacked/kubesec" /usr/local/bin/kubesec

  download https://github.com/stackrox/kube-linter/releases/download/v0.8.3/kube-linter-linux.tar.gz \
    linter.tar.gz 1a6d8419b11971372971fdbc22682b684ebfb7cf1c39591662d1b6ca736c41df
  unpack linter.tar.gz
  install -m 0755 "$STAGE/unpacked/kube-linter" /usr/local/bin/kube-linter

  download https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz \
    helm.tar.gz a7f81ce08007091b86d8bd696eb4d86b8d0f2e1b9f6c714be62f82f96a594496
  unpack helm.tar.gz
  install -m 0755 "$STAGE/unpacked/linux-amd64/helm" /usr/local/bin/helm

  download https://github.com/mikefarah/yq/releases/download/v4.54.3/yq_linux_amd64 \
    yq 129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973
  install -m 0755 "$STAGE/yq" /usr/local/bin/yq

  download https://github.com/falcosecurity/charts/releases/download/falco-9.2.2/falco-9.2.2.tgz \
    falco-9.2.2.tgz b8a1aa984c3d513ab1639be760e6a07a9eb203d4da77a45a1512d382b6d3687d
  install -m 0644 "$STAGE/falco-9.2.2.tgz" /opt/cks/charts/
  download https://kyverno.github.io/kyverno/kyverno-3.9.2.tgz \
    kyverno-3.9.2.tgz f6fe7184544d5e2ee33a77808c09e67aa603ce6560cc197038fde31d727c861e
  install -m 0644 "$STAGE/kyverno-3.9.2.tgz" /opt/cks/charts/

  # Kubesec otherwise fetches schemas on every scan; keep validation enabled offline.
  install -d -m 0755 /opt/cks/schemas /etc/profile.d
  while read -r sha resource; do
    download "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/9367d1ce1c88b8bbf6ee06d0e80510f26394913f/v1.35.10-standalone-strict/$resource.json" \
      "$resource.json" "$sha"
    install -m 0644 "$STAGE/$resource.json" /opt/cks/schemas/
  done <<'SCHEMAS'
df6e1fe99d94e35944027b7bc4317039f22f49cff40c4eb1dc0b54f02fcf8940 cronjob-batch-v1
d6adf88a0790ee7c51f240b01712aaafc897fd2212633aa76331c2a38c216789 daemonset-apps-v1
46dc7cc4bec2c9a62400491e2b8057635afbfa6838999c518f7bea5c621a989b deployment-apps-v1
514d04ed5540a4d6354bff1ace0bd5155c98c58bcd33a030d1500427387fa97f job-batch-v1
ab3eec94c85e6b166a62312ddb919fb747a53d1f5701a77befb17419361b52b0 pod-v1
692ba879efafb2cb506fe07715edc09c6633aede444243c9477391e980eb5c35 replicaset-apps-v1
f3c6b47c63b8477ee5ec0d76c263367ded55103bea3831c21db59dcd1f8af7d5 replicationcontroller-v1
da78ed86dce07983c3e54c565def2c2e478fd458155ac7cd56cf671e88e16ee2 statefulset-apps-v1
SCHEMAS
  printf '%s\n' "export SCHEMA_LOCATION='/opt/cks/schemas/{{.ResourceKind}}{{.KindSuffix}}.json'" \
    > /etc/profile.d/cks-tools.sh

  trivy image --cache-dir /opt/cks/trivy --download-db-only
  ctr -n k8s.io images pull --platform linux/amd64 \
    docker.io/library/alpine@sha256:55ae5d250caebc548793f321534bc6a8ef1d116f334f18f4ada1b2daad3251b2 >/dev/null
  ctr -n k8s.io images export --platform linux/amd64 /opt/cks/images/alpine.tar \
    docker.io/library/alpine@sha256:55ae5d250caebc548793f321534bc6a8ef1d116f334f18f4ada1b2daad3251b2
  ctr -n k8s.io images pull --platform linux/amd64 \
    docker.io/library/busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec >/dev/null
  {
    date -u --iso-8601=seconds
    kubectl version --client; crictl --version; etcdctl version; etcdutl version
    kube-bench version; trivy --version; cosign version; kubesec version
    kube-linter version; helm version --short; yq --version; jq --version
    dpkg-query -W jq apparmor-utils
  } > /opt/cks/versions.txt
  printf 'TOOLS_INSTALLED: /opt/cks/versions.txt; run check-cks-tools.sh before snapshotting\n'
)

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  [[ $# == 0 ]] || { printf 'Usage: sudo bash cks-tools.sh\n' >&2; exit 1; }
  install_tools
fi

#!/usr/bin/env bash
# Run on the control-plane as root after cks-tools.sh. No policy installation.
set -euo pipefail
[[ $(id -u) == 0 ]] || { printf 'Run as root\n' >&2; exit 1; }
export KUBECONFIG=/etc/kubernetes/admin.conf
CACHE=/opt/cks
kubectl wait --for=condition=Ready nodes --all --timeout=300s
[[ $(kubectl get nodes -o name | wc -l) == 2 ]]
kubectl -n kube-system rollout status deployment/coredns --timeout=180s
kubectl get --raw /version >/dev/null
crictl ps >/dev/null
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key endpoint health
printf 'CLUSTER_AND_ETCD_PASS\n'

# Prove a pod can start on each node without pulling from an external registry.
NS="cks-offline-check-$(date +%s)"
kubectl create namespace "$NS"
trap 'kubectl delete namespace "$NS" --wait=false >/dev/null' EXIT
for node in cks-master cks-worker; do
  kubectl -n "$NS" run "$node" --restart=Never \
    --image=busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec \
    --image-pull-policy=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$node\",\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    --command -- sleep 300
done
kubectl -n "$NS" wait --for=condition=Ready pods --all --timeout=180s
for node in cks-master cks-worker; do
  kubectl -n "$NS" exec "$node" -- nslookup kubernetes.default.svc.cluster.local
done
kubectl delete namespace "$NS" --wait=true
trap - EXIT
printf 'CACHED_PODS_PASS\n'

# A fresh network namespace has no external route: --version is not the gate.
unshare --net -- bash -s <<'OFFLINE'
set -euo pipefail
export HOME=/root
CACHE=/opt/cks
TEST=$(mktemp -d)
trap 'rm -rf -- "$TEST"' EXIT
printf 'kind: Pod\nmetadata:\n  name: offline\n' > "$TEST/object.yaml"
yq -e '.metadata.name == "offline"' "$TEST/object.yaml"
printf '{"offline":true}\n' | jq -e '.offline == true'
kubectl create secret generic offline-check --from-literal=fixture=disposable \
  --dry-run=client -o json | jq -e '.data.fixture == "ZGlzcG9zYWJsZQ=="'
helm template falco "$CACHE"/charts/falco-*.tgz > "$TEST/falco.yaml"
helm template kyverno "$CACHE"/charts/kyverno-*.tgz > "$TEST/kyverno.yaml"
test -s "$TEST/falco.yaml" && test -s "$TEST/kyverno.yaml"

cat > "$TEST/pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: insecure-test
spec:
  containers:
  - name: test
    image: busybox:1.37.0
    securityContext:
      privileged: true
YAML
# Findings are expected for this deliberately insecure fixture, not execution errors.
set +e
SCHEMA_LOCATION='/opt/cks/schemas/{{.ResourceKind}}{{.KindSuffix}}.json' \
  kubesec scan "$TEST/pod.yaml" > "$TEST/kubesec.json"
status=$?
set -e
[[ $status == 0 || $status == 2 ]]
jq -e '.[0].valid == true and .[0].score < 0' "$TEST/kubesec.json"
set +e
kube-linter lint "$TEST/pod.yaml" > "$TEST/linter.log" 2>&1
status=$?
set -e
[[ $status == 1 ]] && grep -q 'privileged' "$TEST/linter.log"

# Same-UID local signing, no transparency upload; signature verification stays enabled.
export COSIGN_PASSWORD='disposable-offline-check'
cosign generate-key-pair --output-key-prefix "$TEST/key"
printf 'offline verification fixture\n' > "$TEST/blob"
cosign sign-blob --yes --tlog-upload=false --key "$TEST/key.key" \
  --output-signature "$TEST/blob.sig" "$TEST/blob"
cosign verify-blob --key "$TEST/key.pub" --signature "$TEST/blob.sig" \
  --insecure-ignore-tlog "$TEST/blob"
printf 'tampered\n' >> "$TEST/blob"
if cosign verify-blob --key "$TEST/key.pub" --signature "$TEST/blob.sig" \
    --insecure-ignore-tlog "$TEST/blob" >/dev/null 2>&1; then
  printf 'Tampered blob accepted\n' >&2; exit 1
fi

trivy image --cache-dir "$CACHE/trivy" --skip-db-update --offline-scan \
  --scanners vuln --input "$CACHE/images/alpine.tar" --format json --output "$TEST/trivy.json"
jq -e '.Metadata.OS.Family | length > 0' "$TEST/trivy.json"
# CIS failures are normal on an unhardened lab; ensure the scan actually ran.
kube-bench run --benchmark cis-1.11 --targets controlplane,node,etcd,policies \
  --config-dir /etc/kube-bench/cfg --json > "$TEST/bench.json"
jq -e 'length > 0' "$TEST/bench.json"
# Namespace isolation changes host networking checks: not a CIS compliance verdict.
printf 'OFFLINE_TOOLS_PASS\n'
OFFLINE

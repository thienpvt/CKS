# Domain 0: two-node EC2 lab

One-time installation; one clean snapshot pair; restore both roots after each lab.
**Ubuntu 26.04 amd64, one control-plane, one worker.** No EKS, HA, simulator bootstrap, node IAM role, or AWS credentials inside the lab. Connect from your terminal using **AWS CLI + SSH through a private EC2 Instance Connect Endpoint**, username `ubuntu`; no console required. AWS credentials stay on the workstation.

Cloud changes incur charges; review the account, region, instance IDs and costs before running them. Snapshot/reset erases lab changes when restored. Use a dedicated, disposable environment—never a shared or production cluster.

**Live evidence (2026-11-10):** two Ubuntu 26.04 nodes, Kubernetes v1.35.10, containerd 2.2.2, Calico VXLAN, CoreDNS, cross-node DNS/HTTP, NetworkPolicy deny/re-allow, cgroup2 and AppArmor passed. The earlier cluster-only snapshot pair passed root restore and namespace/file rollback. Terminal SSH/SCP through private EIC endpoint `eice-03af049301137e42a` passed without console access. CKS tools and caches are now installed; live acceptance returned `CLUSTER_AND_ETCD_PASS`, `CACHED_PODS_PASS`, and `OFFLINE_TOOLS_PASS`. Tool checks ran with no external network route. Snapshot/stop acceptance for the new tool-complete pair is tracked in section 7; do not infer its restore test from the old pair. Temporary terminal-IP ingress remains removed; endpoint/security groups/older snapshots/displaced roots are retained. Offline regression suite: 20 tests passed.

## Automated lifecycle (local Bash)

Run from the repository with AWS CLI v2 (`aws` or `aws.exe`), OpenSSH, `curl`, and authenticated AWS credentials. Every action mutates AWS immediately; `reset` destroys node changes and `cleanup` permanently deletes owned lab resources. Review `aws sts get-caller-identity` and the region before running.

```bash
export AWS_REGION=ap-southeast-1
export PURPOSE_TAG=cks-domain0        # Dedicated ownership tag; use the same value for every action.
export SSH_MODE=eic
export STARTUP_SOURCE=/absolute/path/to/cka-sim/scripts/setup
# Optional: reuse an existing endpoint without modifying/tagging/deleting it.
# Required where the VPC's endpoint quota is already occupied.
# export EIC_ENDPOINT=eice-REPLACE
# Optional network overrides:
# export VPC_ID=vpc-REPLACE SUBNET_ID=subnet-REPLACE
# Optional burst CPU credits: extra charges possible; standard is the default.
# export CPU_CREDITS=unlimited

./scripts/cks-lab.sh init
./scripts/cks-lab.sh pause
./scripts/cks-lab.sh resume
./scripts/cks-lab.sh reset
./scripts/cks-lab.sh cleanup
```

`init` creates two Ubuntu 26.04 nodes, bootstraps Kubernetes, installs/checks the CKS toolbox, freezes both roots with node services masked, captures baseline snapshots, then restarts a Ready cluster. State is queried from AWS tags, not a committed local state file. SSH keys/known-hosts remain under `$HOME/.local/state/cks-domain0/access` (`SSH_KEY_DIR` override).

Without network overrides, selection prefers the default VPC, then a subnet with public-IP mapping; fallback is the first available VPC/subnet. **This is selection, not validation of internet routing.** Check the selected subnet's internet gateway, DNS, NACLs, and CIDR overlap before use. Supplying only `SUBNET_ID` derives its VPC. Supplying `VPC_ID` restricts subnet selection to that VPC.

`CPU_CREDITS=standard` prevents surplus-credit billing, but a new `t3.medium` may have no credits: bootstrap load can cause EIC's guest key-verification helper to exceed its five-second timeout (`Permission denied (publickey)`, guest journal status `124`). `CPU_CREDITS=unlimited` explicitly allows paid bursting; it does not disable SSH/signature verification.

Direct SSH uses `SSH_MODE=direct`: it injects the local public key through cloud-init, permits TCP/22 from `WORKSTATION_CIDR` (or the detected workstation public IP `/32`), and connects to each current public IP. Keep `SSH_MODE` and key directory consistent across actions. Direct SSH live testing is deferred to a workstation with supported outbound SSH access.

Baseline snapshots carry `Pair=<master-instance-id>-<worker-instance-id>`; reset refuses snapshots from another pair. Snapshot completion is observed for up to one hour; replacement tasks for up to 30 minutes. Timeout does not cancel the AWS operation—inspect the printed IDs before retrying.

`reset` checks SSH/sudo access before replacement, restores both tagged baselines, deletes replaced roots, then unmasks services only after both tasks succeed. `cleanup` terminates tagged instances, deletes tagged snapshots/detached volumes, deletes owned tagged EIC endpoints, then removes owned node/endpoint security groups. An explicitly supplied **borrowed endpoint and its group remain untouched**; cleanup never deletes the VPC/subnet. Do not put the ownership tag on shared resources. After an interrupted/failed `init` or `reset`, inspect live resources/tasks before retrying; `init` is not a partial-bootstrap recovery command.

After both replacement tasks succeed, `reset` prints `AWS_ROOT_RESET_PASS` independently of guest checks. Service unmask/start and cluster-health commands retry SSH transport exit `255` for up to ten minutes; other remote errors stop immediately. Only these idempotent commands are retried—not root replacement, snapshot creation, or bootstrap. Health checks are sent anew for every connection. A recovery timeout requires inspecting the printed tasks and recovering services; do not rerun `reset` merely to retry SSH.

**Automation live evidence (2026-11-12, EIC only):** the corrected runner completed with exit `0` and `FULL_LIFECYCLE_PASS`, using `CPU_CREDITS=unlimited` and borrowed endpoint `eice-03af049301137e42a`. VPC/subnet auto-selection, unattended `init`, completed baseline snapshots, cluster/etcd checks, cached pods, offline tools, pause, and resume with preserved namespace/file markers passed. Replacement tasks `replacevol-09a33b29a0fa30c5d` / `replacevol-057add327a66f365d` both succeeded; the observed post-reset EIC transport failure was retried without repeating replacement. Both nodes recovered Ready with CoreDNS healthy; `MASTER_ROLLBACK_PASS`, `WORKER_ROLLBACK_PASS`, and `RESET_AND_DISPLACED_ROOT_DELETION_PASS` confirmed namespace/file rollback, absent control-plane taint, and displaced-root deletion.

Independent AWS queries confirmed both test instances terminated and zero test-tagged snapshots, volumes, security groups, or endpoints remained. Exact original roots, untagged replacement roots, and the deliberately created detached-volume cleanup fixture were also absent. The borrowed endpoint remained `create-complete`, unmodified; creating/deleting an owned EIC endpoint was not covered by this successful run because the VPC's endpoint quota was occupied. Direct SSH remains untested live. Evidence: `$HOME/.local/state/cks-domain0/live-eic-20261112-full.sh`, companion `live-eic-20261112-check.sh`, and session task `b2pis569l` output. Earlier failed runs remain failures, not retroactively accepted. Six older snapshots were separately deleted at the operator's request; historical baseline references below are not proof those snapshots still exist.

The detailed manual procedure below and `scripts/ec2-lab.py` retain their separate preview/confirmation and local-baseline workflow; their `cleanup` is termination-only, unlike `cks-lab.sh cleanup`.

## 1. Local preflight (read-only)

Run from this worktree. Commands below use Bash; Windows AWS CLI works from WSL:

```bash
if command -v aws >/dev/null; then AWS=aws; else AWS=aws.exe; fi
export AWS_REGION=ap-southeast-1
export AWS_PAGER=''
"$AWS" --version
"$AWS" sts get-caller-identity --region "$AWS_REGION"
"$AWS" ec2 describe-vpcs --region "$AWS_REGION" --output table
"$AWS" ec2 describe-subnets --region "$AWS_REGION" --output table
```

Select an **existing public subnet** with internet gateway routing, working VPC DNS, and adequate NACL rules. Both instances use that subnet. Do not create a NAT Gateway. Kubernetes networks `192.168.0.0/16` (pods) and `10.96.0.0/12` (services) must not overlap the VPC or connected networks.

```bash
export VPC_ID=
export SUBNET_ID=
"$AWS" ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{Vpc:VpcId,Subnet:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' --output table
"$AWS" ec2 describe-route-tables --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" --output table

AMI=$("$AWS" ec2 describe-images --region "$AWS_REGION" --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*' \
    'Name=architecture,Values=x86_64' 'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text | tr -d '\r')
test -n "$AMI" && test "$AMI" != None
"$AWS" ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI" \
  --query 'Images[].{ID:ImageId,Name:Name,Owner:OwnerId,Root:RootDeviceName}' --output table
ROOT_DEVICE=$("$AWS" ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI" \
  --query 'Images[0].RootDeviceName' --output text | tr -d '\r')

EIC_PREFIX=$("$AWS" ec2 describe-managed-prefix-lists --region "$AWS_REGION" \
  --filters "Name=prefix-list-name,Values=com.amazonaws.$AWS_REGION.ec2-instance-connect" \
  --query 'PrefixLists[0].PrefixListId' --output text | tr -d '\r')
test -n "$EIC_PREFIX" && test "$EIC_PREFIX" != None
```

Stop if any lookup fails or yields `None`; do not substitute an unverified AMI. The operator needs EC2/EBS management permissions plus `ec2-instance-connect:SendSSHPublicKey` and `ec2-instance-connect:OpenTunnel` for terminal access (section 2a). Nodes need **no** instance profile. The workstation needs outbound HTTPS/WebSocket connectivity to AWS. The regional prefix-list SSH rule below is optional browser fallback, not required by private endpoint access.

## 2. Create only the lab security group and two instances

**Approval boundary:** the following commands create billable resources or change AWS state. Confirm the selected account/region and costs first.

Recommended starting size: **2 × `t3.medium`**, each 2 vCPU / 4 GiB RAM, one **30 GiB encrypted gp3 root disk**. Not a free-tier claim. Run heavier tools sequentially. `t3` in standard credit mode limits surplus-credit charges but can throttle after sustained CPU use.

```bash
SG=$("$AWS" ec2 create-security-group --region "$AWS_REGION" --vpc-id "$VPC_ID" \
  --group-name cks-domain0 --description 'Disposable two-node security lab' \
  --query GroupId --output text | tr -d '\r')

# Trust only members of this dedicated group for Kubernetes/Calico traffic.
"$AWS" ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG" \
  --ip-permissions "[{\"IpProtocol\":\"-1\",\"UserIdGroupPairs\":[{\"GroupId\":\"$SG\"}]}]"
# Public SSH only from AWS's regional browser-connect service, never 0.0.0.0/0.
"$AWS" ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"PrefixListIds\":[{\"PrefixListId\":\"$EIC_PREFIX\"}]}]"
```

Keep the new group's default outbound access for apt/image downloads. Do not attach this group to anything else. No public 6443, kubelet, NodePort or etcd rules. The adapter forces **VXLAN** even within one subnet, avoiding custom VPC pod routes/source-destination-check changes.

```bash
DISK="[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":30,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]"

MASTER=$("$AWS" ec2 run-instances --region "$AWS_REGION" --image-id "$AMI" \
  --instance-type t3.medium --count 1 --subnet-id "$SUBNET_ID" --security-group-ids "$SG" \
  --associate-public-ip-address --credit-specification CpuCredits=standard \
  --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
  --block-device-mappings "$DISK" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cks-master},{Key=Purpose,Value=cks-domain0}]' \
  --user-data $'#!/bin/bash\nset -eu\nhostnamectl set-hostname cks-master\napt-get update -qq\napt-get install -y ec2-instance-connect\n' \
  --query 'Instances[0].InstanceId' --output text | tr -d '\r')

WORKER=$("$AWS" ec2 run-instances --region "$AWS_REGION" --image-id "$AMI" \
  --instance-type t3.medium --count 1 --subnet-id "$SUBNET_ID" --security-group-ids "$SG" \
  --associate-public-ip-address --credit-specification CpuCredits=standard \
  --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
  --block-device-mappings "$DISK" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cks-worker},{Key=Purpose,Value=cks-domain0}]' \
  --user-data $'#!/bin/bash\nset -eu\nhostnamectl set-hostname cks-worker\napt-get update -qq\napt-get install -y ec2-instance-connect\n' \
  --query 'Instances[0].InstanceId' --output text | tr -d '\r')

"$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
"$AWS" ec2 describe-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Private:PrivateIpAddress,Public:PublicIpAddress,State:State.Name,Name:Tags[?Key==`Name`]|[0].Value}' --output table
```

If a launch response is lost, inspect instances by the `Purpose=cks-domain0` tag before retrying. Do not blindly launch duplicates. Save `$MASTER`, `$WORKER`, `$SG`, `$SUBNET_ID`, and region **outside Git**. Public IPv4 can change after ordinary stop/start; private IP and node hostname persist. Use console instance IDs, not bookmarked public IPs.

## 2a. Terminal access: private EIC tunnel + SSH

This is the live-tested access method. No public port 22 rule for your workstation, bastion, SSM agent, instance IAM role, or permanent entry in `authorized_keys` is required. The workstation needs AWS CLI v2, OpenSSH, valid AWS credentials and outbound HTTPS/WebSocket access. Instances must be running with `sshd` and `ec2-instance-connect` installed.

The operator needs `ec2:DescribeInstances`, `ec2:DescribeInstanceConnectEndpoints`, `ec2-instance-connect:SendSSHPublicKey` for the two instances/user `ubuntu`, and `ec2-instance-connect:OpenTunnel` for the endpoint/remote port 22. Start/stop and snapshot permissions are separate. Do not copy AWS credentials onto the nodes.

For the existing lab, set these in the local terminal; identifiers are not credentials:

```bash
if command -v aws >/dev/null; then AWS=aws; else AWS=aws.exe; fi
export AWS_REGION=ap-southeast-1 AWS_PAGER=''
MASTER=i-0fbfa4d0779b56321
WORKER=i-0b3cd0d36a8e184c0
EIC_ENDPOINT=eice-03af049301137e42a

"$AWS" sts get-caller-identity --region "$AWS_REGION"
"$AWS" ec2 describe-instance-connect-endpoints --region "$AWS_REGION" \
  --instance-connect-endpoint-ids "$EIC_ENDPOINT" --output table
# Start only when needed; compute/IPv4 charges resume.
"$AWS" ec2 start-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
"$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
```

Existing endpoint: security group `sg-0a047138e74cef63d`, client-IP preservation **disabled**. Node security group `sg-06cf3942ae550b8e5` permits TCP 22 from that endpoint group. Endpoint egress must reach node TCP 22; subnet routing/NACLs must allow the connection and return traffic. Public IPs are not used for SSH; this lab still uses public addressing for package/image downloads.

For a newly created lab without an endpoint, create a dedicated endpoint group in the same VPC, allow its egress to node TCP 22, allow node ingress TCP 22 **from that group**, then create an endpoint with `aws ec2 create-instance-connect-endpoint --subnet-id "$SUBNET_ID" --security-group-ids "$EIC_SG" --no-preserve-client-ip`. These are separately approved AWS mutations. Wait for `create-complete` using `describe-instance-connect-endpoints`; do not create a duplicate endpoint when one already exists.

Generate a workstation-only key once, outside the repository:

```bash
ACCESS="$HOME/.local/state/cks-domain0/access"
install -d -m 700 "$ACCESS"
if [ ! -e "$ACCESS/id_rsa" ]; then
  ssh-keygen -q -t rsa -b 3072 -N '' -C disposable-lab-access -f "$ACCESS/id_rsa"
fi
```

The key is unencrypted for automated lab commands: protect this directory, never commit/copy the private key, and use it only for these disposable nodes. The public key is sent through EIC before **each new SSH/SCP connection**; EIC makes it available for authentication for 60 seconds. An established session can last longer, up to its tunnel limit.

Define these functions in each local Bash/WSL terminal:

```bash
set -o pipefail
eic_key() {
  local instance="$1" az result
  az=$("$AWS" ec2 describe-instances --region "$AWS_REGION" --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text | tr -d '\r') || return
  [ -n "$az" ] && [ "$az" != None ] || return 1
  # Pass key contents, not file://: aws.exe cannot directly open a WSL /home path.
  result=$("$AWS" ec2-instance-connect send-ssh-public-key --region "$AWS_REGION" \
    --instance-id "$instance" --availability-zone "$az" --instance-os-user ubuntu \
    --ssh-public-key "$(<"$ACCESS/id_rsa.pub")" --query Success --output text | tr -d '\r') || return
  [ "$result" = True ]
}

lab_ssh() {
  local instance="$1"; shift
  eic_key "$instance" || return
  ssh -i "$ACCESS/id_rsa" -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$ACCESS/known_hosts" \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
    -o "ProxyCommand=\"$AWS\" ec2-instance-connect open-tunnel --region $AWS_REGION --instance-id %h --instance-connect-endpoint-id $EIC_ENDPOINT --remote-port 22 --max-tunnel-duration 3600" \
    "ubuntu@$instance" "$@"
}

lab_scp() {
  local instance="$1" source="$2" destination="$3"
  eic_key "$instance" || return
  scp -i "$ACCESS/id_rsa" -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$ACCESS/known_hosts" \
    -o "ProxyCommand=\"$AWS\" ec2-instance-connect open-tunnel --region $AWS_REGION --instance-id %h --instance-connect-endpoint-id $EIC_ENDPOINT --remote-port 22 --max-tunnel-duration 3600" \
    "$source" "ubuntu@$instance:$destination"
}

lab_ssh "$MASTER"                         # interactive shell; sudo -i for root
lab_ssh "$WORKER" 'hostname; sudo crictl ps'
lab_ssh "$MASTER" 'kubectl get nodes -o wide'
# Run a reviewed local script without copying it first:
# lab_ssh "$MASTER" 'sudo bash -s' < scripts/cks-tools.sh
# Copy a file:
# lab_scp "$MASTER" ./manifest.yaml /home/ubuntu/manifest.yaml
```

`ProxyCommand` runs the tunnel over SSH's standard input/output; **omit `--local-port`**. No separately managed background tunnel or localhost listener is needed. This is simpler than the earlier diagnostic local-port tunnel. Do not start a second copy of an existing diagnostic tunnel.

SSH uses trust-on-first-use (`accept-new`), then checks the stored host key. Verify the initial fingerprint through a trusted channel for stronger assurance. Root restore should retain the baseline host key. If SSH reports a changed key, inspect the instance/snapshot first; never solve it with `StrictHostKeyChecking=no` or automatic known-host deletion.

Failures: expired AWS credentials require local reauthentication; `Permission denied (publickey)` requires a fresh `eic_key` plus the correct OS user/EIC package; tunnel denial requires `OpenTunnel` permission; a timeout requires endpoint state/SG/NACL/sshd checks. Stopped instances cannot accept EIC SSH. No Kubernetes API exposure is needed.

## 3. Install once using the existing scripts

The existing scripts target Ubuntu 22.04 and require Docker-repository containerd 1.7. Ubuntu 26.04's repository does not provide that series. `scripts/node-setup.sh` sources the originals, overrides runtime installation with Ubuntu's **containerd 2.x**, enables **systemd cgroups**, installs **Calico v3.33.0 with VXLAN**, and removes only the kubeadm control-plane `NoSchedule` taint on master. Other bootstrap functions remain unchanged; original defaults use Kubernetes **1.35**. Live EC2 bootstrap/network/reset testing passed with Kubernetes v1.35.10 and containerd 2.2.2; offline unit tests alone do not establish distro compatibility. If the regional Ubuntu apt mirror returns HTTP 503, inspect `/etc/apt/sources.list.d/ubuntu.sources`, switch its archive URI to the official `http://archive.ubuntu.com/ubuntu/`, then retry apt. This workaround was needed during the live run.

Calico operator CRDs are asynchronous: a CRD may exist before `.status.conditions`. The adapter retries the `Established` wait within a bounded deadline, including immediate `kubectl wait` accessor errors; it never applies custom resources just because the CRD exists. This race was reproduced during the 2026-11-11 live run and now has regression coverage.

On each node via `lab_ssh "$MASTER"` / `lab_ssh "$WORKER"`, first wait for cloud-init and confirm hostname:

```bash
sudo cloud-init status --wait
hostname
```

Use reviewed local copies of `master-startup.sh`, `worker-startup.sh`, and `node-setup.sh`. No `git clone` with access tokens, no `cka-sim bootstrap`. For **new uninitialized nodes only**, transfer them from the local terminal using section 2a:

```bash
SOURCE=/home/thienpv/projects/external/gitlab-com/cka-packs/cka-sim/scripts/setup
for node in "$MASTER" "$WORKER"; do
  lab_ssh "$node" 'umask 077; mkdir -p /home/ubuntu/setup-lab'
  for file in "$SOURCE/master-startup.sh" "$SOURCE/worker-startup.sh" scripts/node-setup.sh; do
    lab_scp "$node" "$file" /home/ubuntu/setup-lab/
  done
done
lab_ssh "$MASTER" 'sudo bash /home/ubuntu/setup-lab/node-setup.sh master /home/ubuntu/setup-lab'
```

Get the join command from master without logging it, then join worker through its private tunnel. Do not enable shell tracing (`set -x`) around join credentials:

```bash
KUBE_JOIN_COMMAND=$(lab_ssh "$MASTER" 'sudo cat /var/log/kubeadm-join-command.txt')
[[ "$KUBE_JOIN_COMMAND" == 'kubeadm join '* ]] || { unset KUBE_JOIN_COMMAND; return 1; }
printf -v JOIN_ARG '%q' "$KUBE_JOIN_COMMAND"
lab_ssh "$WORKER" "sudo env KUBE_JOIN_COMMAND=$JOIN_ARG bash /home/ubuntu/setup-lab/node-setup.sh worker /home/ubuntu/setup-lab"
unset KUBE_JOIN_COMMAND JOIN_ARG
```

Token expired: generate a new one on master using `sudo kubeadm token create --print-join-command`. Never commit tokens/logs containing credentials. Inspect `/var/log/k8s-master-startup.log`, `/var/log/kubeadm-init.log`, or `/var/log/k8s-worker-startup.log` after a failure; do not rerun a partly initialized node blindly. Original guards detect config files, not cluster health.

## 4. Verify before freezing baseline

Master:

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide                    # exactly cks-master and cks-worker
kubectl get pods -A                          # Calico/CoreDNS healthy
kubectl version
kubeadm version -o short
kubectl -n kube-system rollout status deployment/coredns --timeout=180s
```

Both node SSH sessions:

```bash
sudo -i
crictl info
crictl ps -a
systemctl is-active containerd kubelet
containerd --version
stat -fc %T /sys/fs/cgroup                   # cgroup2fs
sudo aa-status                             # AppArmor enabled/profiles loaded
sudo journalctl -u kubelet -n 50 --no-pager
# Master: /etc/kubernetes/manifests/kube-apiserver.yaml
# Both:  /var/lib/kubelet/config.yaml
exit
```

Verify real cross-node pod traffic, DNS, and NetworkPolicy enforcement before trusting the CNI. Remove the master scheduling taint as section 5 describes first. The client uses a node selector, no control-plane toleration or `nodeName`: readiness proves normal scheduler placement on master.

```bash
kubectl create namespace baseline-check
kubectl -n baseline-check run server --image=nginx:alpine --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cks-worker"}}}'
kubectl -n baseline-check run client --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cks-master"}}}' \
  --command -- sleep 3600
kubectl -n baseline-check wait --for=condition=Ready pod --all --timeout=180s
POD_IP=$(kubectl -n baseline-check get pod server -o jsonpath='{.status.podIP}')
kubectl -n baseline-check exec client -- nslookup kubernetes.default.svc.cluster.local
kubectl -n baseline-check exec client -- wget -T 3 -qO- "http://$POD_IP"  # succeeds
kubectl -n baseline-check create -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-server
spec:
  podSelector:
    matchLabels:
      run: server
  policyTypes: [Ingress]
YAML
# Allow policy convergence, then repeat until wget times out; success is NOT a pass.
kubectl -n baseline-check exec client -- wget -T 3 -qO- "http://$POD_IP"
kubectl delete namespace baseline-check --wait=true
```

Record the successful first request and denied second request. Pin/cache desired lab images before the final snapshot. These two images are smoke-test examples, not a reproducible supply-chain baseline.

### 4a. Install the CKS toolbox, then prove offline use

Verified release pins:

| Tool | Version |
|---|---|
| etcdctl / etcdutl | 3.6.6 (matches etcd image 3.6.6-0) |
| kube-bench | 0.16.0 |
| Trivy | 0.76.2 |
| Cosign | 2.6.3 (detached-key workflow) |
| Kubesec | 2.15.0 |
| kube-linter | 0.8.3 |
| Helm | 3.19.0 |
| Mike Farah yq | 4.54.3 |
| jq | 1.8.1; Ubuntu package 1.8.1-4ubuntu2 |
| Falco / Kyverno charts | 9.2.2 / 3.9.2; cached, not deployed |

SHA256 pins are in `scripts/cks-tools.sh`; installed evidence is `/opt/cks/versions.txt` and `/opt/cks/releases.sha256`. The live Trivy DB was updated `2026-11-10T06:59:14Z` and downloaded `2026-11-10T09:08:51Z`; that timestamp is evidence, not a promise of future freshness.

Cluster bootstrap and tool preparation are separate commands; **both** are required for the final Domain 0 baseline. Do not rerun kubeadm on the existing cluster. From the workstation, using section 2a:

```bash
# Runtime/AppArmor/crictl already installed by node bootstrap on both nodes.
# Cache the same smoke image on the worker; no toolbox/controller deployment there.
lab_ssh "$WORKER" 'sudo ctr -n k8s.io images pull --platform linux/amd64 docker.io/library/busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'
lab_ssh "$MASTER" 'sudo bash -s' < scripts/cks-tools.sh
lab_ssh "$MASTER" 'sudo bash -s' < scripts/check-cks-tools.sh
```

`cks-tools.sh` installs pinned Linux amd64 release assets on master after SHA256 verification, including `etcdctl`/`etcdutl` matching the bundled etcd. It also caches the Trivy vulnerability DB, an Alpine image archive, and Falco/Kyverno chart archives under `/opt/cks`. `kubectl`, `crictl`, containerd, AppArmor and node prerequisites already exist on both nodes from bootstrap. `jq` comes from Ubuntu apt; record its resolved package version. Downloads require internet during preparation, not during the offline acceptance checks. Kubesec uses eight cached Kubernetes v1.35.10 strict workload schemas (Pod, Deployment, DaemonSet, StatefulSet, ReplicaSet, Job, CronJob, ReplicationController); login shells load `SCHEMA_LOCATION` from `/etc/profile.d/cks-tools.sh`. For a non-login shell, run `source /etc/profile.d/cks-tools.sh` or pass `--schema-location '/opt/cks/schemas/{{.ResourceKind}}{{.KindSuffix}}.json'`. Unsupported resource kinds need their matching schema cached first; do not bypass validation.

Falco/Kyverno **are not deployed** into the baseline. Their cached charts can be rendered offline; this does not mean every controller image or dependency needed by later drills is cached. Cache those drill-specific images before disconnecting the lab. No admission policies, runtime agents, real signing keys, or production credentials are introduced here.

`check-cks-tools.sh` verifies live nodes/CoreDNS/CRI/etcd health, then runs tool checks inside `unshare --net`: a new network namespace with no external route. It exercises local kubectl generation, YAML/JSON parsing, chart rendering, insecure-manifest detection, a Trivy image-archive scan with DB updates disabled, kube-bench JSON output (expected CIS failures are not remediated), and Cosign local blob sign/verify **plus rejection of a tampered blob**. Local Cosign checks intentionally omit transparency-log publication/lookup; cryptographic signature verification remains enabled. This is not acceptance of offline keyless image verification.

Capture tool versions, release hashes, DB age and acceptance output outside the VMs before snapshotting. The cache is point-in-time: refresh Trivy data and repin tools deliberately when needed, then create a **new** baseline filename. Never overwrite the older cluster-only baseline.

## 5. Snapshot the clean baseline once

**Required invariants:**

- Control-plane `node-role.kubernetes.io/control-plane:NoSchedule` taint is removed. Master resources are intentionally schedulable for this two-node lab.
- kubelet and containerd are **persistently masked and stopped on both nodes**. After any restore, they cannot start against a mixed-generation cluster before both roots finish restoration.
- Snapshot metadata records `control_plane_schedulable: true`; reset refuses older tainted/unknown baselines.

Before masking services, remove the taint idempotently and inspect remaining taints. This also works on an already initialized cluster without rerunning kubeadm:

```bash
lab_ssh "$MASTER" 'sudo bash -c "source /dev/stdin; untaint_master"' < scripts/node-setup.sh
lab_ssh "$MASTER" 'kubectl get node cks-master -o jsonpath="{.spec.taints}"; printf "\\n"'
```

For this disposable lab, allowing workloads on master trades control-plane isolation for capacity. Use resource requests/limits so drills do not starve etcd or the API server. Never remove pressure/unreachable or unrelated security taints to force scheduling.

The snapshot command requires `--taint-free` as an explicit operator assertion, not an AWS verification. Verify the control-plane `NoSchedule` taint is absent **before** stopping services; the script cannot query Kubernetes through AWS APIs. Taints live in etcd, so a correctly captured pair restores the untainted state too. Existing snapshots are immutable: do not add the metadata flag to an old tainted baseline; capture a new pair instead.

On **each node through SSH**, save lab notes off-node, then:

```bash
sudo systemctl mask kubelet.service containerd.service
sudo systemctl stop kubelet.service containerd.service
systemctl is-enabled kubelet.service containerd.service   # masked, masked
systemctl is-active kubelet.service containerd.service    # inactive, inactive; nonzero is expected
sudo sync
```

Stopping containerd alone does not guarantee all shim/container processes stop. Stop **both EC2 instances** before taking any disk snapshots. This ensures no node can keep writing during baseline capture.

Local terminal (AWS mutations, only after approval):

```bash
"$AWS" ec2 stop-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
"$AWS" ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"

# Local state stays outside the repository; do not commit cloud identifiers.
install -d -m 700 "$HOME/.local/state/cks-domain0"
BASELINE="$HOME/.local/state/cks-domain0/baseline-tools.json"  # new pair; retain cluster-only baseline
python3 scripts/ec2-lab.py snapshot --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION" --baseline "$BASELINE"            # read-only preview
python3 scripts/ec2-lab.py snapshot --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION" --baseline "$BASELINE" --taint-free --apply  # confirm IDs + untainted/masked state
```

Keep the old cluster-only baseline pair intact. Both snapshots must reach `completed`. The baseline records account, region, roles, IDs, source root volumes and snapshot IDs. Existing baseline files are never overwritten. Keep an off-machine backup of this metadata and protect the underlying snapshots. Creation is sequential, but both disks are stopped, so neither can change between captures.

After successful baseline capture:

```bash
"$AWS" ec2 start-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
"$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
```

Reconnect **both** nodes using `lab_ssh`. Only after both nodes are back:

```bash
sudo systemctl unmask containerd.service kubelet.service
sudo systemctl enable --now containerd.service kubelet.service
```

EC2 status checks and active systemd services do not prove the API server is listening. After unmasking services on **both** nodes (also after reset), wait on master before creating any lab resources:

```bash
lab_ssh "$MASTER" 'bash -s' <<'READY'
set -euo pipefail
deadline=$((SECONDS + 600))
until kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    sudo crictl ps -a
    sudo journalctl -u kubelet -n 80 --no-pager
    exit 1
  fi
  sleep 3
done
kubectl wait --for=condition=Ready nodes --all --timeout=600s
test "$(kubectl get nodes -o name | wc -l)" -eq 2
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
READY
```

No bootstrap script reruns. A connection-refused response immediately after boot is not a failed restore; bounded readiness timeout is a failure requiring diagnosis.

## 6. Reset after every lab

**Destructive operation:** save wanted work outside the nodes first. Reset restores **both entire root disks**, including etcd, Kubernetes config, packages, policies and local images, to the same baseline. Extra disks are rejected, not restored. AWS security group/IAM/network configuration is outside the snapshots.

If instances are stopped, start both and wait for `instance-status-ok` first. Root replacement requires **running** EBS-backed instances, even if the guest Kubernetes services are broken. Do not use `kubeadm reset`.

```bash
python3 scripts/ec2-lab.py reset --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION" --baseline "$BASELINE"          # read-only preflight
python3 scripts/ec2-lab.py reset --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION" --baseline "$BASELINE" --apply  # type both IDs to confirm loss
```

The wrapper uses `create-replace-root-volume-task` for each node, retaining displaced disks. EC2 reboots the instances; instance IDs, private IPs and network interfaces remain. Repeated restoration from original root snapshots is supported. Snapshots must come **directly from that instance's current or previous root**, not copied snapshots.

**Wait for BOTH replacement tasks to succeed before unmasking anything.** Reconnect through `lab_ssh` (each connection sends a fresh EIC public key), unmask/start services using section 5, then verify two Ready nodes, CoreDNS, and absence of lab namespaces/files. Root-volume task success is not a Kubernetes health check. Do not change the snapshot's masked-service invariant.

Failure/timeout/interrupt: leave services masked on any restored node. Inspect the printed `baseline.json.reset-*.json` journal and AWS replacement history. An in-flight task may continue after the local command exits. Never blindly rerun; a second-node failure can leave one restored root and one dirty root.

```bash
"$AWS" ec2 describe-replace-root-volume-tasks --region "$AWS_REGION" \
  --filters "Name=instance-id,Values=$MASTER,$WORKER" --output table
# Snapshot response lost? Find its unique request_description from baseline.json:
"$AWS" ec2 describe-snapshots --region "$AWS_REGION" --owner-ids self \
  --filters 'Name=description,Values=lab-baseline-REPLACE' --output table
```

No automatic recovery/deletion. For partial reset, complete the missing node's replacement using its recorded command and client token **only after checking AWS state**; wait for both tasks, then unmask. For partial snapshot, inspect recorded snapshot IDs/descriptions; do not invent a missing ID or overwrite the baseline. Keep the incomplete record; use a new baseline filename after resolving orphaned operations. Snapshots/certificates age: check certificate expiry before relying on a months-old baseline.

### Prove reset actually works (once, before destructive drills)

After obtaining approval for a reset test, create a marker namespace on master and a marker file on **each** node:

```bash
kubectl create namespace reset-proof       # master only
sudo touch /var/tmp/reset-proof            # both node SSH sessions
```

Perform section 6. After both roots succeed and services recover:

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get namespace reset-proof          # NotFound is expected
sudo test ! -e /var/tmp/reset-proof        # both node SSH sessions; exit 0
kubectl get nodes -o wide                  # same node names/private IPs; exactly two Ready
kubectl -n kube-system rollout status deployment/coredns --timeout=180s
```

**Bài 0.1 passes only after this actual restore drill succeeds.** The cluster-only baseline passed this live drill. Keep that evidence separate from acceptance of a newer tools baseline and from personal timed-drill completion.

## 7. Satisfied / acceptance evidence

Only mark checks satisfied after observing their output. These checks distinguish infrastructure acceptance from completion of personal timed drills.

**Historical evidence (2026-11-10):** both EC2 instances were stopped with kubelet/containerd masked before capture. Master snapshot `snap-096b8e0940ce250af` and worker snapshot `snap-0c1c36fc59fd7525d` completed. Those snapshots predate the taint-free requirement; their contents have not changed.

**Live testing (2026-11-11):** on `i-06919be093f214b98` (`cks-master`) and `i-00efef5dacd8eb196` (`cks-worker`), bootstrap, offline tools (`CLUSTER_AND_ETCD_PASS`, `CACHED_PODS_PASS`, `OFFLINE_TOOLS_PASS`), and normal scheduler placement on `cks-master` (`MASTER_SCHEDULING_PASS`) succeeded. Taint-free snapshots `snap-0399fcb9f06df16e5` (master) and `snap-00c0b8e399fe579fd` (worker) completed (`$HOME/.local/state/cks-domain0/live-20261111-run5/baseline-tools-taintfree.json`). After adding post-snapshot mutations (`restore-proof` namespace, `/var/tmp/restore-proof` on both nodes, and re-applying `node-role.kubernetes.io/control-plane:NoSchedule` to `cks-master`), `ec2-lab.py reset --apply` replaced both root volumes (`vol-08c52ec4ab88629cd`, `vol-0f58538e9df141c0a` retained), waited for `instance-status-ok`, recovered both Ready nodes + CoreDNS, and confirmed rollback of `restore-proof` (`NAMESPACE_ROLLBACK_PASS`), `/var/tmp/restore-proof`, and the control-plane `NoSchedule` taint (`jq` taint-absence check returned `true`). Finally, `ec2-lab.py cleanup --apply` terminated both instances and `sg-0dfbf1ad30eb787bc` was deleted.

The latest baseline metadata and logs are stored outside the repository under `$HOME/.local/state/cks-domain0/live-20261111-run5/baseline-tools-taintfree.json` (plus earlier `.superpowers/sdd/2026-11-10-domain0-aws-ec2/live/baseline-tools.json`). To copy a baseline into the standard path in section 5 without overwriting an existing file:

```bash
install -d -m 700 "$HOME/.local/state/cks-domain0"
# Refuse to overwrite an existing record; inspect it first if this fails.
( set -o noclobber; umask 077
  cat "$HOME/.local/state/cks-domain0/live-20261111-run5/baseline-tools-taintfree.json" \
    > "$HOME/.local/state/cks-domain0/baseline-tools.json"
)
BASELINE="$HOME/.local/state/cks-domain0/baseline-tools.json"
```

Observed terminal evidence: SSH command `hostname; sudo -n true; echo STDIO_TUNNEL_PASS` returned `cks-master` / `STDIO_TUNNEL_PASS`; SCP copied `check-cks-tools.sh` to master and a remote file check returned `SCP_TUNNEL_PASS`. Acceptance returned `CLUSTER_AND_ETCD_PASS`, `CACHED_PODS_PASS`, `OFFLINE_TOOLS_PASS`, `MASTER_SCHEDULING_PASS`, and `NAMESPACE_ROLLBACK_PASS`; all `Purpose=cks-domain0` test instances reached `terminated`.

- [x] Exactly two kubeadm EC2 nodes; Ubuntu 26.04 amd64; no node IAM role.
- [x] Kubernetes v1.35.10, containerd 2.2.2; both nodes Ready; CoreDNS healthy.
- [x] Calico cross-node DNS/HTTP and NetworkPolicy deny/re-allow tested.
- [x] AppArmor enabled; cgroup2 confirmed on both nodes.
- [x] Private endpoint SSH on both nodes, `sudo`, `crictl`; SCP transfer verified.
- [x] SSH `ProxyCommand` without a background tunnel verified; no console required.
- [x] Earlier cluster-only root snapshot/restore test removed namespace/file markers and recovered both nodes.
- [x] Pinned CKS toolbox installed and release hashes recorded.
- [x] Offline tools acceptance returns `OFFLINE_TOOLS_PASS` in a network namespace without external routes.
- [x] New **taint-free** tool-complete snapshot pair reaches `completed`; older tainted baseline retained.
- [x] Final EC2 termination confirmed after toolbox acceptance and snapshots.
- [x] Restore acceptance of the **new** taint-free tools baseline (separate destructive drill; not inferred from the earlier pair).
- [ ] Personal kubectl speed drill / exam-version comparison completed by the learner.

`--version`, an AWS root-task success, Helm rendering, or expected CIS failures are not substitutes for their respective behavioral checks. Cached Falco/Kyverno charts are not installed controllers; later drills may need additional cached images. Do not mark the whole Domain 0 learning gate complete based only on automation.

## 8. Cost and cleanup

- Running compute, public IPv4, provisioned EBS and snapshots incur charges. After the live test, terminate both lab instances; EBS snapshots and retained displaced volumes still incur charges until separately removed. No hard cost estimate without checking regional pricing/account terms.
- Termination is explicit and tag-guarded. Preview first, then confirm both exact IDs:

```bash
python3 scripts/ec2-lab.py cleanup --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION"                 # read-only preview
python3 scripts/ec2-lab.py cleanup --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION" --apply         # permanent termination
```

The cleanup command requires both instances to carry `Purpose=cks-domain0`, refuses unrelated instances, terminates only those two IDs, waits for `terminated`, and never deletes snapshots/volumes/security groups/endpoint. It is idempotent after both are already terminated. The saved lab currently has no nonterminated `Purpose=cks-domain0` instances; verify with `describe-instances` before cleanup. The prior live instances were already terminated; this command is the enforced path for future live runs.

**Live-test teardown is not a lab reset.** Export evidence and complete the approved restore acceptance before termination. Use a shell `EXIT` trap in any live-test runner so failure still triggers cleanup of its explicitly recorded pair; interrupted cleanup must be reconciled by instance ID. Never enumerate and terminate every instance in the account.

**Termination ends the existing reset workflow.** `create-replace-root-volume-task` requires the original surviving instance; retained snapshots alone do not make a new two-node kubeadm cluster reusable. Recreating from them requires a separate recovery procedure for private IPs, etcd membership and certificates. No AMI/recreation automation is included. Keep the pair (stopped between study sessions) only when explicitly running a persistent study lab, not after a live test.

- Each reset deliberately retains two displaced roots for recovery. After cluster verification, inspect the journal's exact volume IDs and confirm they are detached (`available`) before deleting **only those** volumes. Repeated resets without cleanup accumulate charges.
- Example after reviewing one exact ID: `"$AWS" ec2 delete-volume --region "$AWS_REGION" --volume-id vol-REPLACE`. This permanently removes that disk. Never delete the current root or baseline snapshots.
- Final teardown is separate approval: terminate only the two lab instances, then inspect/delete retained disks, baseline snapshots and the dedicated security group. Do not delete shared VPC/subnet resources.
- No real secrets, personal workloads, cloud credentials or corporate connectivity on these intentionally vulnerable VMs. IMDSv2/hop-limit restrictions are defense in depth, not a substitute for keeping IAM roles off the nodes. A metadata timeout alone does not prove NetworkPolicy enforcement.

## Local checks

```bash
python3 -I -B -m unittest discover -s tests -p 'check_*.py'
bash -n scripts/node-setup.sh scripts/cks-tools.sh scripts/check-cks-tools.sh
git diff --check
```

## Official references

- [Ubuntu AWS AMI discovery](https://ubuntu.com/aws/docs/aws-how-to/instances/find-ubuntu-images/)
- [Ubuntu 26.04 containerd package](https://packages.ubuntu.com/resolute/containerd)
- [Kubernetes container runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Calico requirements](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements)
- [EC2 Instance Connect prerequisites](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-connect-prerequisites.html)
- [EC2 root-volume replacement](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/replace-root.html)

# Domain 0: two-node EC2 lab

One-time installation; one clean snapshot pair; restore both roots after each lab.
**Ubuntu 26.04 amd64, one control-plane, one worker.** No EKS, HA, simulator bootstrap, node IAM role, or AWS credentials inside the lab. Connect to **both nodes through EC2 Console → Connect → EC2 Instance Connect**, username `ubuntu`.

Cloud changes incur charges; review the account, region, instance IDs and costs before running them. Snapshot/reset erases lab changes when restored. Use a dedicated, disposable environment—never a shared or production cluster.

**Live test status (2026-11-10):** two Ubuntu 26.04 EC2 nodes were created and passed EC2 status checks. Private EC2 Instance Connect Endpoint `eice-03af049301137e42a` enabled SSH through the AWS CLI tunnel. Reused bootstrap completed: Kubernetes v1.35.10, containerd 2.2.2, Calico VXLAN, two Ready nodes, CoreDNS, cross-node DNS/HTTP, NetworkPolicy deny/re-allow, cgroup2 and AppArmor. Both masked roots were snapshotted; both roots were restored from those snapshots. Namespace and node-file rollback markers disappeared; both nodes returned Ready and CoreDNS rolled out. Nodes are stopped; temporary terminal-IP ingress removed. Endpoint, baseline snapshots, displaced roots and dedicated security groups remain. Offline regression suite: 18 checks pass. Offline CKS tools (`etcdctl`, `kube-bench`, `trivy` DB, `cosign`, `kubesec`, `kube-linter`, `helm` charts, `yq`, `jq`) were not installed or accepted.

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
export VPC_ID=vpc-REPLACE
export SUBNET_ID=subnet-REPLACE
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

Stop if any lookup fails or yields `None`; do not substitute an unverified AMI. The operator needs EC2/EBS management permissions plus `ec2-instance-connect:SendSSHPublicKey` for console access. Nodes need **no** instance profile. Browser access requires outbound HTTPS/WebSocket connectivity to the regional EIC proxy.

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
  --query 'Reservations[].Instances[].{ID:InstanceId,Private:PrivateIpAddress,Public:PublicIpAddress,State:State.Name}' --output table
```

If a launch response is lost, inspect instances by the `Purpose=cks-domain0` tag before retrying. Do not blindly launch duplicates. Save `$MASTER`, `$WORKER`, `$SG`, `$SUBNET_ID`, and region **outside Git**. Public IPv4 can change after ordinary stop/start; private IP and node hostname persist. Use console instance IDs, not bookmarked public IPs.

## 3. Install once using the existing scripts

The existing scripts target Ubuntu 22.04 and require Docker-repository containerd 1.7. Ubuntu 26.04's repository does not provide that series. `scripts/node-setup.sh` sources the originals, overrides runtime installation with Ubuntu's **containerd 2.x**, enables **systemd cgroups**, and installs **Calico v3.33.0 with VXLAN**. Other bootstrap functions remain unchanged; original defaults use Kubernetes **1.35**. This combination still needs a real EC2 smoke test; offline tests do not establish distro compatibility.

On each console, first wait for cloud-init and confirm hostname:

```bash
sudo cloud-init status --wait
hostname
```

Use reviewed local copies of `master-startup.sh`, `worker-startup.sh`, and `node-setup.sh`. No `git clone` with access tokens, no `cka-sim bootstrap`. To transfer without SSH setup, the following **local** command prints pasteable base64 commands. Review the source files first, then paste the output into each node's console. It creates `/home/ubuntu/setup-lab` and writes these three files there.

```bash
SOURCE=/home/thienpv/projects/external/gitlab-com/cka-packs/cka-sim/scripts/setup
python3 -I - "$SOURCE" scripts/node-setup.sh <<'PY'
import base64, pathlib, sys
files = [pathlib.Path(sys.argv[1]) / name for name in ("master-startup.sh", "worker-startup.sh")]
files.append(pathlib.Path(sys.argv[2]))
print('( umask 077; mkdir -p /home/ubuntu/setup-lab')
for path in files:
    data = base64.b64encode(path.read_bytes()).decode()
    print(f"printf '%s' '{data}' | base64 -d > /home/ubuntu/setup-lab/{path.name}")
print(')')
PY
```

**Master console:**

```bash
sudo bash /home/ubuntu/setup-lab/node-setup.sh master /home/ubuntu/setup-lab
sudo cat /var/log/kubeadm-join-command.txt
```

**Worker console:** paste that full join command only into this private console:

```bash
read -r -s -p 'Paste full kubeadm join command: ' KUBE_JOIN_COMMAND; printf '\n'
sudo env KUBE_JOIN_COMMAND="$KUBE_JOIN_COMMAND" \
  bash /home/ubuntu/setup-lab/node-setup.sh worker /home/ubuntu/setup-lab
unset KUBE_JOIN_COMMAND
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

Both consoles:

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

Verify real cross-node pod traffic, DNS, and NetworkPolicy enforcement before trusting the CNI. On master, this temporary namespace deliberately allows a test pod onto the control-plane:

```bash
kubectl create namespace baseline-check
kubectl -n baseline-check run server --image=nginx:alpine --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cks-worker"}}}'
kubectl -n baseline-check run client --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cks-master"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}' \
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

**Domain 0.2 remains unchecked:** the cluster installer does not install all CKS tools. Before the final baseline, install/verify the tools in `ckschecklist.md`: `etcdctl` matching bundled etcd, `kube-bench`, `trivy` plus its DB/image cache, `cosign`, `kubesec`, `kube-linter`, `helm` plus downloaded Falco/Kyverno charts, `yq`, `jq`. Put host tools on master, node-specific prerequisites on both. Pin and verify releases using official instructions. Prefer cached manifests/charts over preinstalling admission policies/Falco; those change drill starting state.

Test actual offline operation, not just `--version`: Trivy scan with DB updates disabled and image cached; cosign local blob verification using throwaway keys, or image verification against a reachable lab-local registry with verification material available offline. Do not disable verification merely to claim offline success. Kubernetes `--version` alone also does not prove cached images/charts can be used. Capture installed versions and test output outside the VMs. An earlier cluster-only snapshot is possible, but it is **not** the finished Domain 0 baseline; use a new filename for the final snapshot pair.

## 5. Snapshot the clean baseline once

**Required invariant:** in the snapshot, kubelet and containerd are **persistently masked and stopped on both nodes**. After any restore, they cannot start against a mixed-generation cluster before both roots finish restoration. The script requires your confirmation; AWS APIs cannot verify guest systemd state.

On **each console**, save lab notes off-node, then:

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
BASELINE="$HOME/.local/state/cks-domain0/baseline.json"
python3 scripts/ec2-lab.py snapshot --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION" --baseline "$BASELINE"            # read-only preview
python3 scripts/ec2-lab.py snapshot --master "$MASTER" --worker "$WORKER" \
  --region "$AWS_REGION" --baseline "$BASELINE" --apply    # confirm IDs + masking
```

Both snapshots must reach `completed`. The baseline records account, region, roles, IDs, source root volumes and snapshot IDs. Existing baseline files are never overwritten. Keep an off-machine backup of this metadata and protect the underlying snapshots. Creation is sequential, but both disks are stopped, so neither can change between captures.

After successful baseline capture:

```bash
"$AWS" ec2 start-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
"$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
```

Reconnect **both** consoles. Only after both nodes are back:

```bash
sudo systemctl unmask containerd.service kubelet.service
sudo systemctl enable --now containerd.service kubelet.service
```

Repeat the two-Ready-node/CoreDNS checks. No bootstrap script reruns.

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

**Wait for BOTH replacement tasks to succeed before unmasking anything.** Reconnect consoles, unmask/start services using section 5, then verify two Ready nodes, CoreDNS, and absence of lab namespaces/files. Root-volume task success is not a Kubernetes health check. Do not change the snapshot's masked-service invariant.

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
sudo touch /var/tmp/reset-proof            # both consoles
```

Perform section 6. After both roots succeed and services recover:

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get namespace reset-proof          # NotFound is expected
sudo test ! -e /var/tmp/reset-proof        # both consoles; exit 0
kubectl get nodes -o wide                  # same node names/private IPs; exactly two Ready
kubectl -n kube-system rollout status deployment/coredns --timeout=180s
```

**Bài 0.1 passes only after this actual restore drill succeeds.** Keep Domain 0 tool/offline gates separate. Live launch passed; bootstrap and restore remain blocked as recorded at the top of this guide.

## 7. Cost and cleanup

- Running compute, public IPv4, provisioned EBS and snapshots incur charges. Stop both instances between sessions; EBS/snapshot charges continue. No hard cost estimate without checking regional pricing/account terms.
- Each reset deliberately retains two displaced roots for recovery. After cluster verification, inspect the journal's exact volume IDs and confirm they are detached (`available`) before deleting **only those** volumes. Repeated resets without cleanup accumulate charges.
- Example after reviewing one exact ID: `"$AWS" ec2 delete-volume --region "$AWS_REGION" --volume-id vol-REPLACE`. This permanently removes that disk. Never delete the current root or baseline snapshots.
- Final teardown is separate approval: terminate only the two lab instances, then inspect/delete retained disks, baseline snapshots and the dedicated security group. Do not delete shared VPC/subnet resources.
- No real secrets, personal workloads, cloud credentials or corporate connectivity on these intentionally vulnerable VMs. IMDSv2/hop-limit restrictions are defense in depth, not a substitute for keeping IAM roles off the nodes. A metadata timeout alone does not prove NetworkPolicy enforcement.

## Local checks

```bash
python3 -I tests/check_domain0.py
bash -n scripts/node-setup.sh
git diff --check
```

## Official references

- [Ubuntu AWS AMI discovery](https://ubuntu.com/aws/docs/aws-how-to/instances/find-ubuntu-images/)
- [Ubuntu 26.04 containerd package](https://packages.ubuntu.com/resolute/containerd)
- [Kubernetes container runtimes](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Calico requirements](https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements)
- [EC2 Instance Connect prerequisites](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-connect-prerequisites.html)
- [EC2 root-volume replacement](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/replace-root.html)

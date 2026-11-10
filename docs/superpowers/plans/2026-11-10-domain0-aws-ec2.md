# Domain 0 AWS EC2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare a reusable two-node Ubuntu 26.04 kubeadm lab on EC2, snapshot its clean baseline once, restore both nodes after each lab.

**Architecture:** Keep two persistent EC2 instances so their private IPs and Kubernetes identities survive resets. Reuse the existing master/worker scripts through a small Ubuntu 26.04 adapter; do not copy or edit the external repository. Use AWS's native root-volume replacement API rather than implement volume detach/attach orchestration.

**Tech Stack:** Bash, Python 3 standard library, AWS CLI v2 (`aws` or WSL-accessible `aws.exe`), EC2/EBS, kubeadm, containerd, Calico.

**Spec:** `ckschecklist.md`, Domain 0, plus the user's requirements: AWS EC2, one-time setup, snapshots before labs, reset after each lab, two nodes, AWS Console access, Ubuntu 26.04, isolated worktree. Implementation details below are proposed choices, not additional user requirements.

## Global Constraints

- Exactly one control-plane and one worker; no EKS, HA, load balancer, NAT Gateway, simulator bootstrap, or SSH-key distribution.
- Ubuntu 26.04 amd64; propose two `t3.medium` instances (2 vCPU / 4 GiB each), one encrypted 30 GiB gp3 root disk each. Confirm affordability before launch; no price claims.
- Existing VPC/public subnet and a dedicated lab security group. Allow all traffic only within that group; TCP 22 only from the regional EC2 Instance Connect service prefix list for browser access. Never expose Kubernetes API publicly. Browser EC2 Instance Connect is the proposed console method; no instance IAM role or stored AWS credentials.
- Reuse `/home/thienpv/projects/external/gitlab-com/cka-packs/cka-sim/scripts/setup/master-startup.sh` and `worker-startup.sh`. Supply both reviewed scripts alongside the adapter on each VM through console transfer/paste; no private repository credentials on nodes.
- Existing scripts pin Kubernetes 1.35 and download amd64 tools. Retain that minor for this setup; match the exam version separately before claiming full readiness.
- Existing scripts require containerd 1.7 from Docker's repository; that series is absent from the Ubuntu 26.04 repository. Override only runtime installation and Calico installation. Use Ubuntu's containerd 2.x package with systemd cgroups; pin Calico v3.33.0, which lists Kubernetes 1.35 as tested. Force VXLAN across nodes for AWS; leave the original scripts unchanged.
- Python wrapper prints planned mutations by default. Require explicit `--apply`; reset also requires an interactive confirmation naming both instance IDs and warning of data loss. No Terraform or new Python dependencies.
- AWS reads allowed. Do not launch, stop, snapshot, replace, delete, or modify cloud resources during implementation without separate approval for the concrete resources and expected effect.
- Do not commit implementation files without another request. Initial commit `5aef3c1` was separately authorized and completed.

## Review Focus

1. Ubuntu/runtime incompatibility: fail before bootstrap on wrong OS/architecture or unsupported containerd version.
2. Wrong account/region/node: saved baseline includes account, region, instance IDs, source root volume IDs, snapshot IDs; reject mismatches before mutation.
3. Partial restore: wait for both replacement tasks, report failed/detached states, never claim cluster recovery or automatically retry/delete volumes.
4. Mixed cluster generations: baseline disks must have kubelet/containerd masked and stopped; both roots finish restoration before either node's services are unmasked.
5. Baseline loss: refuse overwriting an existing baseline file; reject extra data disks and incomplete snapshots; retain displaced roots until explicitly cleaned up after verification.

---

### Task 1: Reuse node installers on Ubuntu 26.04

**Files:** Create `scripts/node-setup.sh`; create `tests/check_domain0.py`.

**Interfaces:** `bash scripts/node-setup.sh master|worker /absolute/path/to/setup`; consume existing `KUBE_JOIN_COMMAND` for worker. Source the selected original script, override `install_containerd` and master's `install_calico`, invoke its `main`. No downloading arbitrary repository code or running the simulator bootstrap.

- [ ] Write standard-library unittest checks for role/path validation, rejected OS/architecture/runtime versions, source-script reuse, containerd 2.x systemd cgroup configuration, and pinned VXLAN Calico installation. Use temporary fixture scripts and command mocks; never run actual package installation in tests.
- [ ] Run `python3 -I tests/check_domain0.py`; verify the new checks fail because the adapter is absent.
- [ ] Implement adapter with OS/architecture/root checks, Ubuntu containerd package installation, generated config patched to `SystemdCgroup = true`, and pinned Calico manifests. Download remote files into fresh temporary directories; do not run interpreters from those directories. Preserve original script functions for everything else.
- [ ] Run `bash -n scripts/node-setup.sh` and the checks; expect success with no host mutations.

### Task 2: Minimal EC2 snapshot/reset lifecycle

**Files:** Create `scripts/ec2-lab.py`; extend `tests/check_domain0.py`.

**Interfaces:** `python3 scripts/ec2-lab.py snapshot|reset --master i-... --worker i-... --region REGION --baseline PATH [--apply]`. Discover `aws` or `aws.exe`; call via subprocess argv, never a shell. Snapshot requires both instances already stopped after the documented guest-service masking step. Reset requires both running and root-volume-only storage. Creation/start/stop remain explicit AWS CLI commands in the guide rather than additional wrapper subcommands.

- [ ] Add mocked CLI checks: dry-run causes no AWS mutations; duplicate IDs rejected; account/region/baseline mismatch rejected; baseline overwrite rejected; root disks selected by `RootDeviceName`; extra disks and incomplete snapshots rejected; second-node failure leaves first-node results recorded; task polling has a finite timeout and recognizes every failure state; no automatic deletion on failure.
- [ ] Run checks; verify failure because lifecycle wrapper is absent.
- [ ] Implement snapshot of both stopped roots with immutable local baseline metadata. Record each successful cloud operation immediately so a disconnect or second-node failure remains diagnosable. Never silently restart snapshots or replacement tasks.
- [ ] Implement reset using `create-replace-root-volume-task --snapshot-id ... --no-delete-replaced-root-volume`; bounded status checks until both succeed. Retain and report displaced volume IDs for later explicit cleanup. Require the user to confirm the baseline masking procedure before initial snapshots; cloud APIs cannot verify guest systemd state.
- [ ] Run `python3 -I tests/check_domain0.py` and compile scripts without writing bytecode; expect all checks passing. Do not contact AWS in automated tests.

### Task 3: Operator guide and Domain 0 linkage

**Files:** Create `docs/domain0-aws.md`; modify only Domain 0 in `ckschecklist.md`.

**Interfaces:** Guide invokes the two scripts above. English guide; preserve Vietnamese checklist text/style and add one relative guide link.

- [ ] Document read-only AWS preflight, official Ubuntu AMI discovery, subnet/CIDR overlap checks, dedicated security group and regional EC2 Instance Connect prefix-list rules, and two explicit `run-instances` commands. Configure IMDSv2 with hop limit 1, encrypted gp3 disks, no instance IAM profile, stable hostnames. No automatic provisioning run.
- [ ] Document console installation order: transfer reviewed setup files; run master adapter; retrieve root-only join command; run worker adapter; verify exactly two Ready nodes, CoreDNS, cross-node network traffic and NetworkPolicy enforcement, AppArmor, `crictl`, and Kubernetes versions. Do not publish join credentials or cloud identifiers in tracked notes.
- [ ] Document baseline creation: finish desired tools/cache preparation, save notes off-node, mask and stop kubelet/containerd on both nodes, stop both EC2 instances, snapshot both roots, wait for completion, start instances, unmask/start services. Offline tools from checklist remain unchecked until individually installed and tested; the cluster baseline alone does not pass Domain 0.
- [ ] Document each reset: discard/save lab work explicitly; start instances if stopped; replace both roots from the same baseline; wait for both tasks; console-unmask/start services; verify two Ready nodes, clean resources, and node-file rollback. Console reconnection needs rediscovering public IPv4 after ordinary stop/start; private IPs remain stable. No cluster bootstrap reruns.
- [ ] Document an actual destructive-reset acceptance drill to run only after approval: create a namespace and node marker, reset both nodes, verify both disappear and cluster recovers. Root replacement completion alone is not the acceptance gate. Backups protect neither expired certificates nor external AWS networking changes.
- [ ] Document ongoing EC2/EBS/public IPv4/snapshot charges, stop-between-sessions, retained-volume cleanup by explicit volume ID after verification, no cost guarantee, no sensitive credentials on this intentionally vulnerable lab.
- [ ] Run all mocked tests, shell syntax check, `git diff --check`; inspect diff for unintended edits and secrets. Report live EC2/bootstrap/reset checks as NOT RUN unless separately authorized and actually completed.

## Verified references

- Ubuntu AMI lookup: https://ubuntu.com/aws/docs/aws-how-to/instances/find-ubuntu-images/
- Ubuntu 26.04 containerd packages: https://packages.ubuntu.com/resolute/containerd
- Docker resolute package index: https://download.docker.com/linux/ubuntu/dists/resolute/pool/stable/amd64/
- Calico supported versions: https://docs.tigera.io/calico/latest/getting-started/kubernetes/requirements
- Kubernetes runtimes/cgroups: https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Repeatable root-volume restoration, preserved networking, running-instance requirement: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/replace-root.html

## Execution proposal

Native execution in this worktree. Three tightly related tasks do not justify per-task subagents. Review this plan before implementation; AWS mutations require a separate concrete approval.

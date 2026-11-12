#!/usr/bin/env bash
# Automated two-node CKS EC2 lab lifecycle (init | pause | resume | reset | cleanup).
# State is tracked live via AWS tags (Purpose=cks-domain0).
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export AWS_REGION="${AWS_REGION:-ap-southeast-1}"
export AWS_PAGER=""
SSH_MODE="${SSH_MODE:-eic}"
CPU_CREDITS="${CPU_CREDITS:-standard}"
SSH_KEY_DIR="${SSH_KEY_DIR:-$HOME/.local/state/cks-domain0/access}"
STARTUP_SOURCE="${STARTUP_SOURCE:-/home/thienpv/projects/external/gitlab-com/cka-packs/cka-sim/scripts/setup}"
PURPOSE="${PURPOSE_TAG:-cks-domain0}"
BUSY_IMAGE="docker.io/library/busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_aws() {
  if command -v aws >/dev/null 2>&1; then
    AWS=aws
  elif command -v aws.exe >/dev/null 2>&1; then
    AWS=aws.exe
  else
    die "AWS CLI (aws or aws.exe) is required in PATH"
  fi
}

aws_text() {
  "$AWS" "$@" --region "$AWS_REGION" --output text | tr -d '\r'
}

ensure_ssh_key() {
  install -d -m 700 "$SSH_KEY_DIR"
  if [[ ! -e "$SSH_KEY_DIR/id_rsa" ]]; then
    ssh-keygen -q -t rsa -b 3072 -N '' -C disposable-lab-access -f "$SSH_KEY_DIR/id_rsa"
  fi
}

find_role_instance() {
  local role="$1"
  aws_text ec2 describe-instances \
    --filters "Name=tag:Purpose,Values=$PURPOSE" "Name=tag:Role,Values=$role" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId | [0]'
}

require_instances() {
  MASTER=$(find_role_instance master)
  WORKER=$(find_role_instance worker)
  [[ -n "$MASTER" && "$MASTER" != "None" && -n "$WORKER" && "$WORKER" != "None" ]] || \
    die "Could not find active master/worker instances tagged Purpose=$PURPOSE"
}

find_eic_endpoint() {
  aws_text ec2 describe-instance-connect-endpoints \
    --filters "Name=tag:Purpose,Values=$PURPOSE" \
    --query 'InstanceConnectEndpoints[?State!=`delete-complete`].InstanceConnectEndpointId | [0]'
}

eic_send_key() {
  local instance="$1" az ok
  az=$(aws_text ec2 describe-instances --instance-ids "$instance" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone')
  [[ -n "$az" && "$az" != "None" ]] || die "Could not determine AZ for $instance"
  ok=$(aws_text ec2-instance-connect send-ssh-public-key \
    --instance-id "$instance" --availability-zone "$az" --instance-os-user ubuntu \
    --ssh-public-key "$(<"$SSH_KEY_DIR/id_rsa.pub")" --query Success)
  [[ "$ok" == "True" ]] || die "Failed to push EIC SSH key to $instance"
}

instance_public_ip() {
  local ip
  ip=$(aws_text ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress')
  [[ -n "$ip" && "$ip" != "None" ]] || die "No PublicIpAddress on $1"
  printf '%s\n' "$ip"
}

lab_ssh() {
  local instance="$1"; shift
  ensure_ssh_key
  if [[ "$SSH_MODE" == "eic" ]]; then
    [[ -n "${EIC_ENDPOINT:-}" && "${EIC_ENDPOINT:-}" != "None" ]] || EIC_ENDPOINT=$(find_eic_endpoint)
    [[ -n "$EIC_ENDPOINT" && "$EIC_ENDPOINT" != "None" ]] || die "No EIC endpoint found for Purpose=$PURPOSE"
    eic_send_key "$instance" || return
    ssh -o BatchMode=yes -o ConnectTimeout=15 -i "$SSH_KEY_DIR/id_rsa" -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KEY_DIR/known_hosts" \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
      -o "ProxyCommand=\"$AWS\" ec2-instance-connect open-tunnel --region $AWS_REGION --instance-id %h --instance-connect-endpoint-id $EIC_ENDPOINT --remote-port 22 --max-tunnel-duration 3600" \
      "ubuntu@$instance" "$@"
  else
    local pub_ip
    pub_ip=$(instance_public_ip "$instance")
    ssh -o BatchMode=yes -o ConnectTimeout=15 -i "$SSH_KEY_DIR/id_rsa" -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KEY_DIR/known_hosts" \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
      "ubuntu@$pub_ip" "$@"
  fi
}

lab_scp() {
  local instance="$1" src="$2" dst="$3"
  ensure_ssh_key
  if [[ "$SSH_MODE" == "eic" ]]; then
    [[ -n "${EIC_ENDPOINT:-}" && "${EIC_ENDPOINT:-}" != "None" ]] || EIC_ENDPOINT=$(find_eic_endpoint)
    eic_send_key "$instance"
    scp -i "$SSH_KEY_DIR/id_rsa" -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KEY_DIR/known_hosts" \
      -o "ProxyCommand=\"$AWS\" ec2-instance-connect open-tunnel --region $AWS_REGION --instance-id %h --instance-connect-endpoint-id $EIC_ENDPOINT --remote-port 22 --max-tunnel-duration 3600" \
      "$src" "ubuntu@$instance:$dst"
  else
    local pub_ip
    pub_ip=$(instance_public_ip "$instance")
    scp -i "$SSH_KEY_DIR/id_rsa" -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KEY_DIR/known_hosts" \
      "$src" "ubuntu@$pub_ip:$dst"
  fi
}

wait_ssh() {
  local deadline=$((SECONDS + 600))
  printf 'Waiting for SSH/sudo: %s\n' "$1"
  until lab_ssh "$1" 'sudo -n true'; do
    (( SECONDS < deadline )) || die "SSH/sudo readiness timeout: $1"
    sleep 5
  done
}

# Only idempotent recovery/check commands: transport loss may occur after execution.
retry_ssh() {
  local deadline=$((SECONDS + 600)) status
  while :; do
    if lab_ssh "$@" </dev/null; then return 0; else status=$?; fi
    (( status == 255 )) || return "$status"
    (( SECONDS < deadline )) || die "SSH recovery timeout: $1; do not rerun root replacement"
    printf 'SSH transport failed for %s; retrying idempotent recovery/check\n' "$1" >&2
    sleep 5
  done
}

wait_cluster_ready() {
  # Command argument, not stdin: each reconnect must receive the entire check again.
  retry_ssh "$MASTER" 'set -euo pipefail
deadline=$((SECONDS + 600))
until kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; do
  (( SECONDS < deadline )) || exit 1
  sleep 3
done
kubectl wait --for=condition=Ready nodes --all --timeout=600s
test "$(kubectl get nodes -o name | wc -l)" -eq 2
kubectl -n kube-system rollout status deployment/coredns --timeout=300s'
}

workstation_cidr() {
  if [[ -n "${WORKSTATION_CIDR:-}" ]]; then
    printf '%s\n' "$WORKSTATION_CIDR"
  else
    local ip
    ip=$(curl -fsSL https://checkip.amazonaws.com | tr -d '[:space:]')
    [[ -n "$ip" ]] || die "Failed to detect workstation public IP"
    printf '%s/32\n' "$ip"
  fi
}

wait_snapshots() {
  local deadline=$((SECONDS + 3600)) states state complete
  printf 'Waiting for baseline snapshots: %s\n' "$*"
  while :; do
    states=$(aws_text ec2 describe-snapshots --snapshot-ids "$@" --query 'Snapshots[].State')
    complete=0
    for state in $states; do
      case "$state" in
        completed) complete=$((complete + 1)) ;;
        pending) ;;
        *) die "Baseline snapshot state: $state; inspect snapshot IDs before retrying" ;;
      esac
    done
    (( complete == $# )) && return 0
    (( SECONDS < deadline )) || die "Snapshot timeout; inspect these IDs before retrying: $*"
    sleep 15
  done
}

cmd_init() {
  [[ "$CPU_CREDITS" == standard || "$CPU_CREDITS" == unlimited ]] || die "CPU_CREDITS must be standard or unlimited"
  local existing_m existing_w
  existing_m=$(find_role_instance master)
  existing_w=$(find_role_instance worker)
  [[ -z "$existing_m" || "$existing_m" == "None" ]] || die "Master instance $existing_m already exists"
  [[ -z "$existing_w" || "$existing_w" == "None" ]] || die "Worker instance $existing_w already exists"
  [[ -r "$STARTUP_SOURCE/master-startup.sh" && -r "$STARTUP_SOURCE/worker-startup.sh" ]] || \
    die "Missing startup scripts in STARTUP_SOURCE=$STARTUP_SOURCE"

  if [[ -n "${SUBNET_ID:-}" && -z "${VPC_ID:-}" ]]; then
    VPC_ID=$(aws_text ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].VpcId')
  fi
  if [[ -z "${VPC_ID:-}" || "${VPC_ID:-}" == "None" ]]; then
    VPC_ID=$(aws_text ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId')
    if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
      VPC_ID=$(aws_text ec2 describe-vpcs --filters "Name=state,Values=available" --query 'Vpcs[0].VpcId')
    fi
  fi
  [[ -n "${VPC_ID:-}" && "$VPC_ID" != "None" ]] || die "Could not auto-detect VPC_ID"

  if [[ -z "${SUBNET_ID:-}" || "${SUBNET_ID:-}" == "None" ]]; then
    SUBNET_ID=$(aws_text ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
      --query 'Subnets[0].SubnetId')
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
      SUBNET_ID=$(aws_text ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
        --query 'Subnets[0].SubnetId')
    fi
  fi
  [[ -n "${SUBNET_ID:-}" && "$SUBNET_ID" != "None" ]] || die "Could not auto-detect SUBNET_ID in $VPC_ID"

  ensure_ssh_key

  local ami root_dev sg eic_sg cidr user_data_master user_data_worker pub_key
  ami=$(aws_text ec2 describe-images --owners 099720109477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*' \
              'Name=architecture,Values=x86_64' 'Name=state,Values=available' \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId')
  [[ -n "$ami" && "$ami" != "None" ]] || die "Ubuntu 26.04 AMI not found"
  root_dev=$(aws_text ec2 describe-images --image-ids "$ami" --query 'Images[0].RootDeviceName')

  sg=$(aws_text ec2 create-security-group --vpc-id "$VPC_ID" \
    --group-name "$PURPOSE-nodes" --description "Disposable two-node security lab" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=cks-domain0},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=nodes}]" \
    --query GroupId)
  "$AWS" ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$sg" \
    --ip-permissions "[{\"IpProtocol\":\"-1\",\"UserIdGroupPairs\":[{\"GroupId\":\"$sg\"}]}]" >/dev/null

  if [[ "$SSH_MODE" == "eic" ]]; then
    if [[ -n "${EIC_ENDPOINT:-}" ]]; then
      [[ $(aws_text ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$EIC_ENDPOINT" \
        --query 'InstanceConnectEndpoints[0].VpcId') == "$VPC_ID" ]] || die "EIC_ENDPOINT must be in $VPC_ID"
      [[ $(aws_text ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$EIC_ENDPOINT" \
        --query 'InstanceConnectEndpoints[0].PreserveClientIp') == False ]] || die "EIC_ENDPOINT must disable client-IP preservation"
      eic_sg=$(aws_text ec2 describe-instance-connect-endpoints --instance-connect-endpoint-ids "$EIC_ENDPOINT" \
        --query 'InstanceConnectEndpoints[0].SecurityGroupIds[0]')
    else
      eic_sg=$(aws_text ec2 create-security-group --vpc-id "$VPC_ID" \
        --group-name "$PURPOSE-eic" --description "CKS EIC endpoint SG" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=cks-domain0-eic},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=eic}]" \
        --query GroupId)
      EIC_ENDPOINT=$(aws_text ec2 create-instance-connect-endpoint --subnet-id "$SUBNET_ID" \
        --security-group-ids "$eic_sg" --no-preserve-client-ip \
        --tag-specifications "ResourceType=instance-connect-endpoint,Tags=[{Key=Name,Value=cks-eic},{Key=Purpose,Value=$PURPOSE}]" \
        --query 'InstanceConnectEndpoint.InstanceConnectEndpointId')
    fi
    "$AWS" ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$sg" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"UserIdGroupPairs\":[{\"GroupId\":\"$eic_sg\"}]}]" >/dev/null

    local st=""
    until [[ "$st" == "create-complete" ]]; do
      st=$(aws_text ec2 describe-instance-connect-endpoints \
        --instance-connect-endpoint-ids "$EIC_ENDPOINT" \
        --query 'InstanceConnectEndpoints[0].State')
      [[ "$st" != "create-failed" ]] || die "EIC endpoint creation failed"
      [[ "$st" == "create-complete" ]] || sleep 5
    done
    user_data_master=$'#!/bin/bash\nset -eu\nhostnamectl set-hostname cks-master\napt-get update -qq\napt-get install -y ec2-instance-connect\n'
    user_data_worker=$'#!/bin/bash\nset -eu\nhostnamectl set-hostname cks-worker\napt-get update -qq\napt-get install -y ec2-instance-connect\n'
  else
    cidr=$(workstation_cidr)
    "$AWS" ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$sg" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"IpRanges\":[{\"CidrIp\":\"$cidr\"}]}]" >/dev/null
    pub_key=$(<"$SSH_KEY_DIR/id_rsa.pub")
    user_data_master="#!/bin/bash
set -eu
hostnamectl set-hostname cks-master
install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
printf '%s\n' '$pub_key' >> /home/ubuntu/.ssh/authorized_keys
chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
chmod 600 /home/ubuntu/.ssh/authorized_keys
"
    user_data_worker="${user_data_master/cks-master/cks-worker}"
  fi

  local disk="[{\"DeviceName\":\"$root_dev\",\"Ebs\":{\"VolumeSize\":30,\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]"
  MASTER=$(aws_text ec2 run-instances --image-id "$ami" --instance-type t3.medium --count 1 \
    --subnet-id "$SUBNET_ID" --security-group-ids "$sg" --associate-public-ip-address \
    --credit-specification "CpuCredits=$CPU_CREDITS" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
    --block-device-mappings "$disk" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=cks-master},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=master}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=cks-master-root},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=master}]" \
    --user-data "$user_data_master" --query 'Instances[0].InstanceId')

  WORKER=$(aws_text ec2 run-instances --image-id "$ami" --instance-type t3.medium --count 1 \
    --subnet-id "$SUBNET_ID" --security-group-ids "$sg" --associate-public-ip-address \
    --credit-specification "CpuCredits=$CPU_CREDITS" \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
    --block-device-mappings "$disk" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=cks-worker},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=worker}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=cks-worker-root},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=worker}]" \
    --user-data "$user_data_worker" --query 'Instances[0].InstanceId')

  "$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"

  local node file
  for node in "$MASTER" "$WORKER"; do
    wait_ssh "$node"
    lab_ssh "$node" 'sudo cloud-init status --wait >/dev/null && umask 077 && mkdir -p /home/ubuntu/setup-lab'
    for file in "$STARTUP_SOURCE/master-startup.sh" "$STARTUP_SOURCE/worker-startup.sh" "$SCRIPT_DIR/node-setup.sh"; do
      lab_scp "$node" "$file" /home/ubuntu/setup-lab/
    done
  done

  lab_ssh "$MASTER" 'sudo bash /home/ubuntu/setup-lab/node-setup.sh master /home/ubuntu/setup-lab'
  local join_cmd join_arg
  join_cmd=$(lab_ssh "$MASTER" 'sudo cat /var/log/kubeadm-join-command.txt')
  [[ "$join_cmd" == 'kubeadm join '* ]] || die "Invalid join command from master"
  printf -v join_arg '%q' "$join_cmd"
  lab_ssh "$WORKER" "sudo env KUBE_JOIN_COMMAND=$join_arg bash /home/ubuntu/setup-lab/node-setup.sh worker /home/ubuntu/setup-lab"
  unset join_cmd join_arg

  wait_cluster_ready
  lab_ssh "$WORKER" "sudo ctr -n k8s.io images pull --platform linux/amd64 $BUSY_IMAGE"
  lab_ssh "$MASTER" 'sudo bash -s' < "$SCRIPT_DIR/cks-tools.sh"
  lab_ssh "$MASTER" 'sudo bash -s' < "$SCRIPT_DIR/check-cks-tools.sh"
  lab_ssh "$MASTER" 'sudo bash -c "source /dev/stdin; untaint_master"' < "$SCRIPT_DIR/node-setup.sh"

  for node in "$MASTER" "$WORKER"; do
    lab_ssh "$node" 'sudo systemctl mask kubelet.service containerd.service && sudo systemctl stop kubelet.service containerd.service && sudo sync'
  done

  "$AWS" ec2 stop-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER" >/dev/null
  "$AWS" ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"

  local m_vol w_vol m_snap w_snap
  m_vol=$(aws_text ec2 describe-instances --instance-ids "$MASTER" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId')
  w_vol=$(aws_text ec2 describe-instances --instance-ids "$WORKER" --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId')

  m_snap=$(aws_text ec2 create-snapshot --volume-id "$m_vol" --description "cks-domain0-master-baseline" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=cks-master-baseline},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=master},{Key=Pair,Value=$MASTER-$WORKER},{Key=Baseline,Value=true}]" \
    --query SnapshotId)
  w_snap=$(aws_text ec2 create-snapshot --volume-id "$w_vol" --description "cks-domain0-worker-baseline" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=cks-worker-baseline},{Key=Purpose,Value=$PURPOSE},{Key=Role,Value=worker},{Key=Pair,Value=$MASTER-$WORKER},{Key=Baseline,Value=true}]" \
    --query SnapshotId)
  wait_snapshots "$m_snap" "$w_snap"

  "$AWS" ec2 start-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER" >/dev/null
  "$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
  for node in "$MASTER" "$WORKER"; do
    retry_ssh "$node" 'sudo systemctl unmask containerd.service kubelet.service && sudo systemctl enable --now containerd.service kubelet.service'
  done
  wait_cluster_ready
}

cmd_pause() {
  require_instances
  "$AWS" ec2 stop-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER" >/dev/null
  "$AWS" ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
}

cmd_resume() {
  require_instances
  "$AWS" ec2 start-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER" >/dev/null
  "$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
  if [[ "$SSH_MODE" == "direct" ]]; then
    local sg cidr
    sg=$(aws_text ec2 describe-security-groups \
      --filters "Name=tag:Purpose,Values=$PURPOSE" "Name=tag:Role,Values=nodes" \
      --query 'SecurityGroups[0].GroupId')
    cidr=$(workstation_cidr)
    "$AWS" ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$sg" \
      --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":22,\"ToPort\":22,\"IpRanges\":[{\"CidrIp\":\"$cidr\"}]}]" >/dev/null 2>&1 || true
  fi
  wait_cluster_ready
}

cmd_reset() {
  require_instances
  local m_snap w_snap m_task w_task st1 st2
  m_snap=$(aws_text ec2 describe-snapshots --owner-ids self \
    --filters "Name=tag:Purpose,Values=$PURPOSE" "Name=tag:Baseline,Values=true" "Name=tag:Pair,Values=$MASTER-$WORKER" "Name=tag:Role,Values=master" "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId')
  w_snap=$(aws_text ec2 describe-snapshots --owner-ids self \
    --filters "Name=tag:Purpose,Values=$PURPOSE" "Name=tag:Baseline,Values=true" "Name=tag:Pair,Values=$MASTER-$WORKER" "Name=tag:Role,Values=worker" "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId')
  [[ -n "$m_snap" && "$m_snap" != "None" && -n "$w_snap" && "$w_snap" != "None" ]] || \
    die "Missing completed baseline snapshots tagged Purpose=$PURPOSE,Baseline=true"

  "$AWS" ec2 start-instances --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER" >/dev/null
  "$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"

  # Fail before destroying roots if the selected access path cannot recover services.
  lab_ssh "$MASTER" 'sudo -n true'
  lab_ssh "$WORKER" 'sudo -n true'

  m_task=$(aws_text ec2 create-replace-root-volume-task --instance-id "$MASTER" \
    --snapshot-id "$m_snap" --delete-replaced-root-volume \
    --query 'ReplaceRootVolumeTask.ReplaceRootVolumeTaskId')
  w_task=$(aws_text ec2 create-replace-root-volume-task --instance-id "$WORKER" \
    --snapshot-id "$w_snap" --delete-replaced-root-volume \
    --query 'ReplaceRootVolumeTask.ReplaceRootVolumeTaskId')

  printf 'Replacement tasks: master=%s worker=%s\n' "$m_task" "$w_task"
  local deadline=$((SECONDS + 1800))
  until [[ "${st1:-}" == "succeeded" && "${st2:-}" == "succeeded" ]]; do
    st1=$(aws_text ec2 describe-replace-root-volume-tasks --replace-root-volume-task-ids "$m_task" \
      --query 'ReplaceRootVolumeTasks[0].TaskState')
    st2=$(aws_text ec2 describe-replace-root-volume-tasks --replace-root-volume-task-ids "$w_task" \
      --query 'ReplaceRootVolumeTasks[0].TaskState')
    case "$st1:$st2" in
      *failed*) die "Root volume replacement failed: master=$m_task:$st1 worker=$w_task:$st2" ;;
    esac
    for st in "$st1" "$st2"; do
      case "$st" in succeeded|pending|in-progress|failing|failing-detached) ;; *) die "Unknown replacement task state: $st" ;; esac
    done
    (( SECONDS < deadline )) || die "Replacement timeout: master=$m_task:$st1 worker=$w_task:$st2; services stay masked"
    [[ "$st1" == "succeeded" && "$st2" == "succeeded" ]] || sleep 10
  done

  printf 'AWS_ROOT_RESET_PASS: master=%s worker=%s; guest recovery pending\n' "$m_task" "$w_task"
  "$AWS" ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$MASTER" "$WORKER"
  local node
  for node in "$MASTER" "$WORKER"; do
    retry_ssh "$node" 'sudo systemctl unmask containerd.service kubelet.service && sudo systemctl enable --now containerd.service kubelet.service'
  done
  wait_cluster_ready
}

cmd_cleanup() {
  local instances snaps vols eics sgs id
  instances=$(aws_text ec2 describe-instances \
    --filters "Name=tag:Purpose,Values=$PURPOSE" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId')
  if [[ -n "$instances" && "$instances" != "None" ]]; then
    # shellcheck disable=SC2086
    "$AWS" ec2 terminate-instances --region "$AWS_REGION" --instance-ids $instances >/dev/null
    # shellcheck disable=SC2086
    "$AWS" ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids $instances
  fi

  snaps=$(aws_text ec2 describe-snapshots --owner-ids self \
    --filters "Name=tag:Purpose,Values=$PURPOSE" \
    --query 'Snapshots[].SnapshotId')
  for id in $snaps; do
    [[ "$id" != "None" ]] && "$AWS" ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$id" >/dev/null
  done

  vols=$(aws_text ec2 describe-volumes \
    --filters "Name=tag:Purpose,Values=$PURPOSE" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId')
  for id in $vols; do
    [[ "$id" != "None" ]] && "$AWS" ec2 delete-volume --region "$AWS_REGION" --volume-id "$id" >/dev/null
  done

  eics=$(aws_text ec2 describe-instance-connect-endpoints \
    --filters "Name=tag:Purpose,Values=$PURPOSE" \
    --query 'InstanceConnectEndpoints[?State!=`delete-complete`].InstanceConnectEndpointId')
  for id in $eics; do
    [[ "$id" == "None" ]] && continue
    "$AWS" ec2 delete-instance-connect-endpoint --region "$AWS_REGION" --instance-connect-endpoint-id "$id" >/dev/null
    local st=delete-in-progress deadline=$((SECONDS + 600))
    until [[ "$st" == "None" || "$st" == "delete-complete" ]]; do
      st=$(aws_text ec2 describe-instance-connect-endpoints \
        --filters "Name=instance-connect-endpoint-id,Values=$id" \
        --query 'InstanceConnectEndpoints[0].State')
      [[ "$st" != delete-failed ]] || die "EIC endpoint deletion failed: $id"
      (( SECONDS < deadline )) || die "EIC endpoint deletion timed out: $id"
      [[ "$st" == "None" || "$st" == "delete-complete" ]] || sleep 5
    done
  done

  local role
  for role in nodes eic; do
    sgs=$(aws_text ec2 describe-security-groups \
      --filters "Name=tag:Purpose,Values=$PURPOSE" "Name=tag:Role,Values=$role" \
      --query 'SecurityGroups[].GroupId')
    for id in $sgs; do
      [[ "$id" == "None" ]] && continue
      "$AWS" ec2 delete-security-group --region "$AWS_REGION" --group-id "$id" >/dev/null
    done
  done
}

main() {
  require_aws
  [[ "$SSH_MODE" == "eic" || "$SSH_MODE" == "direct" ]] || \
    die "SSH_MODE must be 'eic' or 'direct' (got: $SSH_MODE)"
  case "${1:-}" in
    init)    cmd_init ;;
    pause)   cmd_pause ;;
    resume)  cmd_resume ;;
    reset)   cmd_reset ;;
    cleanup) cmd_cleanup ;;
    *)       die "Usage: $0 {init|pause|resume|reset|cleanup}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

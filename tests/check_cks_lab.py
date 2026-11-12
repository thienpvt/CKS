#!/usr/bin/env python3
"""Unit tests for scripts/cks-lab.sh lifecycle automation."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cks-lab.sh"

FAKE_AWS = r'''
echo "aws $*" >> "$CALL_LOG"
case "$*" in
  *"sts get-caller-identity"*)
    echo "123456789012" ;;
  *"describe-vpcs"*)
    echo "vpc-auto111" ;;
  *"describe-subnets"*"map-public-ip-on-launch"*)
    echo "None" ;;
  *"describe-subnets"*"VpcId"*)
    echo "vpc-auto111" ;;
  *"describe-subnets"*)
    echo "subnet-auto222" ;;
  *"describe-images"*"RootDeviceName"*)
    echo "/dev/sda1" ;;
  *"describe-images"*)
    echo "ami-0123456789abcdef0" ;;
  *"create-security-group"*"cks-domain0-eic"*)
    echo "sg-eic111" ;;
  *"create-security-group"*)
    echo "sg-nodes111" ;;
  *"create-instance-connect-endpoint"*)
    echo "eice-111111" ;;
  *"describe-instance-connect-endpoints"*"InstanceConnectEndpoints[0].State"*)
    echo "${FAKE_EIC_STATE:-create-complete}" ;;
  *"describe-instance-connect-endpoints"*"SecurityGroupIds"*)
    echo "sg-existing" ;;
  *"describe-instance-connect-endpoints"*"VpcId"*)
    echo "vpc-1111" ;;
  *"describe-instance-connect-endpoints"*"PreserveClientIp"*)
    echo "False" ;;
  *"describe-instance-connect-endpoints"*)
    echo "eice-111111" ;;
  *"run-instances"*"cks-master"*)
    echo "i-master111" ;;
  *"run-instances"*"cks-worker"*)
    echo "i-worker222" ;;
  *"describe-instances"*"State.Name"*)
    echo "${FAKE_INSTANCE_STATE:-running} ${FAKE_INSTANCE_STATE:-running}" ;;
  *"describe-instances"*"Placement.AvailabilityZone"*)
    echo "ap-southeast-1a" ;;
  *"describe-instances"*"PublicIpAddress"*)
    echo "198.51.100.25" ;;
  *"describe-instances"*"BlockDeviceMappings"*)
    if [[ "$*" == *"i-master111"* ]]; then echo "vol-master111"; else echo "vol-worker222"; fi ;;
  *"describe-instances"*"Role,Values=master"*)
    echo "${FAKE_MASTER_ID:-i-master111}" ;;
  *"describe-instances"*"Role,Values=worker"*)
    echo "${FAKE_WORKER_ID:-i-worker222}" ;;
  *"describe-instances"*)
    echo "${FAKE_INSTANCES:-i-master111 i-worker222}" ;;
  *"send-ssh-public-key"*)
    echo "True" ;;
  *"create-snapshot"*"vol-master111"*)
    echo "snap-master111" ;;
  *"create-snapshot"*"vol-worker222"*)
    echo "snap-worker222" ;;
  *"describe-snapshots"*"Snapshots[].State"*)
    echo "completed completed" ;;
  *"describe-snapshots"*"tag:Pair"*)
    if [[ "$*" != *"Name=tag:Pair,Values=i-master111-i-worker222"* ]]; then echo None
    elif [[ "$*" == *"Role,Values=master"* ]]; then echo "snap-master111"
    else echo "snap-worker222"; fi ;;
  *"describe-snapshots"*"Role,Values=master"*)
    echo "snap-master111" ;;
  *"describe-snapshots"*"Role,Values=worker"*)
    echo "snap-worker222" ;;
  *"describe-snapshots"*)
    echo "snap-master111 snap-worker222" ;;
  *"create-replace-root-volume-task"*"i-master111"*)
    echo "replacevol-master111" ;;
  *"create-replace-root-volume-task"*"i-worker222"*)
    echo "replacevol-worker222" ;;
  *"describe-replace-root-volume-tasks"*)
    echo "succeeded" ;;
  *"describe-volumes"*)
    echo "vol-detached111" ;;
  *"describe-security-groups"*"Role,Values=nodes"*)
    echo "sg-nodes111" ;;
  *"describe-security-groups"*"Role,Values=eic"*)
    echo "sg-eic111" ;;
  *"describe-security-groups"*)
    echo "sg-eic111 sg-nodes111" ;;
esac
'''


class CksLabScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmpdir = Path(self.tmp.name)
        self.bin_dir = self.tmpdir / "bin"
        self.bin_dir.mkdir()
        self.log_file = self.tmpdir / "calls.log"
        self.startup_dir = self.tmpdir / "startup"
        self.startup_dir.mkdir()
        (self.startup_dir / "master-startup.sh").write_text("main() { :; }\n")
        (self.startup_dir / "worker-startup.sh").write_text("main() { :; }\n")

    def write_exe(self, name, content):
        path = self.bin_dir / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + content)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def base_env(self, **extra):
        env = {
            "PATH": f"{self.bin_dir}:/usr/bin:/bin",
            "HOME": str(self.tmpdir),
            "AWS_REGION": "ap-southeast-1",
            "VPC_ID": "vpc-1111",
            "SUBNET_ID": "subnet-2222",
            "STARTUP_SOURCE": str(self.startup_dir),
            "CALL_LOG": str(self.log_file),
        }
        env.update(extra)
        return env

    def install_fake_tools(self, aws_body=FAKE_AWS):
        self.write_exe("ssh-keygen", 'for a in "$@"; do last="$a"; done; touch "$last" "$last.pub"; echo "ssh-rsa AAAA test" > "$last.pub"\n')
        self.write_exe("curl", 'echo "203.0.113.10"\n')
        self.write_exe("scp", 'echo "scp $*" >> "$CALL_LOG"\n')
        self.write_exe("ssh", (
            'echo "ssh $*" >> "$CALL_LOG"\n'
            'if [[ "$*" == *"kubeadm-join-command.txt"* ]]; then\n'
            '  echo "kubeadm join 10.0.0.10:6443 --token abc --discovery-token-ca-cert-hash sha256:123"\n'
            'fi\n'
        ))
        self.write_exe("aws", aws_body)

    def run_script(self, *args, env=None):
        return subprocess.run(
            ["bash", str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env=env or self.base_env(),
        )

    def test_missing_aws_cli_fails_fast(self):
        result = self.run_script("pause", env={"PATH": "/usr/bin:/bin", "HOME": str(self.tmpdir)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aws", result.stderr.lower())

    def test_invalid_action_or_ssh_mode_rejected(self):
        self.install_fake_tools()
        res1 = self.run_script("unknown")
        self.assertNotEqual(res1.returncode, 0)
        self.assertIn("Usage:", res1.stderr)
        res2 = self.run_script("pause", env=self.base_env(SSH_MODE="invalid"))
        self.assertNotEqual(res2.returncode, 0)
        self.assertIn("SSH_MODE", res2.stderr)

    def test_pause_and_resume_discover_instances_via_tags(self):
        self.install_fake_tools()
        res_pause = self.run_script("pause")
        self.assertEqual(res_pause.returncode, 0, res_pause.stderr)
        calls = self.log_file.read_text()
        self.assertIn("stop-instances", calls)
        self.assertIn("i-master111", calls)
        self.assertIn("i-worker222", calls)
        self.assertIn("wait instance-stopped", calls)

        self.log_file.write_text("")
        res_resume = self.run_script("resume")
        self.assertEqual(res_resume.returncode, 0, res_resume.stderr)
        calls = self.log_file.read_text()
        self.assertIn("start-instances", calls)
        self.assertIn("wait instance-status-ok", calls)

    def test_init_eic_creates_resources_bootstraps_and_snapshots(self):
        self.install_fake_tools()
        res = self.run_script("init", env=self.base_env(FAKE_MASTER_ID="None", FAKE_WORKER_ID="None"))
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertIn("create-instance-connect-endpoint", calls)
        self.assertIn("run-instances", calls)
        self.assertIn("node-setup.sh master", calls)
        self.assertIn("node-setup.sh worker", calls)
        self.assertIn("systemctl mask kubelet.service containerd.service", calls)
        self.assertIn("create-snapshot", calls)
        self.assertIn("Key=Baseline,Value=true", calls)
        self.assertIn("systemctl unmask containerd.service kubelet.service", calls)

    def test_ssh_readiness_retries_probe_without_replaying_remote_changes(self):
        self.install_fake_tools()
        res = subprocess.run(
            ["bash", "-c", 'source "$1"; attempts=0; lab_ssh() { [[ "$2" == "sudo -n true" ]] || return 99; attempts=$((attempts+1)); ((attempts >= 3)); }; sleep() { :; }; wait_ssh i-test; [[ "$attempts" == 3 ]]', "check", str(SCRIPT)],
            capture_output=True, text=True, env=self.base_env(), timeout=10,
        )
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_snapshot_wait_observes_pending_then_completed(self):
        self.install_fake_tools()
        res = subprocess.run(
            ["bash", "-c", 'source "$1"; require_aws; aws_text() { local n=0; [[ ! -e "$HOME/polls" ]] || read -r n < "$HOME/polls"; n=$((n+1)); printf "%s\\n" "$n" > "$HOME/polls"; if ((n == 1)); then printf "pending completed\\n"; else printf "completed completed\\n"; fi; }; sleep() { :; }; wait_snapshots snap-one snap-two', "check", str(SCRIPT)],
            capture_output=True, text=True, env=self.base_env(), timeout=10,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual((self.tmpdir / "polls").read_text().strip(), "2")

    def test_init_auto_picks_vpc_and_subnet_when_unset(self):
        self.install_fake_tools()
        env = self.base_env(FAKE_MASTER_ID="None", FAKE_WORKER_ID="None")
        env.pop("VPC_ID", None)
        env.pop("SUBNET_ID", None)
        res = self.run_script("init", env=env)
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertIn("--vpc-id vpc-auto111", calls)
        self.assertIn("--subnet-id subnet-auto222", calls)

    def test_init_names_security_groups_from_purpose_tag(self):
        self.install_fake_tools()
        env = self.base_env(PURPOSE_TAG="cks-domain0-live-eic-20261112", FAKE_MASTER_ID="None", FAKE_WORKER_ID="None")
        res = self.run_script("init", env=env)
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertIn("--group-name cks-domain0-live-eic-20261112-nodes", calls)
        self.assertIn("--group-name cks-domain0-live-eic-20261112-eic", calls)

    def test_init_supports_explicit_burst_credits(self):
        self.install_fake_tools()
        res = self.run_script("init", env=self.base_env(CPU_CREDITS="unlimited", FAKE_MASTER_ID="None", FAKE_WORKER_ID="None"))
        self.assertEqual(res.returncode, 0, res.stderr)
        launches = [line for line in self.log_file.read_text().splitlines() if "run-instances" in line]
        self.assertEqual(len(launches), 2)
        for launch in launches:
            self.assertIn("CpuCredits=unlimited", launch)

    def test_invalid_credit_mode_rejected_before_creating_resources(self):
        self.install_fake_tools()
        res = self.run_script("init", env=self.base_env(CPU_CREDITS="invalid", FAKE_MASTER_ID="None", FAKE_WORKER_ID="None"))
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("CPU_CREDITS", res.stderr)
        self.assertNotIn("create-security-group", self.log_file.read_text() if self.log_file.exists() else "")

    def test_init_can_borrow_endpoint_without_creating_or_tagging_it(self):
        self.install_fake_tools()
        res = self.run_script("init", env=self.base_env(EIC_ENDPOINT="eice-existing", FAKE_MASTER_ID="None", FAKE_WORKER_ID="None"))
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertNotIn("create-instance-connect-endpoint", calls)
        self.assertIn('"GroupId":"sg-existing"', calls)
        self.assertIn("--instance-connect-endpoint-id eice-existing", calls)
        self.assertNotIn("create-tags", calls)

    def test_init_direct_uses_workstation_cidr_and_cloud_init_ssh_key(self):
        self.install_fake_tools()
        res = self.run_script("init", env=self.base_env(SSH_MODE="direct", FAKE_MASTER_ID="None", FAKE_WORKER_ID="None"))
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertNotIn("create-instance-connect-endpoint", calls)
        self.assertIn("203.0.113.10/32", calls)
        self.assertIn("authorized_keys", calls)
        self.assertIn("ubuntu@198.51.100.25", calls)

    def test_reset_replaces_root_volumes_from_tagged_snapshots_and_unmasks(self):
        self.install_fake_tools()
        res = self.run_script("reset")
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertIn("create-replace-root-volume-task", calls)
        self.assertIn("--snapshot-id snap-master111", calls)
        self.assertIn("--snapshot-id snap-worker222", calls)
        self.assertIn("--delete-replaced-root-volume", calls)
        self.assertIn("systemctl unmask containerd.service kubelet.service", calls)
        self.assertIn("AWS_ROOT_RESET_PASS", res.stdout)

    def test_reset_retries_lost_service_start_response_without_replacing_roots_again(self):
        self.install_fake_tools()
        self.write_exe("ssh", r'''
            printf 'ssh %s\n' "$*" >> "$CALL_LOG"
            if [[ "$*" == *i-worker222* && "$*" == *'systemctl unmask'* ]]; then
                if [[ ! -e "$HOME/service-started" ]]; then
                    touch "$HOME/service-started"
                    exit 255  # Service started, but transport lost the response.
                fi
            fi
        ''')
        res = subprocess.run(
            ["bash", "-c", 'source "$1"; sleep() { :; }; main reset', "check", str(SCRIPT)],
            capture_output=True, text=True, env=self.base_env(), stdin=subprocess.DEVNULL, timeout=10,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertEqual(calls.count("aws ec2 create-replace-root-volume-task "), 2)
        self.assertEqual(calls.count("systemctl unmask containerd.service kubelet.service"), 3)
        self.assertNotIn("node-setup.sh", calls)

    def test_service_error_exits_without_retry(self):
        self.install_fake_tools()
        self.write_exe("ssh", r'''
            printf 'ssh %s\n' "$*" >> "$CALL_LOG"
            if [[ "$*" == *'systemctl unmask'* ]]; then
                printf 'containerd start failed\n' >&2
                exit 42
            fi
        ''')
        res = self.run_script("reset")
        self.assertEqual(res.returncode, 42, res.stderr)
        self.assertIn("containerd start failed", res.stderr)
        self.assertEqual(self.log_file.read_text().count("systemctl unmask"), 1)

    def test_health_retry_resends_entire_check_after_transport_consumes_input(self):
        self.install_fake_tools()
        self.write_exe("ssh", r'''
            payload="$*"
            if [[ "$payload" == *'bash -s'* ]]; then payload=$(</dev/stdin); fi
            if [[ "$payload" == *'kubectl wait'* ]]; then
                printf '%s\n' "$payload" >> "$HOME/health-checks"
                if [[ ! -e "$HOME/health-disconnected" ]]; then
                    touch "$HOME/health-disconnected"
                    exit 255
                fi
            fi
        ''')
        res = subprocess.run(
            ["bash", "-c", 'source "$1"; sleep() { :; }; main resume', "check", str(SCRIPT)],
            capture_output=True, text=True, env=self.base_env(), stdin=subprocess.DEVNULL, timeout=10,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        checks = (self.tmpdir / "health-checks").read_text()
        self.assertEqual(checks.count("kubectl wait --for=condition=Ready nodes"), 2)
        self.assertEqual(checks.count("rollout status deployment/coredns"), 2)

    def test_recovery_transport_retries_stop_at_deadline(self):
        self.install_fake_tools()
        self.write_exe("ssh", r'''
            printf 'ssh %s\n' "$*" >> "$CALL_LOG"
            if [[ "$*" == *'systemctl unmask'* ]]; then exit 255; fi
        ''')
        res = subprocess.run(
            ["bash", "-c", 'source "$1"; sleep() { SECONDS=$((SECONDS + 601)); }; main reset', "check", str(SCRIPT)],
            capture_output=True, text=True, env=self.base_env(), stdin=subprocess.DEVNULL, timeout=10,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("SSH recovery timeout", res.stderr)
        self.assertIn("AWS_ROOT_RESET_PASS", res.stdout)
        calls = self.log_file.read_text()
        self.assertEqual(calls.count("aws ec2 create-replace-root-volume-task "), 2)
        self.assertEqual(calls.count("systemctl unmask"), 2)

    def test_reset_proves_access_before_replacing_disks(self):
        self.install_fake_tools()
        self.write_exe("ssh", 'exit 255\n')
        res = self.run_script("reset")
        self.assertNotEqual(res.returncode, 0)
        self.assertNotIn("create-replace-root-volume-task", self.log_file.read_text())

    def test_reset_limits_snapshots_to_exact_instance_pair(self):
        self.install_fake_tools()
        res = self.run_script("reset")
        self.assertEqual(res.returncode, 0, res.stderr)
        queries = [line for line in self.log_file.read_text().splitlines() if "describe-snapshots" in line]
        self.assertEqual(len(queries), 2)
        for query in queries:
            self.assertIn("Name=tag:Pair,Values=i-master111-i-worker222", query)

    def test_stalled_reset_times_out_without_unmasking(self):
        self.install_fake_tools(aws_body=FAKE_AWS.replace('echo "succeeded" ;;', 'echo "in-progress" ;;'))
        res = subprocess.run(
            ["bash", "-c", 'source "$1"; sleep() { SECONDS=$((SECONDS + 2000)); }; main reset', "check", str(SCRIPT)],
            capture_output=True, text=True, env=self.base_env(), timeout=10,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Replacement timeout", res.stderr)
        self.assertNotIn("systemctl unmask", self.log_file.read_text())

    def test_failed_reset_never_unmasks_services(self):
        body = FAKE_AWS.replace('echo "succeeded" ;;', 'if [[ "$*" == *replacevol-worker222* ]]; then echo failed; else echo succeeded; fi ;;')
        self.install_fake_tools(aws_body=body)
        res = self.run_script("reset")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("master=replacevol-master111:succeeded worker=replacevol-worker222:failed", res.stderr)
        self.assertNotIn("systemctl unmask", self.log_file.read_text())

    def test_reset_rejects_missing_pair_before_starting_instances(self):
        body = FAKE_AWS.replace('echo "snap-worker222"', 'echo "None"')
        self.install_fake_tools(aws_body=body)
        res = self.run_script("reset")
        self.assertNotEqual(res.returncode, 0)
        calls = self.log_file.read_text()
        self.assertNotIn("start-instances", calls)
        self.assertNotIn("create-replace-root-volume-task", calls)

    def test_cleanup_removes_instances_snapshots_volumes_endpoint_and_sgs(self):
        self.install_fake_tools()
        res = self.run_script("cleanup", env=self.base_env(FAKE_EIC_STATE="delete-complete"))
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log_file.read_text()
        self.assertIn("terminate-instances", calls)
        self.assertIn("delete-snapshot --region ap-southeast-1 --snapshot-id snap-master111", calls)
        self.assertIn("delete-snapshot --region ap-southeast-1 --snapshot-id snap-worker222", calls)
        self.assertIn("delete-volume --region ap-southeast-1 --volume-id vol-detached111", calls)
        self.assertIn("delete-instance-connect-endpoint --region ap-southeast-1 --instance-connect-endpoint-id eice-111111", calls)
        nodes_idx = calls.find("delete-security-group --region ap-southeast-1 --group-id sg-nodes111")
        eic_idx = calls.find("delete-security-group --region ap-southeast-1 --group-id sg-eic111")
        self.assertNotEqual(nodes_idx, -1)
        self.assertNotEqual(eic_idx, -1)
        self.assertLess(nodes_idx, eic_idx)
        deletion = calls.index("aws ec2 delete-instance-connect-endpoint")
        observation = calls.find("InstanceConnectEndpoints[0].State", deletion)
        self.assertNotEqual(observation, -1, "Cleanup must observe endpoint deletion before removing its groups")
        self.assertLess(observation, nodes_idx)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Offline checks only: no AWS requests, package installs or host writes."""
import contextlib
import copy
import importlib.util
import io
import json
from unittest.mock import patch
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "scripts/node-setup.sh"


class NodeSetupTests(unittest.TestCase):
    def shell(self, body, *args, env=None):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; shift; ' + body, "check", str(ADAPTER), *args],
            capture_output=True, text=True, env=env,
        )

    def test_platform_rejects_wrong_os_architecture_and_nonroot(self):
        for values in [("debian", "26.04", "x86_64", "0"),
                       ("ubuntu", "24.04", "x86_64", "0"),
                       ("ubuntu", "26.04", "aarch64", "0"),
                       ("ubuntu", "26.04", "x86_64", "1000")]:
            with self.subTest(values=values):
                result = self.shell('check_platform "$@"', *values)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("requires Ubuntu 26.04 amd64 as root", result.stderr)
        result = self.shell('check_platform ubuntu 26.04 x86_64 0')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_runtime_rejects_1x_and_generates_systemd_cgroups(self):
        result = self.shell("check_runtime 'containerd containerd.io 1.7.23 abc'")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires containerd 2.x", result.stderr)
        result = self.shell("check_runtime 'containerd containerd.io 2.2.2 abc'; "
                            "containerd() { printf '%s\\n' '[plugins.test.options]' 'SystemdCgroup = false'; }; "
                            "runtime_config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SystemdCgroup = true", result.stdout)
        self.assertNotIn("SystemdCgroup = false", result.stdout)

    def test_untaint_master_is_idempotent_and_preserves_other_taints(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / 'taints'
            original = ['node-role.kubernetes.io/control-plane:NoSchedule', 'dedicated:NoSchedule']
            state.write_text('\n'.join(original) + '\n')
            result = self.shell(r'''
                kubectl() {
                    [[ "$1" == --kubeconfig=/etc/kubernetes/admin.conf ]] || return 90
                    shift
                    case "$1" in
                        get)
                            [[ "$2 $3" == 'node cks-master' ]] || return 91
                            /usr/bin/cat "$TAINTS" ;;
                        taint)
                            [[ "$*" == 'taint node cks-master node-role.kubernetes.io/control-plane:NoSchedule-' ]] || return 92
                            grep -vx 'node-role.kubernetes.io/control-plane:NoSchedule' "$TAINTS" > "$TAINTS.new"
                            mv "$TAINTS.new" "$TAINTS" ;;
                        *) return 93 ;;
                    esac
                }
                untaint_master
                untaint_master
            ''', env=dict(os.environ, TAINTS=str(state)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(state.read_text(), 'dedicated:NoSchedule\n')
        result = self.shell('kubectl() { return 80; }; untaint_master')
        self.assertNotEqual(result.returncode, 0)

    def test_bootstrap_untaints_before_initialized_master_exits(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'master-startup.sh').write_text('main() { exit 0; }\n')
            marker = path / 'untainted'
            env = dict(os.environ, MARKER=str(marker))
            result = self.shell(r'''
                kubectl() {
                    [[ "$1" == --kubeconfig=/etc/kubernetes/admin.conf ]] || return 90
                    shift
                    case "$1" in
                        get) printf '%s\n' 'node-role.kubernetes.io/control-plane:NoSchedule' ;;
                        taint) touch "$MARKER" ;;
                        *) return 91 ;;
                    esac
                }
                bootstrap master "$1"
            ''', tmp, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker.exists())

    def test_role_and_missing_source_rejected_before_bootstrap(self):
        result = self.shell('bootstrap unknown /missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("master|worker", result.stderr)
        result = self.shell('bootstrap master /missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)

    def test_existing_scripts_reused_and_worker_join_environment_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            for role in ("master", "worker"):
                (path / f"{role}-startup.sh").write_text(
                    'install_containerd() { exit 99; }\n'
                    'install_calico() { exit 98; }\n'
                    'main() { printf "original-main:%s:%s\\n" "$1" "${KUBE_JOIN_COMMAND:-}"; }\n'
                    '[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"\n')
                env = dict(os.environ, KUBE_JOIN_COMMAND="kubeadm join private:6443 --token test")
                result = self.shell('kubectl() { return 0; }; bootstrap "$@"', role, tmp, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("original-main:", result.stdout)
                self.assertIn("kubeadm join private:6443 --token test", result.stdout)

    def test_bootstrap_restores_readable_apt_files_after_restrictive_transfer_mask(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'master-startup.sh').write_text('main() { touch "$PROBE"; }\n')
            env = dict(os.environ, PROBE=str(path / 'apt.list'))
            result = self.shell('kubectl() { return 0; }; umask 077; bootstrap master "$1"', tmp, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((path / 'apt.list').stat().st_mode & 0o777, 0o644)

    def test_calico_downloads_are_pinned_and_installation_forces_vxlan(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, TMPDIR=tmp)
            result = self.shell(r'''
                curl() {
                    [[ "$*" == *'/v3.33.0/manifests/'* ]] || return 90
                    printf '%s\n' 'spec:' '  calicoNetwork:' '    ipPools:' \
                        '      - cidr: 192.168.0.0/16' '        encapsulation: VXLANCrossSubnet' > "$2"
                }
                kubectl() {
                    if [[ "$1" == create ]]; then /usr/bin/cat "${@: -1}"; fi
                }
                install_calico
            ''', env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("encapsulation: VXLAN\n", result.stdout)
            self.assertIn("bgp: Disabled", result.stdout)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_calico_waits_for_operator_crds_before_custom_resources(self):
        result = self.shell(r'''
            ready=0
            curl() { printf '%s\n' '  calicoNetwork:' '        encapsulation: VXLANCrossSubnet' > "$2"; }
            kubectl() {
                case "$1" in
                    wait) [[ "$*" == *'Established'* ]] && ready=1 ;;
                    create)
                        if [[ "${@: -1}" == *resources.yaml && "$ready" != 1 ]]; then
                            printf 'CRDs not Established\n' >&2; return 80
                        fi ;;
                    get) return 0 ;;
                esac
            }
            install_calico
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)


class CalicoReadinessTests(unittest.TestCase):
    shell = NodeSetupTests.shell

    def test_calico_retries_missing_conditions_before_custom_resources(self):
        result = self.shell(r'''
            attempts=0
            curl() { printf '%s\n' '  calicoNetwork:' '        encapsulation: VXLANCrossSubnet' > "$2"; }
            sleep() { :; }
            kubectl() {
                case "$1" in
                    get) return 0 ;;
                    wait)
                        attempts=$((attempts + 1))
                        if [[ $attempts == 1 ]]; then
                            printf 'error: .status.conditions accessor error: <nil>\n' >&2
                            return 1
                        fi ;;
                    create)
                        if [[ "${@: -1}" == *resources.yaml ]]; then
                            [[ $attempts -ge 5 ]] || return 81
                            printf 'CUSTOM_RESOURCES_CREATED\n'
                        fi ;;
                esac
            }
            install_calico
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CUSTOM_RESOURCES_CREATED', result.stdout)

    def test_calico_missing_conditions_times_out_without_creating_resources(self):
        result = self.shell(r'''
            curl() { printf '%s\n' '  calicoNetwork:' '        encapsulation: VXLANCrossSubnet' > "$2"; }
            sleep() { SECONDS=10000; }
            kubectl() {
                case "$1" in
                    get) return 0 ;;
                    wait) return 1 ;;
                    create) [[ "${@: -1}" != *resources.yaml ]] ;;
                esac
            }
            install_calico
        ''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Timed out waiting for', result.stderr)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        script = ROOT / "scripts/ec2-lab.py"
        self.assertTrue(script.exists(), "snapshot/reset implementation missing")
        spec = importlib.util.spec_from_file_location("ec2_lab", script)
        self.lab = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.lab)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.baseline = Path(self.tmp.name) / "baseline.json"
        self.master = "i-0123456789abcdef0"
        self.worker = "i-0123456789abcdef1"
        self.region = "ap-southeast-1"
        self.account = "123456789012"
        self.calls = []
        self.state = "stopped"
        self.snap_state = "completed"
        self.task_state = "succeeded"
        self.extra_disk = False
        self.fail_second = False

    def fake_aws(self, service, action, *args):
        self.calls.append((service, action, *args))
        if action == "get-caller-identity":
            return {"Account": self.account}
        if action == "describe-instances":
            instances = []
            for n, ident in enumerate((self.master, self.worker)):
                mappings = [{"DeviceName": "/dev/sda1", "Ebs": {"VolumeId": f"vol-{n}", "Status": "attached"}}]
                if self.extra_disk:
                    mappings.insert(0, {"DeviceName": "/dev/sdf", "Ebs": {"VolumeId": "vol-extra"}})
                instances.append({"InstanceId": ident, "RootDeviceName": "/dev/sda1",
                                  "RootDeviceType": "ebs", "State": {"Name": self.state},
                                  "Tags": [{"Key": "Purpose", "Value": "cks-domain0"}],
                                  "BlockDeviceMappings": mappings})
            return {"Reservations": [{"Instances": instances}]}
        if action == "create-snapshot":
            n = sum(c[1] == action for c in self.calls) - 1
            if self.fail_second and n == 1:
                raise RuntimeError("second snapshot failed")
            return {"SnapshotId": f"snap-{n}"}
        if action == "describe-snapshots":
            return {"Snapshots": [{"SnapshotId": f"snap-{n}", "VolumeId": f"vol-{n}",
                                    "OwnerId": self.account, "State": self.snap_state} for n in range(2)]}
        if action == "create-replace-root-volume-task":
            n = sum(c[1] == action for c in self.calls) - 1
            if self.fail_second and n == 1:
                raise RuntimeError("second replacement failed")
            return {"ReplaceRootVolumeTask": {"ReplaceRootVolumeTaskId": f"replacevol-{n}"}}
        if action == "describe-replace-root-volume-tasks":
            if "--filters" in args:
                return {"ReplaceRootVolumeTasks": []}
            return {"ReplaceRootVolumeTasks": [{"ReplaceRootVolumeTaskId": f"replacevol-{n}",
                                                "TaskState": self.task_state} for n in range(2)]}
        if action == "terminate-instances":
            return {"TerminatingInstances": []}
        if action == "wait":
            return {}
        self.fail(f"Unexpected AWS operation: {service} {action} {args}")

    def run_lab(self, action, apply=False, extra=(), taint_free=True):
        argv = [action, "--master", self.master, "--worker", self.worker,
                "--region", self.region, "--baseline", str(self.baseline)]
        if action == "snapshot" and taint_free:
            argv.append("--taint-free")
        argv.extend(extra)
        if apply:
            argv.append("--apply")

        with patch.object(self.lab, "aws", side_effect=self.fake_aws), \
             patch("builtins.input", side_effect=lambda _: f"{self.master} {self.worker}"), \
             contextlib.redirect_stdout(io.StringIO()):
            return self.lab.main(argv)

    def seed(self):
        self.baseline.write_text(json.dumps({"account": self.account, "region": self.region,
            "services_masked": True, "control_plane_schedulable": True, "nodes": [
                {"role": "master", "instance_id": self.master, "root_volume_id": "vol-0", "snapshot_id": "snap-0"},
                {"role": "worker", "instance_id": self.worker, "root_volume_id": "vol-1", "snapshot_id": "snap-1"}]}))
        self.state = "running"

    def mutations(self):
        return [c for c in self.calls if c[1].startswith(("create-", "delete-", "stop-", "start-"))]

    def test_dry_run_snapshot_and_reset_make_no_mutations_or_local_state(self):
        self.run_lab("snapshot")
        self.assertFalse(self.baseline.exists())
        self.assertFalse(self.mutations())
        self.seed()
        before = self.baseline.read_bytes()
        self.run_lab("reset")
        self.assertFalse(self.mutations())
        self.assertEqual(self.baseline.read_bytes(), before)
        self.assertEqual(len(list(Path(self.tmp.name).iterdir())), 1)

    def test_duplicate_instance_ids_rejected(self):
        self.worker = self.master
        with self.assertRaises((ValueError, RuntimeError)):
            self.run_lab("snapshot", apply=True)
        self.assertFalse(self.mutations())

    def test_snapshot_overwrite_extra_disk_and_wrong_state_rejected(self):
        for fault in ("exists", "extra", "running"):
            with self.subTest(fault=fault):
                self.extra_disk = fault == "extra"
                self.state = "running" if fault == "running" else "stopped"
                if fault == "exists":
                    self.baseline.write_text("do not overwrite")
                elif self.baseline.exists():
                    self.baseline.unlink()
                with self.assertRaises((ValueError, RuntimeError)):
                    self.run_lab("snapshot", apply=True)
                self.assertFalse(self.mutations())

    def test_snapshot_requires_taint_free_confirmation_before_mutation(self):
        with self.assertRaisesRegex(RuntimeError, "taint-free"):
            self.run_lab("snapshot", apply=True, taint_free=False)
        self.assertFalse(self.mutations())
        self.assertFalse(self.baseline.exists())

    def test_snapshot_records_both_root_volumes(self):
        self.run_lab("snapshot", apply=True)
        saved = json.loads(self.baseline.read_text())
        self.assertEqual(saved["account"], "123456789012")
        self.assertEqual(saved["region"], "ap-southeast-1")
        self.assertTrue(saved["services_masked"])
        self.assertTrue(saved["control_plane_schedulable"])
        self.assertEqual([(n["root_volume_id"], n["snapshot_id"]) for n in saved["nodes"]],
                         [("vol-0", "snap-0"), ("vol-1", "snap-1")])

    def test_partial_snapshot_records_first_success(self):
        self.fail_second = True
        with self.assertRaisesRegex(RuntimeError, "second snapshot failed"):
            self.run_lab("snapshot", apply=True)
        saved = json.loads(self.baseline.read_text())
        self.assertEqual(saved["nodes"][0]["snapshot_id"], "snap-0")
        self.assertIsNone(saved["nodes"][1].get("snapshot_id"))

    def test_reset_rejects_account_region_ids_or_mask_mismatch_before_mutation(self):
        self.seed()
        original = json.loads(self.baseline.read_text())
        for key in ("account", "region", "instance", "services_masked", "snapshot_id"):
            data = copy.deepcopy(original)
            if key == "instance":
                data["nodes"][1]["instance_id"] = "i-00000000000000000"
            elif key == "services_masked":
                data[key] = False
            elif key == "snapshot_id":
                data["nodes"][1][key] = None
            else:
                data[key] = "wrong"
            self.baseline.write_text(json.dumps(data))
            with self.subTest(key=key), self.assertRaises((ValueError, RuntimeError)):
                self.run_lab("reset", apply=True)
            self.assertFalse(self.mutations())

    def test_reset_rejects_incomplete_or_wrong_source_snapshots(self):
        self.seed()
        self.snap_state = "pending"
        with self.assertRaises((ValueError, RuntimeError)):
            self.run_lab("reset", apply=True)
        self.assertFalse(self.mutations())
        self.snap_state = "completed"
        saved = json.loads(self.baseline.read_text())
        saved["nodes"][0]["root_volume_id"] = "vol-wrong"
        self.baseline.write_text(json.dumps(saved))
        with self.assertRaises((ValueError, RuntimeError)):
            self.run_lab("reset", apply=True)
        self.assertFalse(self.mutations())

    def test_reset_retains_displaced_roots_and_journals_task_ids(self):
        self.seed()
        self.run_lab("reset", apply=True)
        changes = self.mutations()
        self.assertEqual(len(changes), 2)
        for command in changes:
            self.assertIn("--no-delete-replaced-root-volume", command)
            self.assertNotIn("--delete-replaced-root-volume", command)
        logs = list(Path(self.tmp.name).glob("baseline.json.reset-*.json"))
        self.assertEqual(len(logs), 1)
        data = json.loads(logs[0].read_text())
        self.assertEqual([n["task_id"] for n in data["nodes"]], ["replacevol-0", "replacevol-1"])
        self.assertEqual([n["displaced_volume_id"] for n in data["nodes"]], ["vol-0", "vol-1"])
        self.assertEqual(self.calls[-1], ("ec2", "wait", "instance-status-ok",
                                         "--instance-ids", self.master, self.worker))

    def test_partial_reset_records_first_task_and_does_not_delete(self):
        self.seed()
        self.fail_second = True
        with self.assertRaisesRegex(RuntimeError, "second replacement failed"):
            self.run_lab("reset", apply=True)
        logs = list(Path(self.tmp.name).glob("baseline.json.reset-*.json"))
        data = json.loads(logs[0].read_text())
        self.assertEqual(data["nodes"][0]["task_id"], "replacevol-0")
        self.assertFalse(any(c[1].startswith("delete-") for c in self.calls))

    def test_reset_rejects_baseline_without_schedulable_control_plane(self):
        for value in (None, False):
            self.seed()
            data = json.loads(self.baseline.read_text())
            data["control_plane_schedulable"] = value
            self.baseline.write_text(json.dumps(data))
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "schedulable"):
                self.run_lab("reset", apply=True)
            self.assertFalse(self.mutations())

    def test_transient_failure_keeps_observing_both_tasks_to_terminal_states(self):
        path = Path(self.tmp.name) / 'tasks.json'
        journal = {"nodes": [{"task_id": "replacevol-0"}, {"task_id": "replacevol-1"}]}
        responses = [
            {"ReplaceRootVolumeTasks": [
                {"ReplaceRootVolumeTaskId": "replacevol-0", "TaskState": "failing-detached"},
                {"ReplaceRootVolumeTaskId": "replacevol-1", "TaskState": "in-progress"}]},
            {"ReplaceRootVolumeTasks": [
                {"ReplaceRootVolumeTaskId": "replacevol-0", "TaskState": "failed-detached"},
                {"ReplaceRootVolumeTaskId": "replacevol-1", "TaskState": "succeeded"}]},
        ]
        with patch.object(self.lab, 'aws', side_effect=responses), patch.object(self.lab.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'failed-detached'):
                self.lab.wait_tasks(path, journal)
        self.assertEqual([n['task_state'] for n in json.loads(path.read_text())['nodes']],
                         ['failed-detached', 'succeeded'])

    def cleanup(self, apply=False, confirmation=None):
        argv = ["cleanup", "--master", self.master, "--worker", self.worker, "--region", self.region]
        if apply:
            argv.append("--apply")
        with patch.object(self.lab, "aws", side_effect=self.fake_aws), \
             patch("builtins.input", return_value=confirmation or f"{self.master} {self.worker}"), \
             contextlib.redirect_stdout(io.StringIO()):
            self.lab.main(argv)

    def test_cleanup_terminates_exactly_the_two_lab_instances(self):
        self.cleanup(apply=True)
        writes = [c for c in self.calls if c[1] == "terminate-instances"]
        self.assertEqual(writes, [("ec2", "terminate-instances", "--instance-ids", self.master, self.worker)])
        self.assertEqual(self.calls[-1], ("ec2", "wait", "instance-terminated",
                                         "--instance-ids", self.master, self.worker))
        self.assertFalse(any(c[1].startswith(("create-", "delete-")) for c in self.calls))

    def test_cleanup_preview_and_rejected_confirmation_never_terminate(self):
        self.cleanup()
        self.assertFalse(any(c[1] == "terminate-instances" for c in self.calls))
        with self.assertRaisesRegex(RuntimeError, "Confirmation did not match"):
            self.cleanup(apply=True, confirmation="wrong")
        self.assertFalse(any(c[1] == "terminate-instances" for c in self.calls))

    def test_cleanup_rejects_unrelated_instances_and_skips_terminated_pair(self):
        original_aws = self.fake_aws

        def unrelated(service, action, *args):
            result = original_aws(service, action, *args)
            if action == "describe-instances":
                result["Reservations"][0]["Instances"][1]["Tags"] = []
            return result

        with patch.object(self, "fake_aws", side_effect=unrelated):
            with self.assertRaisesRegex(RuntimeError, "Purpose tag"):
                self.cleanup(apply=True)
        self.assertFalse(any(c[1] == "terminate-instances" for c in self.calls))
        self.state = "terminated"
        self.cleanup(apply=True)
        self.assertFalse(any(c[1] == "terminate-instances" for c in self.calls))
        self.assertFalse(self.baseline.exists())

    def test_failed_tasks_and_timeout_fail_closed(self):
        self.seed()
        for state in ("failing", "failed", "failing-detached", "failed-detached", "pending"):
            self.task_state = state
            with self.subTest(state=state), patch.object(self.lab.time, "sleep"), \
                 patch.object(self.lab.time, "monotonic", side_effect=[0, 1, 10000, 10001]):
                with self.assertRaises((ValueError, RuntimeError, TimeoutError)):
                    self.run_lab("reset", apply=True)
        self.assertFalse(any(c[1].startswith("delete-") for c in self.calls))


if __name__ == "__main__":
    unittest.main(verbosity=2)

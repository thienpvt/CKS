#!/usr/bin/env python3
"""Snapshot/reset exactly two disposable EC2 roots. Read-only unless --apply."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

REGION = None


def aws(service, action, *args):
    executable = shutil.which("aws") or shutil.which("aws.exe")
    if not executable:
        raise RuntimeError("AWS CLI v2 required (aws or aws.exe)")
    command = [executable, service, action, *args, "--region", REGION,
               "--output", "json", "--no-cli-pager", "--cli-connect-timeout", "15",
               "--cli-read-timeout", "60"]
    result = subprocess.run(command, capture_output=True, text=True,
                            env=dict(os.environ, AWS_MAX_ATTEMPTS="1", AWS_PAGER=""))
    if result.returncode:
        raise RuntimeError(f"{action}: {result.stderr.strip()}")
    return json.loads(result.stdout or "{}")


def save(path, data, create=False):
    """Reserve once, then replace atomically; do not lose known cloud results."""
    if create:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
    name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
            name = out.name
            json.dump(data, out, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if name and os.path.exists(name):
            os.unlink(name)


def nodes_for(ids, state):
    response = aws("ec2", "describe-instances", "--instance-ids", *ids)
    instances = {i["InstanceId"]: i for r in response["Reservations"] for i in r["Instances"]}
    if set(instances) != set(ids):
        raise RuntimeError("Expected exactly the two requested instances")
    nodes = []
    for role, ident in zip(("master", "worker"), ids):
        instance = instances[ident]
        mappings = instance.get("BlockDeviceMappings", [])
        roots = [m for m in mappings if m["DeviceName"] == instance["RootDeviceName"]]
        if (instance.get("RootDeviceType") != "ebs" or len(mappings) != 1 or
                len(roots) != 1 or "Ebs" not in roots[0]):
            raise RuntimeError(f"{ident}: requires exactly one EBS root disk; extra disks are not reset")
        if instance["State"]["Name"] != state:
            raise RuntimeError(f"{ident}: must be {state}")
        nodes.append({"role": role, "instance_id": ident,
                      "root_volume_id": roots[0]["Ebs"]["VolumeId"]})
    return nodes


def verify_snapshots(data, wait=False):
    wanted = {n["snapshot_id"]: n for n in data["nodes"]}
    deadline = time.monotonic() + 1800
    while True:
        snapshots = aws("ec2", "describe-snapshots", "--snapshot-ids", *wanted)["Snapshots"]
        if {s["SnapshotId"] for s in snapshots} != set(wanted):
            raise RuntimeError("Missing baseline snapshots")
        for snapshot in snapshots:
            if (snapshot["OwnerId"] != data["account"] or
                    snapshot["VolumeId"] != wanted[snapshot["SnapshotId"]]["root_volume_id"]):
                raise RuntimeError("Snapshot owner/source does not match baseline")
            if snapshot["State"] not in ("pending", "completed"):
                raise RuntimeError(f"Snapshot failed: {snapshot['SnapshotId']} {snapshot['State']}")
        if all(s["State"] == "completed" for s in snapshots):
            return
        if not wait:
            raise RuntimeError("Baseline snapshots not completed")
        if time.monotonic() >= deadline:
            raise TimeoutError("Snapshot timeout; inspect recorded IDs, do not resubmit blindly")
        time.sleep(15)


def confirm(ids, snapshot=False):
    if snapshot:
        print("Confirm BOTH nodes have kubelet and containerd persistently MASKED and STOPPED, "
              "then were stopped in EC2. AWS cannot verify guest service state.")
    else:
        print("WARNING: Reset discards ALL changes on BOTH root disks since baseline. "
              "Keep node services masked until BOTH replacement tasks succeed. Old disks retained.")
    expected = " ".join(ids)
    if input(f"Type both instance IDs to confirm [{expected}]: ").strip() != expected:
        raise RuntimeError("Confirmation did not match; no mutations requested")


def wait_tasks(path, journal):
    deadline = time.monotonic() + 1800
    pending = {n["task_id"] for n in journal["nodes"]}
    failures = []
    while pending:
        tasks = aws("ec2", "describe-replace-root-volume-tasks",
                    "--replace-root-volume-task-ids", *sorted(pending))["ReplaceRootVolumeTasks"]
        if {t["ReplaceRootVolumeTaskId"] for t in tasks} != pending:
            raise RuntimeError("Missing replacement tasks; inspect journal before retrying")
        for task in tasks:
            ident, state = task["ReplaceRootVolumeTaskId"], task["TaskState"]
            for node in journal["nodes"]:
                if node["task_id"] == ident:
                    node["task_state"] = state
            if state == "succeeded":
                pending.remove(ident)
            elif state in ("failed", "failed-detached"):
                failures.append(f"{ident}: {state}")
                pending.remove(ident)
            elif state not in ("pending", "in-progress", "failing", "failing-detached"):
                raise RuntimeError(f"Unknown replacement state {ident}: {state}")
        save(path, journal)
        if pending:
            if time.monotonic() >= deadline:
                raise TimeoutError("Replacement timeout; inspect journal, do not resubmit blindly")
            time.sleep(15)
    if failures:
        raise RuntimeError("Replacement failure; do not start services: " + "; ".join(failures))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("snapshot", "reset"))
    for flag in ("master", "worker", "region", "baseline"):
        parser.add_argument(f"--{flag}", required=True)
    parser.add_argument("--apply", action="store_true", help="request cloud mutations; prompts for confirmation")
    args = parser.parse_args(argv)
    ids = [args.master, args.worker]
    if len(set(ids)) != 2 or not all(re.fullmatch(r"i-[0-9a-f]{8,17}", i) for i in ids):
        raise ValueError("Two distinct valid instance IDs required")
    global REGION
    REGION = args.region
    path = Path(args.baseline).expanduser().absolute()
    account = aws("sts", "get-caller-identity")["Account"]
    print(f"Account {account}; region {REGION}; nodes {' '.join(ids)}")
    nodes = nodes_for(ids, "stopped" if args.action == "snapshot" else "running")

    if args.action == "snapshot":
        if path.exists():
            raise RuntimeError("Baseline file exists; never overwrite it. Inspect previous operation first.")
        if not path.parent.is_dir():
            raise RuntimeError("Create the baseline's parent directory outside the repository first")
        data = {"account": account, "region": REGION, "services_masked": True,
                "created_at": datetime.now(timezone.utc).isoformat(), "nodes": nodes}
        for node in nodes:
            print(f"PLAN create-snapshot --volume-id {node['root_volume_id']} ({node['role']})")
        if not args.apply:
            print("Read-only preview. Mask/stop guest services, stop both instances, then use --apply.")
            return
        confirm(ids, snapshot=True)
        save(path, data, create=True)
        for node in nodes:
            # Intent first: on a lost response, find the snapshot by this description.
            node["request_description"] = f"lab-baseline-{uuid.uuid4()}-{node['role']}"
            save(path, data)
            snapshot = aws("ec2", "create-snapshot", "--volume-id", node["root_volume_id"],
                           "--description", node["request_description"])
            node["snapshot_id"] = snapshot["SnapshotId"]
            save(path, data)
        verify_snapshots(data, wait=True)
        print(f"Both snapshots completed: {path}. Start instances, then unmask/start node services.")
        return

    data = json.loads(path.read_text())
    if (data.get("account") != account or data.get("region") != REGION or
            data.get("services_masked") is not True or
            [(n.get("role"), n.get("instance_id")) for n in data.get("nodes", [])] !=
            [("master", ids[0]), ("worker", ids[1])] or
            not all(n.get("snapshot_id") for n in data["nodes"])):
        raise RuntimeError("Account, region, node identities, masking or snapshots do not match baseline")
    verify_snapshots(data)
    active = aws("ec2", "describe-replace-root-volume-tasks", "--filters",
                 f"Name=instance-id,Values={','.join(ids)}")["ReplaceRootVolumeTasks"]
    if any(t["TaskState"] in ("pending", "in-progress", "failing", "failing-detached") for t in active):
        raise RuntimeError("Existing replacement task active; inspect it instead of resubmitting")
    commands = []
    for node, baseline in zip(nodes, data["nodes"]):
        command = ["--instance-id", node["instance_id"], "--snapshot-id", baseline["snapshot_id"],
                   "--no-delete-replaced-root-volume"]
        commands.append(command)
        print("PLAN create-replace-root-volume-task " + shlex.join(command))
    if not args.apply:
        print("Read-only preview. Add --apply to confirm reset.")
        return
    confirm(ids)
    journal_path = path.with_name(path.name + f".reset-{uuid.uuid4()}.json")
    journal = {"account": account, "region": REGION, "baseline": str(path), "nodes": []}
    for node, command in zip(nodes, commands):
        journal["nodes"].append({"instance_id": node["instance_id"],
                                 "displaced_volume_id": node["root_volume_id"],
                                 "client_token": str(uuid.uuid4()), "command": command})
    save(journal_path, journal, create=True)
    print(f"Recovery journal: {journal_path}")
    for node in journal["nodes"]:
        task = aws("ec2", "create-replace-root-volume-task", *node["command"],
                   "--client-token", node["client_token"])
        node["task_id"] = task["ReplaceRootVolumeTask"]["ReplaceRootVolumeTaskId"]
        save(journal_path, journal)
    wait_tasks(journal_path, journal)
    print("Both roots restored. Reconnect consoles; unmask/start services on BOTH nodes, then verify cluster.")
    print("Retained displaced disks (delete explicitly ONLY after verification): " +
          " ".join(n["displaced_volume_id"] for n in journal["nodes"]))
    print(f"Journal: {journal_path}. AWS task success is not a Kubernetes health check.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, KeyError, EOFError, TimeoutError) as exc:
        print(f"ERROR: {exc}\nInspect saved baseline/journal and AWS task history before retrying.", file=sys.stderr)
        sys.exit(1)

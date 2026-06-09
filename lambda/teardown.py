"""
Auto-teardown guardrail.

EventBridge fires this on a schedule. It terminates any EC2 instance tagged
TestPlane=true (and Project=<project>) whose age exceeds MAX_AGE_HOURS. This is
the serverless cost backstop: if someone forgets `harness down`, a stale test
plane self-destructs instead of billing all weekend.

Deliberately tag-driven and out-of-band — it does NOT touch the observability
plane (no TestPlane tag) or the persistent metrics volume. It also leaves
Terraform state stale by design; reconcile with `terraform apply`/`refresh`
afterwards. Cost-stop beats state-tidiness for a guardrail.

Env:
  MAX_AGE_HOURS  float  age threshold (default 3)
  PROJECT        str    Project tag to scope to (default nfs-harness)
  DRY_RUN        str    "true" = log only, never terminate (default false)
"""
import datetime
import os

import boto3

ec2 = boto3.client("ec2")


def handler(event, context):
    max_age_hours = float(os.environ.get("MAX_AGE_HOURS", "3"))
    project = os.environ.get("PROJECT", "nfs-harness")
    dry_run = os.environ.get("DRY_RUN", "false").lower() == "true"

    now = datetime.datetime.now(datetime.timezone.utc)
    cutoff = now - datetime.timedelta(hours=max_age_hours)

    resp = ec2.describe_instances(
        Filters=[
            {"Name": "tag:TestPlane", "Values": ["true"]},
            {"Name": "tag:Project", "Values": [project]},
            {"Name": "instance-state-name",
             "Values": ["pending", "running", "stopping", "stopped"]},
        ]
    )

    stale, kept = [], []
    for reservation in resp["Reservations"]:
        for inst in reservation["Instances"]:
            iid = inst["InstanceId"]
            launched = inst["LaunchTime"]
            age_h = (now - launched).total_seconds() / 3600.0
            if launched < cutoff:
                stale.append(iid)
                print(f"STALE  {iid} age={age_h:.2f}h > {max_age_hours}h")
            else:
                kept.append(iid)
                print(f"keep   {iid} age={age_h:.2f}h")

    if stale and not dry_run:
        ec2.terminate_instances(InstanceIds=stale)
        print(f"TERMINATED {len(stale)}: {stale}")
    elif stale:
        print(f"DRY_RUN: would terminate {len(stale)}: {stale}")
    else:
        print("nothing stale")

    return {
        "terminated": [] if dry_run else stale,
        "would_terminate": stale if dry_run else [],
        "kept": kept,
        "max_age_hours": max_age_hours,
        "dry_run": dry_run,
    }

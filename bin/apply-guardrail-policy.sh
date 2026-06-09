#!/usr/bin/env bash
###############################################################################
# apply-guardrail-policy.sh — attach the teardown guardrail's inline policy
# out-of-band.
#
# Needed only while the deploy principal lacks iam:GetRolePolicy (so terraform
# can't manage the inline policy itself — see docs/tight-iam-gaps.md #2/#6).
# iam:PutRolePolicy works; it's the read-back terraform does that doesn't. This
# script does the Put directly. Idempotent — safe to re-run.
#
# Usage: bin/apply-guardrail-policy.sh [aws_profile] [project_name]
###############################################################################
set -euo pipefail
PROFILE="${1:-nfs-harness-broad}"
PROJECT="${2:-nfs-harness}"
ROLE="${PROJECT}-teardown"
REGION="${AWS_REGION:-us-east-1}"

read -r -d '' POLICY <<JSON || true
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "Describe", "Effect": "Allow",
      "Action": ["ec2:DescribeInstances"], "Resource": "*" },
    { "Sid": "TerminateProjectOnly", "Effect": "Allow",
      "Action": ["ec2:TerminateInstances"], "Resource": "*",
      "Condition": { "StringEquals": { "ec2:ResourceTag/Project": "${PROJECT}" } } },
    { "Sid": "Logs", "Effect": "Allow",
      "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:*:*" }
  ]
}
JSON

echo "attaching inline policy '${PROJECT}-teardown' to role ${ROLE} (profile ${PROFILE})"
aws iam put-role-policy \
  --role-name "$ROLE" \
  --policy-name "${PROJECT}-teardown" \
  --policy-document "$POLICY" \
  --profile "$PROFILE" --region "$REGION"
echo "done — guardrail role is armed."

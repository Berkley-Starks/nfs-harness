###############################################################################
# Auto-teardown guardrail — the real serverless win.
#
# EventBridge → Lambda → terminate any TestPlane=true instance older than
# var.max_test_plane_age_hours. Serverless is the RIGHT tool here precisely
# because the job is short, stateless, and event-driven — the opposite of the
# long-lived, stateful client fleet that has to be EC2.
#
# Scoped tight: the IAM policy only allows terminating instances carrying this
# project's Project tag, so the guardrail can never reach beyond the harness.
###############################################################################

locals {
  teardown_count = var.teardown_enabled ? 1 : 0
}

# Zip the handler at plan time — no build step, no registry.
data "archive_file" "teardown" {
  count       = local.teardown_count
  type        = "zip"
  source_file = "${path.module}/../lambda/teardown.py"
  output_path = "${path.module}/.build/teardown.zip"
}

# --- IAM ------------------------------------------------------------------
data "aws_iam_policy_document" "teardown_assume" {
  count = local.teardown_count
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "teardown" {
  count              = local.teardown_count
  name               = "${var.project_name}-teardown"
  assume_role_policy = data.aws_iam_policy_document.teardown_assume[0].json
}

data "aws_iam_policy_document" "teardown" {
  count = local.teardown_count

  # Describe is account-wide (the API does not support resource scoping), but
  # it is read-only.
  statement {
    sid       = "Describe"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # Terminate is constrained to instances tagged with THIS project.
  statement {
    sid       = "TerminateProjectOnly"
    actions   = ["ec2:TerminateInstances"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

# Inline policy for the guardrail role. Terraform reads inline role policies back
# after writing them (iam:GetRolePolicy). Where the deploy principal lacks that
# read (as both nfs-harness users do — see docs/tight-iam-gaps.md #2), set
# manage_guardrail_inline_policy=false: the PutRolePolicy still lands the policy
# on the role, you just stop terraform from tracking it. Grant iam:GetRolePolicy
# and flip this back to true to restore full IaC management (terraform import).
resource "aws_iam_role_policy" "teardown" {
  count  = var.teardown_enabled && var.manage_guardrail_inline_policy ? 1 : 0
  name   = "${var.project_name}-teardown"
  role   = aws_iam_role.teardown[0].id
  policy = data.aws_iam_policy_document.teardown[0].json
}

# --- Lambda ---------------------------------------------------------------
resource "aws_lambda_function" "teardown" {
  count            = local.teardown_count
  function_name    = "${var.project_name}-teardown"
  role             = aws_iam_role.teardown[0].arn
  handler          = "teardown.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.teardown[0].output_path
  source_code_hash = data.archive_file.teardown[0].output_base64sha256

  environment {
    variables = {
      MAX_AGE_HOURS = tostring(var.max_test_plane_age_hours)
      PROJECT       = var.project_name
      DRY_RUN       = tostring(var.teardown_dry_run)
    }
  }
}

# --- EventBridge schedule -------------------------------------------------
resource "aws_cloudwatch_event_rule" "teardown" {
  count               = local.teardown_count
  name                = "${var.project_name}-teardown"
  description         = "Reap stale ${var.project_name} test-plane instances"
  schedule_expression = var.teardown_schedule
}

resource "aws_cloudwatch_event_target" "teardown" {
  count     = local.teardown_count
  rule      = aws_cloudwatch_event_rule.teardown[0].name
  target_id = "teardown-lambda"
  arn       = aws_lambda_function.teardown[0].arn
}

resource "aws_lambda_permission" "teardown_events" {
  count         = local.teardown_count
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.teardown[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.teardown[0].arn
}

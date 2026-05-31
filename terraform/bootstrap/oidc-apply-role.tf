# oidc-apply-role.tf — GitHub Actions OIDC APPLY role for the governed-org path.
#
# ADR-0051. In the aegis governed org, the org SCP `deny-iam-privilege-
# escalation` denies iam:CreateRole / AttachRolePolicy / PassRole AND the
# teardown twins (DetachRolePolicy / DeleteRolePolicy) for every principal
# EXCEPT a name-glob allow-list. So neither the human `make cloud-up` nor
# `make cloud-down` can create or destroy the enclave's IAM in-org. This role
# is named in the `gh-tf-*` family, which the SCP glob already permits — so the
# landing-zone needs NO SCP change to let this role apply/destroy IAM.
#
# This is the APPLY sibling of the read-only plan role in main.tf (ADR-0026);
# both federate the same aws_iam_openid_connect_provider.github.
#
# Forker note: a forker in an ungoverned account never assumes this role — they
# run the end-to-end local `make cloud-up` / `make cloud-down`. The role + the
# cloud-apply / cloud-destroy workflows are an opt-in governed-org overlay.
#
# Chicken-and-egg: the first creation of this role is itself an iam:CreateRole,
# blocked for a human by the SCP. Seed it once via the aegis-emergency-break-
# glass role (surgical create), then it self-sustains via OIDC.

# ─── Trust: rename-proof, push-to-main only ────────────────────────────────
# Bind to the IMMUTABLE repository_id (StringEquals), wildcard the repo NAME in
# the sub (StringLike) so a repo rename cannot break OIDC auth. Apply runs ONLY
# on push to main; PR events get the read-only plan role, never this one.
data "aws_iam_policy_document" "gha_apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository_id"
      values   = [var.github_repo_id]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/*:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_terraform_apply" {
  name               = "gh-tf-apply-enclave"
  assume_role_policy = data.aws_iam_policy_document.gha_apply_trust.json
  description        = "GitHub Actions OIDC - terraform apply/destroy on main (ADR-0051). gh-tf-* name is covered by the org SCP deny-iam-privilege-escalation carve-out."
}

# ─── Resource CRUD: PowerUserAccess (everything EXCEPT iam/organizations) ───
# The enclave apply surface (VPC, VPC endpoints, Client VPN, ALB, ECS, app
# autoscaling, ECR, SQS, ElastiCache Serverless, DynamoDB, S3 result buckets,
# CloudWatch, SNS, Route53, Budgets, ACM-read, IPAM allocate/preview, AND the
# S3+DynamoDB state backend) is all non-IAM, so PowerUserAccess covers it.
#
# Why NOT AdministratorAccess (which the sibling aegis-platform-aws apply role
# uses): the SCP carve-out for `gh-tf-*` REMOVES the org SCP as a backstop for
# THIS role, so the role's own policy is the only guardrail against escalation.
# PowerUserAccess withholds iam:* — so a compromised apply (a malicious commit
# reaching main) cannot mint an Admin role and escalate. The narrow IAM writes
# the apply genuinely needs are added below, scoped to aegis-enclave-*.
#
# Production hardening: replace PowerUserAccess with the per-service action
# lists enumerated in ADR-0051. PowerUserAccess is proportionate while the
# enclave deploys into a DEDICATED account (account boundary == workload
# boundary); tighten it for a shared account.
resource "aws_iam_role_policy_attachment" "gha_apply_poweruser" {
  role       = aws_iam_role.gha_terraform_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# ─── IAM: the escalation-critical surface, tightly scoped ──────────────────
# tfsec:ignore -- the role / passrole / instance-profile resources ARE the
# least-privilege control (the aegis-enclave-* prefix wildcard is the scope, not
# an over-permission). The two "*" statements are read-only (plan refresh) and
# the AWS-service-name-conditioned CreateServiceLinkedRole. Intentional; the
# scoping that matters (escalation) is enforced. See ADR-0051.
#tfsec:ignore:aws-iam-no-policy-wildcards
data "aws_iam_policy_document" "gha_apply_iam" {
  # Read IAM (plan refresh): reads are not escalation, and terraform must read
  # the AWS-managed policies it attaches (e.g. AmazonEC2ContainerRegistryReadOnly)
  # plus the roles it manages. Mirrors what ReadOnlyAccess gave the plan role.
  statement {
    sid    = "IamReadForRefresh"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetInstanceProfile",
      "iam:ListRoles",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListPolicyVersions",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["*"]
  }

  # Write/lifecycle the enclave's OWN task + execution roles ONLY. Scoping to
  # aegis-enclave-* is the load-bearing control: even a compromised apply cannot
  # create an arbitrary Admin role outside this prefix and assume it.
  statement {
    sid    = "EnclaveRoleLifecycle"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = ["arn:aws:iam::*:role/aegis-enclave-*"]
  }

  # PassRole only for enclave roles, and only TO the services that run them —
  # the service condition stops PassRole being used as an escalation lever.
  statement {
    sid       = "EnclavePassRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/aegis-enclave-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "ecs.amazonaws.com"]
    }
  }

  # Instance profiles for the enclave, scoped the same way (community modules
  # may create them).
  statement {
    sid    = "EnclaveInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = ["arn:aws:iam::*:instance-profile/aegis-enclave-*"]
  }

  # Service-linked roles for the workload's services, constrained by the AWS
  # service name (these trust policies are AWS-controlled, not an escalation
  # path). No-op when the SLRs already exist in the account.
  statement {
    sid       = "WorkloadServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "application-autoscaling.amazonaws.com",
        "elasticache.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "gha_apply_iam" {
  name   = "gh-tf-apply-enclave-iam-scoped"
  role   = aws_iam_role.gha_terraform_apply.id
  policy = data.aws_iam_policy_document.gha_apply_iam.json
}

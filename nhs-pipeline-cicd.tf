# ---------- OIDC: GitHub Actions authenticates with a short-lived token, not stored keys ----------
# NOTE: an AWS account can only have one OIDC provider per URL. If you've
# ever set this up before in this account, apply will fail with
# "EntityAlreadyExists" - delete this resource and look the existing one up
# with a data source instead.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # No thumbprint_list: AWS validates GitHub's OIDC provider against its own
  # trusted root CAs now, not a stored thumbprint, and current AWS provider
  # versions don't require the argument. If terraform complains it's
  # missing, add: thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "nhs-pipeline-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Scoped to your repo, any branch/PR - needed since this same role
          # is used by both PR jobs and main-branch jobs. Swap the path if
          # the repo ever moves.
          "token.actions.githubusercontent.com:sub" = "repo:mo-mo35/NHS-Airflow-dbt-Pipeline:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "nhs-pipeline-gha-ecr"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken" # this one action isn't scopable to a single repo - it's account-wide by design
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = aws_ecr_repository.nhs_pipeline.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_actions_terraform" {
  name = "nhs-pipeline-gha-terraform"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # State bucket access, so CI reads/writes the same state file you do locally.
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      },
      {
        # Broad on purpose: `apply` needs to manage whatever resource types
        # this config uses, and that list grows as the project does. A real
        # team setup would split into narrower plan/apply roles - a
        # reasonable thing to defer on a solo project, and worth naming as a
        # known trade-off if it comes up in an interview.
        Effect = "Allow"
        Action = [
          "ecs:*", "ecr:*", "logs:*", "scheduler:*", "s3:*", "ec2:Describe*",
          "iam:GetRole", "iam:PassRole", "iam:CreateRole", "iam:DeleteRole", "iam:TagRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy",
          "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "Put this in the AWS_GHA_ROLE_ARN repository variable in GitHub (Settings > Secrets and variables > Actions > Variables)"
}

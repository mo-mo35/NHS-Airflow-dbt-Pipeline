terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

terraform {
  backend "s3" {
    bucket       = "nhs-pipeline-tfstate-330859152022"
    key          = "nhs-pipeline/terraform.tfstate"
    region       = "eu-west-2"
    use_lockfile = true
  }
}

variable "aws_region" {
  type    = string
  default = "eu-west-2"
}

provider "aws" {
  region = var.aws_region

}

# ---------- Container registry ----------
resource "aws_ecr_repository" "nhs_pipeline" {
  name                 = "nhs-ae-pipeline"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # portfolio project - allow destroy without manual image cleanup
}

# ---------- Data bucket (raw CSV cache + dbt docs output) ----------
resource "aws_s3_bucket" "nhs_data" {
  bucket        = "nhs-ae-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

data "aws_caller_identity" "current" {}

# ---------- ECS cluster (no always-on capacity - Fargate is pay-per-run) ----------
resource "aws_ecs_cluster" "nhs_pipeline" {
  name = "nhs-ae-pipeline"
}

# ---------- IAM: task execution role (pull image, write logs) ----------
resource "aws_iam_role" "task_execution" {
  name = "nhs-pipeline-task-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------- IAM: task role (what the running container can access - S3 only) ----------
resource "aws_iam_role" "task_role" {
  name = "nhs-pipeline-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "task_s3_access" {
  name = "nhs-pipeline-s3-access"
  role = aws_iam_role.task_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.nhs_data.arn, "${aws_s3_bucket.nhs_data.arn}/*"]
    }]
  })
}

resource "aws_cloudwatch_log_group" "nhs_pipeline" {
  name              = "/ecs/nhs-ae-pipeline"
  retention_in_days = 14 # keep logs cheap - this isn't a compliance system
}

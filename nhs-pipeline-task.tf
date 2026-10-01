# ---------- Networking ----------
# Default VPC is fine here: this task makes outbound calls only (NHS England,
# ECR, S3, CloudWatch) and nothing calls it, so there's no case for a
# dedicated VPC on a monthly batch job.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "nhs_pipeline_task" {
  name        = "nhs-pipeline-task"
  description = "Outbound-only SG for the scheduled NHS pipeline Fargate task"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound - NHS England, ECR, S3, CloudWatch"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- ECS task definition ----------
resource "aws_ecs_task_definition" "nhs_pipeline" {
  family                   = "nhs-ae-pipeline"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"  # 0.5 vCPU - a monthly batch job over ~200 rows, not a hot path
  memory                   = "1024" # 1 GB - comfortable headroom for pandas + DuckDB at this data size
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture         = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "nhs-pipeline"
      image     = "${aws_ecr_repository.nhs_pipeline.repository_url}:latest"
      essential = true
      environment = [
        { name = "S3_BUCKET", value = aws_s3_bucket.nhs_data.bucket }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.nhs_pipeline.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# ---------- IAM: role EventBridge Scheduler assumes to call ecs:RunTask ----------
resource "aws_iam_role" "scheduler_execution" {
  name = "nhs-pipeline-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_run_task" {
  name = "nhs-pipeline-run-task"
  role = aws_iam_role.scheduler_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecs:RunTask"
        Resource = "${aws_ecs_task_definition.nhs_pipeline.arn_without_revision}:*"
        Condition = {
          ArnLike = { "ecs:cluster" = aws_ecs_cluster.nhs_pipeline.arn }
        }
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [aws_iam_role.task_execution.arn, aws_iam_role.task_role.arn]
      }
    ]
  })
}

# ---------- Schedule: monthly trigger ----------
# NHS England publishes each month's file ~6 weeks after month-end, landing
# around the 10th-14th of the month (checked against their own stats page).
# Running on the 20th leaves a buffer past that, including occasional late
# publications.
resource "aws_scheduler_schedule" "nhs_pipeline_monthly" {
  name                = "nhs-pipeline-monthly"
  schedule_expression = "cron(0 6 20 * ? *)" # 06:00 UTC on the 20th, every month

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_ecs_cluster.nhs_pipeline.arn
    role_arn = aws_iam_role.scheduler_execution.arn

    ecs_parameters {
      # No revision pinned, so the schedule always runs whatever revision is
      # currently active - a new image push doesn't require touching this.
      task_definition_arn = aws_ecs_task_definition.nhs_pipeline.arn_without_revision
      launch_type          = "FARGATE"

      network_configuration {
        subnets          = data.aws_subnets.default.ids
        security_groups  = [aws_security_group.nhs_pipeline_task.id]
        assign_public_ip = true # default-VPC subnets are public and there's no NAT gateway - this is how the task reaches the internet at all
      }
    }

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}

output "task_security_group_id" {
  value       = aws_security_group.nhs_pipeline_task.id
  description = "For manual ecs run-task testing - avoids AWS CLI filter syntax"
}

output "task_subnet_id" {
  value       = data.aws_subnets.default.ids[0]
  description = "For manual ecs run-task testing - avoids AWS CLI filter syntax"
}

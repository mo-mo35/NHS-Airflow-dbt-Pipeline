# ---------- Remote state ----------
# A GitHub Actions runner has no disk between jobs, so local state (what
# you've been using so far) would just vanish after every CI run. This
# bucket is what `terraform apply` reads/writes from instead, both locally
# and in CI, so they see the same state.
#
# Bootstrap order matters here: apply this file locally first (same as
# everything else so far, local state) - THEN add the backend block and
# migrate. See the migration steps in chat rather than in this file.

resource "aws_s3_bucket" "tfstate" {
  bucket = "nhs-pipeline-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # required for S3's native state locking, and lets you recover a previous state if an apply goes wrong
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "tfstate_bucket_name" {
  value       = aws_s3_bucket.tfstate.bucket
  description = "Use this exact name in the backend \"s3\" block, step 4"
}

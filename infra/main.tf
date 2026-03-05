terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Core AWS provider that manages Lambda, S3, Glue, Athena, etc.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.55"
    }
    # Random provider is used for suffixes so bucket names stay globally unique.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

# Configure the AWS provider once. Most resources inherit this region implicitly.
provider "aws" {
  region = var.aws_region
}

# Account context is used to scope IAM policy resources.
data "aws_caller_identity" "current" {}

locals {
  project_slug = lower(regexreplace(var.project_name, "[^A-Za-z0-9-]", "-"))
  # Glue databases require underscores, so adjust the project name accordingly.
  glue_db_name = lower(regexreplace(var.project_name, "[^A-Za-z0-9_]", "_"))
  # Resolve the Lambda package to an absolute path so Terraform tracks code changes.
  lambda_package_path = startswith(var.lambda_package, "/") ? var.lambda_package : abspath("${path.module}/${var.lambda_package}")
}

# ---------------------------------------------------------------------------
# S3 DATA LAKE: Buckets and folder structure for raw + processed datasets.
# ---------------------------------------------------------------------------

resource "random_string" "s3_suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

# ---------------------------------------------------------------------------
# S3 BUCKET FOR ATHENA RESULTS: Dedicated location for query output.
# ---------------------------------------------------------------------------

resource "random_string" "athena_suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

resource "aws_s3_bucket" "data_lake" {
  bucket = "${local.project_slug}-data-lake-${random_string.s3_suffix.result}"

  tags = merge(var.common_tags, {
    Purpose = "weather-data-lake"
  })
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  # Prevent accidental public exposure of the data lake contents.
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    # Default to SSE-S3 encryption for objects in the data lake.
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "data_lake_prefixes" {
  for_each = toset(["raw/", "processed/"])

  bucket       = aws_s3_bucket.data_lake.id
  key          = each.value
  content      = ""
  content_type = "application/x-directory"
}

resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.project_slug}-athena-${random_string.athena_suffix.result}"

  tags = merge(var.common_tags, {
    Purpose = "athena-query-results"
  })
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    # Encrypt Athena result objects by default.
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# IAM ROLES AND POLICIES: Lambda service role with S3 + Glue permissions.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name_prefix        = "${local.project_slug}-etl-"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = merge(var.common_tags, {
    Component = "etl-lambda"
  })
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid       = "AllowLogging"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
    ]
  }

  statement {
    sid     = "AllowS3DataLakeWrite"
    actions = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.data_lake.arn}/raw/*",
      "${aws_s3_bucket.data_lake.arn}/processed/*"
    ]
  }

  statement {
    sid     = "AllowS3DataLakeList"
    actions = ["s3:ListBucket"]
    resources = [
      aws_s3_bucket.data_lake.arn
    ]
  }

}

resource "aws_iam_policy" "lambda" {
  name_prefix = "${local.project_slug}-etl-"
  policy      = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_iam_role_policy_attachment" "lambda" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda.arn
}

# ---------------------------------------------------------------------------
# LAMBDA FUNCTION: Weather ETL orchestrator with EventBridge trigger.
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "etl_orchestrator" {
  function_name = "${local.project_slug}-etl-orchestrator"
  description   = "Fetches weather data and stores it to the data lake."
  filename      = local.lambda_package_path
  handler       = "app.lambda_handler"
  runtime       = "python3.11"
  role          = aws_iam_role.lambda.arn
  timeout       = 900
  memory_size   = 512
  publish       = true

  source_code_hash = filebase64sha256(local.lambda_package_path)

  environment {
    variables = merge(var.lambda_environment, {
      S3_BUCKET        = aws_s3_bucket.data_lake.bucket
      RAW_BUCKET       = aws_s3_bucket.data_lake.bucket
      RAW_PREFIX       = "raw"
      PROCESSED_BUCKET = aws_s3_bucket.data_lake.bucket
      PROCESSED_PREFIX = "processed"
      USE_PARQUET      = "false"
    })
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda
  ]

  tags = merge(var.common_tags, {
    Component = "etl-orchestrator"
  })
}

# EventBridge rule fires the Lambda on the defined schedule.
resource "aws_cloudwatch_event_rule" "etl_schedule" {
  name                = "${local.project_slug}-etl-schedule"
  schedule_expression = var.lambda_schedule_expression

  tags = merge(var.common_tags, {
    Component = "etl-schedule"
  })
}

# Associate the Lambda as the target invoked by the schedule above.
resource "aws_cloudwatch_event_target" "etl_target" {
  rule      = aws_cloudwatch_event_rule.etl_schedule.name
  target_id = "lambda"
  arn       = aws_lambda_function.etl_orchestrator.arn
}

# Permit EventBridge to call the Lambda when the schedule triggers.
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.etl_orchestrator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.etl_schedule.arn
}

# ---------------------------------------------------------------------------
# GLUE CATALOG + CRAWLER: Automatic schema discovery for the data lake.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name_prefix        = "${local.project_slug}-glue-"
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json

  tags = merge(var.common_tags, {
    Component = "glue"
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_s3_access" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.data_lake.arn,
      "${aws_s3_bucket.data_lake.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name   = "${local.project_slug}-glue-s3"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_s3_access.json
}

resource "aws_glue_catalog_database" "data_lake" {
  name = "${local.glue_db_name}_weather"

  description = "Weather pipeline curated database."

  tags = var.common_tags
}

resource "aws_glue_crawler" "data_lake" {
  name         = "${local.project_slug}-weather-crawler"
  database_name = aws_glue_catalog_database.data_lake.name
  role          = aws_iam_role.glue.arn
  schedule      = var.crawler_schedule_expression

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/processed/"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_EVERYTHING"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  depends_on = [
    aws_iam_role_policy_attachment.glue_service_role,
    aws_iam_role_policy.glue_s3_access,
    aws_s3_object.data_lake_prefixes
  ]

  tags = merge(var.common_tags, {
    Component = "glue-crawler"
  })
}

# ---------------------------------------------------------------------------
# ATHENA WORKGROUP: Dedicated space for querying weather analytics.
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "weather" {
  name = "${local.project_slug}_weather"

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
    }
  }

  tags = merge(var.common_tags, {
    Component = "athena"
  })
}

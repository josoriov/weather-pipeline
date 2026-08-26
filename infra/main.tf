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
  project_slug         = lower(join("", [for ch in regexall(".", var.project_name) : length(regexall("[A-Za-z0-9-]", ch)) > 0 ? ch : "-"]))
  lambda_function_name = "${local.project_slug}-etl-orchestrator"
  # Glue databases require underscores, so adjust the project name accordingly.
  glue_db_name = lower(join("", [for ch in regexall(".", var.project_name) : length(regexall("[A-Za-z0-9_]", ch)) > 0 ? ch : "_"]))
  # Resolve the Lambda package to an absolute path so Terraform tracks code changes.
  lambda_package_path = startswith(var.lambda_package, "/") ? var.lambda_package : abspath("${path.module}/${var.lambda_package}")
  # Project is mandatory for cost allocation; callers can add more dimensions.
  resource_tags = merge(var.common_tags, {
    Project = var.project_name
  })
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

  tags = merge(local.resource_tags, {
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

resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  # Keep versioning recoverable for a short period without retaining old
  # versions and abandoned uploads forever.
  rule {
    id     = "data-lake-housekeeping"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }

    expiration {
      expired_object_delete_marker = true
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  # Current-object retention is opt-in because enabling it can permanently
  # remove historical observations. See terraform.tfvars.example.
  dynamic "rule" {
    for_each = var.raw_retention_days == null ? [] : [var.raw_retention_days]
    iterator = raw_retention

    content {
      id     = "expire-raw-data"
      status = "Enabled"

      filter {
        prefix = "raw/"
      }

      expiration {
        days = raw_retention.value
      }
    }
  }

  dynamic "rule" {
    for_each = var.processed_retention_days == null ? [] : [var.processed_retention_days]
    iterator = processed_retention

    content {
      id     = "expire-processed-data"
      status = "Enabled"

      filter {
        prefix = "processed/"
      }

      expiration {
        days = processed_retention.value
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.data_lake]
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

  tags = merge(local.resource_tags, {
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

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-old-results"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

# ---------------------------------------------------------------------------
# IAM ROLES AND POLICIES: Lambda service role with logs + S3 write permissions.
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

  tags = merge(local.resource_tags, {
    Component = "etl-lambda"
  })
}

data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid     = "AllowLogging"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
    ]
  }

  statement {
    sid     = "AllowS3DataLakeWrite"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.data_lake.arn}/raw/*",
      "${aws_s3_bucket.data_lake.arn}/processed/*"
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

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = merge(local.resource_tags, {
    Component = "etl-lambda-logs"
  })
}

# ---------------------------------------------------------------------------
# LAMBDA FUNCTION: Weather ETL orchestrator with EventBridge trigger.
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "etl_orchestrator" {
  function_name                  = local.lambda_function_name
  description                    = "Fetches weather data and stores it to the data lake."
  filename                       = local.lambda_package_path
  handler                        = "app.lambda_handler"
  runtime                        = "python3.11"
  role                           = aws_iam_role.lambda.arn
  timeout                        = 900
  memory_size                    = 512
  reserved_concurrent_executions = var.execution_enabled ? -1 : 0
  publish                        = true
  layers                         = var.lambda_layer_arns

  source_code_hash = filebase64sha256(local.lambda_package_path)

  environment {
    variables = merge(
      var.lambda_environment,
      # Storage destinations and formats are managed by this stack and cannot
      # be overridden accidentally through the generic environment map.
      {
        USE_PARQUET      = tostring(var.use_parquet_output)
        S3_BUCKET        = aws_s3_bucket.data_lake.bucket
        RAW_BUCKET       = aws_s3_bucket.data_lake.bucket
        RAW_PREFIX       = "raw"
        PROCESSED_BUCKET = aws_s3_bucket.data_lake.bucket
        PROCESSED_PREFIX = "processed"
      }
    )
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda,
    aws_cloudwatch_log_group.lambda
  ]

  lifecycle {
    precondition {
      condition     = !var.use_parquet_output || length(var.lambda_layer_arns) > 0
      error_message = "use_parquet_output=true requires at least one PyArrow Lambda layer ARN."
    }
  }

  tags = merge(local.resource_tags, {
    Component = "etl-orchestrator"
  })
}

# EventBridge rule fires the Lambda on the defined schedule.
resource "aws_cloudwatch_event_rule" "etl_schedule" {
  name                = "${local.project_slug}-etl-schedule"
  schedule_expression = var.lambda_schedule_expression
  state               = var.execution_enabled ? "ENABLED" : "DISABLED"

  tags = merge(local.resource_tags, {
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
# GLUE CATALOG: Static schema + Athena partition projection.
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "data_lake" {
  name = "${local.glue_db_name}_weather"

  description = "Weather pipeline curated database."

  tags = local.resource_tags
}

resource "aws_glue_catalog_table" "processed" {
  name          = "${local.glue_db_name}_processed"
  database_name = aws_glue_catalog_database.data_lake.name
  table_type    = "EXTERNAL_TABLE"

  parameters = merge(
    {
      EXTERNAL                               = "TRUE"
      classification                         = var.use_parquet_output ? "parquet" : "csv"
      "projection.enabled"                   = "true"
      "projection.ingest_hour.type"          = "date"
      "projection.ingest_hour.format"        = "yyyy-MM-dd-HH"
      "projection.ingest_hour.range"         = "${var.partition_projection_start},NOW"
      "projection.ingest_hour.interval"      = "1"
      "projection.ingest_hour.interval.unit" = "HOURS"
      "storage.location.template"            = "s3://${aws_s3_bucket.data_lake.bucket}/processed/ingest_hour=$${ingest_hour}/"
    },
    var.use_parquet_output ? {} : { "skip.header.line.count" = "1" }
  )

  partition_keys {
    name = "ingest_hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.data_lake.bucket}/processed/"
    compressed    = var.use_parquet_output
    input_format  = var.use_parquet_output ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat" : "org.apache.hadoop.mapred.TextInputFormat"
    output_format = var.use_parquet_output ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat" : "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    columns {
      name = "city"
      type = "string"
    }
    columns {
      name = "latitude"
      type = "double"
    }
    columns {
      name = "longitude"
      type = "double"
    }
    columns {
      name = "ingest_ts_utc"
      type = "string"
    }
    columns {
      name = "ingest_ts_local"
      type = "string"
    }
    columns {
      name = "ingest_date_local"
      type = "string"
    }
    columns {
      name = "ingest_time_local"
      type = "string"
    }
    columns {
      name = "timezone"
      type = "string"
    }
    columns {
      name = "obs_ts_utc"
      type = "string"
    }
    columns {
      name = "obs_ts_local"
      type = "string"
    }
    columns {
      name = "obs_date_local"
      type = "string"
    }
    columns {
      name = "obs_time_local"
      type = "string"
    }
    columns {
      name = "temperature_2m"
      type = "double"
    }
    columns {
      name = "relative_humidity_2m"
      type = "double"
    }
    columns {
      name = "apparent_temperature"
      type = "double"
    }
    columns {
      name = "precipitation"
      type = "double"
    }
    columns {
      name = "rain"
      type = "double"
    }
    columns {
      name = "snowfall"
      type = "double"
    }
    columns {
      name = "weather_code"
      type = "double"
    }
    columns {
      name = "wind_speed_10m"
      type = "double"
    }
    columns {
      name = "wind_direction_10m"
      type = "double"
    }
    columns {
      name = "wind_gusts_10m"
      type = "double"
    }
    columns {
      name = "surface_pressure"
      type = "double"
    }
    columns {
      name = "pressure_msl"
      type = "double"
    }
    columns {
      name = "cloud_cover"
      type = "double"
    }
    columns {
      name = "dew_point_2m"
      type = "double"
    }
    columns {
      name = "visibility"
      type = "double"
    }
    columns {
      name = "is_day"
      type = "double"
    }

    ser_de_info {
      name                  = "${local.glue_db_name}_processed_serde"
      serialization_library = var.use_parquet_output ? "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe" : "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      parameters = var.use_parquet_output ? {} : {
        separatorChar = ","
        quoteChar     = "\""
        escapeChar    = "\\"
      }
    }
  }

  depends_on = [aws_s3_object.data_lake_prefixes]
}

# ---------------------------------------------------------------------------
# ATHENA WORKGROUP: Dedicated space for querying weather analytics.
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "weather" {
  name  = "${local.project_slug}_weather"
  state = var.execution_enabled ? "ENABLED" : "DISABLED"

  configuration {
    enforce_workgroup_configuration = true
    bytes_scanned_cutoff_per_query  = var.athena_bytes_scanned_cutoff_per_query

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
    }
  }

  tags = merge(local.resource_tags, {
    Component = "athena"
  })
}

# ---------------------------------------------------------------------------
# COST CONTROL: Optional project-scoped monthly budget and email alerts.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  count = var.budget_alert_email == null ? 0 : 1

  name         = "${local.project_slug}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Requires the user-defined Project tag to be activated as a cost allocation
  # tag in Billing. All supported resources in this stack receive this tag.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.project_name)]
  }

  dynamic "notification" {
    for_each = toset([50, 80, 100])

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}

resource "aws_ce_anomaly_monitor" "project" {
  count = var.budget_alert_email == null ? 0 : 1

  name         = "${local.project_slug}-cost-anomalies"
  monitor_type = "CUSTOM"
  monitor_specification = jsonencode({
    And            = null
    CostCategories = null
    Dimensions     = null
    Not            = null
    Or             = null
    Tags = {
      # Cost Explorer prefixes activated user-defined cost allocation tags.
      # Match the live monitor to avoid replacing this cost safeguard.
      Key          = "user:Project"
      MatchOptions = ["EQUALS"]
      Values       = [var.project_name]
    }
  })

  tags = local.resource_tags
}

resource "aws_ce_anomaly_subscription" "project" {
  count = var.budget_alert_email == null ? 0 : 1

  name             = "${local.project_slug}-cost-anomaly-alerts"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.project[0].arn]

  subscriber {
    type    = "EMAIL"
    address = var.budget_alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.cost_anomaly_threshold_usd)]
    }
  }

  tags = local.resource_tags
}

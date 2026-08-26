variable "project_name" {
  # High-level project identifier. This is normalized and reused for most
  # resource names so they are easy to locate across AWS services.
  description = "Project identifier used as a prefix for resource names."
  type        = string
  default     = "weather-pipeline"
}

variable "aws_region" {
  # Region all infrastructure will be provisioned into. Make sure it matches the
  # one used when packaging the Lambda artifact and managing secrets/parameters.
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "execution_enabled" {
  description = "Whether Lambda execution, its EventBridge schedule, and Athena queries are enabled."
  type        = bool
  default     = false
}

variable "lambda_package" {
  # Relative or absolute path to the zipped Lambda code artifact. The default
  # assumes the `scripts/package_lambda.sh` workflow stored the file in /dist.
  description = "Path to the zipped Lambda deployment package."
  type        = string
  default     = "../dist/function.zip"
}

variable "lambda_schedule_expression" {
  # EventBridge rate/cron expression that dictates how often the orchestrator
  # executes. Adjust to trade off freshness vs API usage.
  description = "EventBridge schedule expression that triggers the ETL Lambda."
  type        = string
  default     = "cron(0/15 * * * ? *)"
}

variable "lambda_environment" {
  # Optional environment variables to merge into the Lambda. Useful for API keys,
  # city lists, or feature toggles that differ by environment.
  description = "Additional environment variables for the ETL Lambda."
  type        = map(string)
  default     = {}
}

variable "lambda_layer_arns" {
  # Optional Lambda layers, such as a PyArrow layer when Parquet output is enabled.
  description = "Lambda layer ARNs attached to the ETL Lambda function."
  type        = list(string)
  default     = []
}

variable "use_parquet_output" {
  description = "Write processed batches as Parquet instead of CSV. Requires a PyArrow Lambda layer."
  type        = bool
  default     = false
}

variable "partition_projection_start" {
  description = "Oldest projected hourly partition, formatted as yyyy-MM-dd-HH in UTC."
  type        = string
  default     = "2026-01-01-00"

  validation {
    condition     = can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}$", var.partition_projection_start))
    error_message = "partition_projection_start must use yyyy-MM-dd-HH."
  }
}

variable "raw_retention_days" {
  description = "Days to retain current raw objects. Null disables destructive expiration."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition     = var.raw_retention_days == null ? true : (var.raw_retention_days >= 1 && floor(var.raw_retention_days) == var.raw_retention_days)
    error_message = "raw_retention_days must be null or a positive integer."
  }
}

variable "processed_retention_days" {
  description = "Days to retain current processed objects. Null disables destructive expiration."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition     = var.processed_retention_days == null ? true : (var.processed_retention_days >= 1 && floor(var.processed_retention_days) == var.processed_retention_days)
    error_message = "processed_retention_days must be null or a positive integer."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to retain noncurrent S3 object versions."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 1 && floor(var.noncurrent_version_retention_days) == var.noncurrent_version_retention_days
    error_message = "noncurrent_version_retention_days must be a positive integer."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Days before S3 aborts incomplete multipart uploads."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_upload_days >= 1 && floor(var.abort_incomplete_multipart_upload_days) == var.abort_incomplete_multipart_upload_days
    error_message = "abort_incomplete_multipart_upload_days must be a positive integer."
  }
}

variable "cloudwatch_log_retention_days" {
  description = "Retention period for Lambda CloudWatch logs."
  type        = number
  default     = 30
}

variable "athena_bytes_scanned_cutoff_per_query" {
  description = "Maximum bytes an Athena query may scan before it is cancelled."
  type        = number
  default     = 104857600

  validation {
    condition     = var.athena_bytes_scanned_cutoff_per_query >= 10485760
    error_message = "Athena's scan cutoff must be at least 10 MiB."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly project cost budget in USD, created when budget_alert_email is set."
  type        = number
  default     = 1

  validation {
    condition     = var.monthly_budget_usd >= 0.01
    error_message = "monthly_budget_usd must be at least 0.01."
  }
}

variable "budget_alert_email" {
  description = "Email for 50/80/100 percent budget alerts. Null disables budget creation."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.budget_alert_email == null ? true : can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be null or a valid email address."
  }
}

variable "cost_anomaly_threshold_usd" {
  description = "Absolute cost impact that triggers a daily anomaly email."
  type        = number
  default     = 0.5

  validation {
    condition     = var.cost_anomaly_threshold_usd >= 0
    error_message = "cost_anomaly_threshold_usd cannot be negative."
  }
}

variable "common_tags" {
  # Standard AWS tags propagated to supported resources. Set values such as
  # `Environment`, `Owner`, or `CostCenter` through Terraform variables.
  description = "Tags applied to all supported resources."
  type        = map(string)
  default     = {}
}

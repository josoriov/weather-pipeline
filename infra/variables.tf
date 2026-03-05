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
  default     = "rate(15 minutes)"
}

variable "crawler_schedule_expression" {
  # Glue crawler schedule used to refresh partitions/schema in the catalog.
  # This default runs every Sunday at 03:00 UTC.
  description = "Cron schedule for the weekly Glue crawler run."
  type        = string
  default     = "cron(0 3 ? * SUN *)"
}

variable "lambda_environment" {
  # Optional environment variables to merge into the Lambda. Useful for API keys,
  # city lists, or feature toggles that differ by environment.
  description = "Additional environment variables for the ETL Lambda."
  type        = map(string)
  default     = {}
}

variable "common_tags" {
  # Standard AWS tags propagated to supported resources. Set values such as
  # `Environment`, `Owner`, or `CostCenter` through Terraform variables.
  description = "Tags applied to all supported resources."
  type        = map(string)
  default     = {}
}

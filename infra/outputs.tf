# Outputs make it easy to integrate with other stacks or scripts and to inspect
# the resulting resource names after `terraform apply`.

output "lambda_function_name" {
  # Deployed function name for downstream integration or manual invocations.
  description = "Name of the ETL Lambda function."
  value       = aws_lambda_function.etl_orchestrator.function_name
}

output "lambda_role_arn" {
  # IAM role assumed by the Lambda. Useful if you need to attach extra policies.
  description = "IAM role ARN used by the ETL Lambda function."
  value       = aws_iam_role.lambda.arn
}

output "data_lake_bucket" {
  # Bucket used to land raw and processed weather data sets.
  description = "Primary S3 bucket for raw and processed weather data."
  value       = aws_s3_bucket.data_lake.bucket
}

output "athena_results_bucket" {
  # Separate bucket that receives Athena query results and metadata spills.
  description = "S3 bucket storing Athena query results."
  value       = aws_s3_bucket.athena_results.bucket
}

output "glue_database_name" {
  # Glue database name surfaced for building Athena/Glue jobs.
  description = "Glue Data Catalog database tracking the weather tables."
  value       = aws_glue_catalog_database.data_lake.name
}

output "glue_table_name" {
  description = "Projected Glue table used by Athena without a crawler."
  value       = aws_glue_catalog_table.processed.name
}

output "athena_workgroup" {
  # Workgroup pre-configured with result location for analytics queries.
  description = "Athena workgroup configured for weather analytics."
  value       = aws_athena_workgroup.weather.name
}

output "monthly_budget_name" {
  description = "Project budget name, or null when no alert email was configured."
  value       = try(aws_budgets_budget.monthly[0].name, null)
}

output "cost_anomaly_monitor_arn" {
  description = "Cost anomaly monitor ARN, or null when no alert email was configured."
  value       = try(aws_ce_anomaly_monitor.project[0].arn, null)
}

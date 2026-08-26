# Setup

This guide assumes the project code is complete and walks through building,
deploying, and verifying the Weather Pipeline from a fresh checkout.

## What This Builds

The setup provisions a serverless AWS weather data pipeline:

- AWS Lambda fetches current observations from Open-Meteo.
- S3 stores one gzipped raw batch and one processed batch per invocation.
- EventBridge can run the Lambda on a schedule when execution is enabled.
- A static Glue table uses hourly Athena partition projection; no crawler runs.
- Athena provides the query workgroup and result location when execution is enabled.
- S3 lifecycle, CloudWatch retention, scan limits and an optional budget cap costs.

Parquet output is optional and requires an additional PyArrow Lambda layer.

## Prerequisites

Install and configure these tools before starting:

| Tool      | Minimum             | Used for                                      |
|-----------|---------------------|-----------------------------------------------|
| Terraform | 1.5                 | AWS infrastructure provisioning               |
| AWS CLI   | v2                  | AWS authentication and manual verification    |
| Python    | 3.11                | Local tests and Lambda packaging              |
| uv        | any recent version  | Local dependency and mypy checks              |
| Docker    | any recent version  | Optional PyArrow layer build                  |

Configure AWS credentials for the target account:

```bash
aws configure
```

Or export credentials in your shell:

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"
```

The AWS identity must be able to manage Lambda, S3, IAM, Glue, Athena,
EventBridge, and CloudWatch Logs. Managing the optional alerts also requires
Budgets and Cost Explorer permissions.

## 1. Validate the Local Project

From the repository root:

```bash
uv sync
python3 -m unittest discover -s tests -p "test_*.py"
uv run mypy
terraform fmt -check -diff infra
```

These checks should pass before deployment.

## 2. Build the Lambda Package

Terraform deploys the Lambda artifact from `dist/function.zip`. Rebuild it before
each deployment, especially after changing anything under `lambda/`.

```bash
bash lambda/package_lambda.sh
```

The `dist/` directory is generated locally and ignored by Git.

## 3. Configure Terraform Variables

Create `infra/terraform.tfvars` for the target environment:

```hcl
project_name                = "weather-pipeline"
aws_region                  = "us-east-1"
execution_enabled           = false
lambda_schedule_expression  = "rate(15 minutes)"
lambda_environment          = {}
lambda_layer_arns           = []
use_parquet_output          = false

# Leave current-object expiration disabled until retention is approved.
raw_retention_days       = null
processed_retention_days = null

partition_projection_start            = "2026-01-01-00"
cloudwatch_log_retention_days          = 30
athena_bytes_scanned_cutoff_per_query  = 104857600
monthly_budget_usd                     = 1
budget_alert_email                     = null
cost_anomaly_threshold_usd             = 0.5

common_tags = {
  Environment = "dev"
  Owner       = "your-name"
  CostCenter  = "weather-data"
}
```

`terraform.tfvars` is ignored by Git so account-specific values stay local.
Set `execution_enabled = true` only when scheduled ingestion, Lambda invocation,
and Athena queries should be available.

## 4. Initialize and Validate Terraform

```bash
terraform -chdir=infra init
terraform -chdir=infra validate
```

After the first successful init, commit `infra/.terraform.lock.hcl` so provider
versions are reproducible across machines and CI.

## 5. Migrate an Existing Deployment

Skip this section for a new account. Existing deployments normally already have
the Lambda log group, but it was not previously managed by Terraform. Import it
before planning so Terraform does not try to recreate it:

```bash
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/weather-pipeline-etl-orchestrator"

terraform -chdir=infra import \
  aws_cloudwatch_log_group.lambda \
  "/aws/lambda/weather-pipeline-etl-orchestrator"
```

The migration intentionally destroys the scheduled Glue crawler and its IAM role,
then creates a static table named by `glue_table_name`. Existing objects and the
old crawler-created table are not deleted. New data uses:

```text
raw/ingest_hour=yyyy-MM-dd-HH/snapshot_<epoch>.json.gz
processed/ingest_hour=yyyy-MM-dd-HH/part-<epoch>.csv
```

Review these replacements carefully in the plan. Current raw and processed
objects do not expire while their retention variables remain `null`.

To enable the optional project budget and daily anomaly monitor, first activate
the `Project` cost tag, wait for AWS Billing to expose it, then set
`budget_alert_email`:

```bash
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=Project,Status=Active
```

## 6. Plan and Deploy

Review the plan before applying it:

```bash
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

With `execution_enabled = false`, the plan must keep the EventBridge rule and
Athena workgroup disabled and Lambda reserved concurrency at zero. Reject a plan
that enables any of those resources unexpectedly.

Save the important outputs:

```bash
terraform -chdir=infra output
```

## 7. Verify the Deployment

When `execution_enabled = false`, verify the halt controls:

```bash
aws events describe-rule --name weather-pipeline-etl-schedule --query State
aws lambda get-function-concurrency \
  --function-name weather-pipeline-etl-orchestrator
aws athena get-work-group --work-group weather-pipeline_weather \
  --query WorkGroup.State
```

The expected values are `DISABLED`, zero reserved concurrency, and `DISABLED`.
To validate data ingestion, first set `execution_enabled = true`, apply the
change, and then invoke the Lambda manually:

```bash
aws lambda invoke \
  --function-name "$(terraform -chdir=infra output -raw lambda_function_name)" \
  /tmp/weather-pipeline-response.json

cat /tmp/weather-pipeline-response.json
```

Confirm raw and processed objects were written:

```bash
aws s3 ls "s3://$(terraform -chdir=infra output -raw data_lake_bucket)/raw/" --recursive --summarize
aws s3 ls "s3://$(terraform -chdir=infra output -raw data_lake_bucket)/processed/" --recursive --summarize
```

Check recent Lambda logs in CloudWatch:

```bash
aws logs tail "/aws/lambda/$(terraform -chdir=infra output -raw lambda_function_name)" --since 30m
```

The invocation response must report 14 records and exactly one `raw` and one
`processed` key. Then query the projected table; no crawler is required:

```sql
SELECT *
FROM "<glue_database_name>"."<glue_table_name>"
WHERE ingest_hour >= date_format(current_timestamp - interval '1' day, '%Y-%m-%d-%H')
LIMIT 10;
```

Use these outputs to find the database and workgroup names:

```bash
terraform -chdir=infra output -raw glue_database_name
terraform -chdir=infra output -raw glue_table_name
terraform -chdir=infra output -raw athena_workgroup
```

If this was only a temporary validation, set `execution_enabled = false` again,
apply a reviewed plan, and confirm the halt state before leaving the environment.

## Optional: Enable Parquet Output

The default deployment writes processed CSV files. To write Parquet, build and
publish the PyArrow Lambda layer:

```bash
cd layer_build
./build_layer.sh
./publish_layer.sh
cd ..
```

Copy the layer version ARN returned by AWS and update `infra/terraform.tfvars`:

```hcl
lambda_layer_arns = ["arn:aws:lambda:<region>:<account-id>:layer:pyarrow-311:<version>"]
use_parquet_output = true
```

Rebuild the Lambda package if needed, then apply Terraform again:

```bash
bash lambda/package_lambda.sh
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

Invoke the Lambda and verify new objects under `processed/` end in `.parquet`.

## Operations

Useful commands after deployment:

```bash
terraform -chdir=infra output -raw lambda_function_name
terraform -chdir=infra output -raw data_lake_bucket
terraform -chdir=infra output -raw glue_table_name
terraform -chdir=infra output -raw athena_workgroup
```

The only managed scheduled workload is the Lambda. `execution_enabled = false`
disables its EventBridge rule, throttles the function to zero concurrency, and
disables the Athena workgroup. When execution is enabled,
`lambda_schedule_expression` controls the ingestion interval. Athena discovers
hourly partitions through table projection and does not require a scheduled
catalog job.

Use the same reviewed Terraform workflow for both state transitions:

```bash
# Set execution_enabled to false (halt) or true (resume) first.
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

Verify a halt after applying:

```bash
aws events describe-rule --name weather-pipeline-etl-schedule --query State
aws lambda get-function-concurrency \
  --function-name weather-pipeline-etl-orchestrator
aws athena get-work-group --work-group weather-pipeline_weather \
  --query WorkGroup.State
```

The account also contains an unmanaged legacy Lambda named `weather-pipeline`.
It has no trigger and is currently throttled to zero. Terraform does not manage
that safeguard, so verify it separately until the function is removed:

```bash
aws lambda get-function-concurrency --function-name weather-pipeline
```

For an emergency halt, block the live execution paths first and reconcile
Terraform immediately afterward:

```bash
aws events disable-rule --name weather-pipeline-etl-schedule
aws lambda put-function-concurrency \
  --function-name weather-pipeline-etl-orchestrator \
  --reserved-concurrent-executions 0
aws lambda put-function-concurrency \
  --function-name weather-pipeline \
  --reserved-concurrent-executions 0
aws athena update-work-group \
  --work-group weather-pipeline_weather \
  --state DISABLED
```

An invocation that is already running can finish; the managed function timeout
is 15 minutes. Keep both concurrency limits at zero, set
`execution_enabled = false`, and require a no-change Terraform plan before
considering the environment reconciled. These commands do not delete stored
data or disable the budget and anomaly alerts.

## Cost Baseline

Capture a before/after breakdown by usage type and operation. The optional bucket
argument adds current object metrics:

```bash
./scripts/cost_baseline.sh \
  2026-07-01 2026-08-01 \
  "$(terraform -chdir=infra output -raw data_lake_bucket)"
```

The fourth script argument is only for a historical deployment where the legacy
crawler still exists. The current deployment has no crawler.

Run it again after a complete billing month and compare S3 request usage and Glue
cost. Listing a bucket is itself a billable S3 operation, so use this diagnostic
only for periodic baselines.

## Teardown

S3 buckets must be emptied before destroying the stack, including versioned
objects and delete markers. The recursive commands below remove current objects
but are not sufficient by themselves for versioned history.

```bash
aws s3 rm "s3://$(terraform -chdir=infra output -raw data_lake_bucket)" --recursive
aws s3 rm "s3://$(terraform -chdir=infra output -raw athena_results_bucket)" --recursive
terraform -chdir=infra destroy
```

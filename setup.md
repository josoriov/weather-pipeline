# Setup

This guide assumes the project code is complete and walks through building,
deploying, and verifying the Weather Pipeline from a fresh checkout.

## What This Builds

The setup provisions a serverless AWS weather data pipeline:

- AWS Lambda fetches current observations from Open-Meteo.
- S3 stores gzipped raw JSON and processed CSV output by default.
- EventBridge runs the Lambda on a schedule.
- Glue crawls processed data for Athena.
- Athena provides the query workgroup and result location.

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
EventBridge, and CloudWatch Logs.

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
cd lambda
./package_lambda.sh
cd ..
```

The `dist/` directory is generated locally and ignored by Git.

## 3. Configure Terraform Variables

Create `infra/terraform.tfvars` for the target environment:

```hcl
project_name                = "weather-pipeline"
aws_region                  = "us-east-1"
lambda_schedule_expression  = "rate(15 minutes)"
crawler_schedule_expression = "cron(0 3 ? * SUN *)"

lambda_environment = {
  USE_PARQUET = "false"
}

lambda_layer_arns = []

common_tags = {
  Environment = "dev"
  Owner       = "your-name"
}
```

`terraform.tfvars` is ignored by Git so account-specific values stay local.

## 4. Initialize and Validate Terraform

```bash
terraform -chdir=infra init
terraform -chdir=infra validate
```

After the first successful init, commit `infra/.terraform.lock.hcl` so provider
versions are reproducible across machines and CI.

## 5. Plan and Deploy

Review the plan before applying it:

```bash
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

Save the important outputs:

```bash
terraform -chdir=infra output
```

## 6. Verify the Deployment

Invoke the Lambda manually:

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

## 7. Build the Glue Catalog and Query Athena

Run the Glue crawler once after processed data exists:

```bash
aws glue start-crawler \
  --name "$(terraform -chdir=infra output -raw glue_crawler_name)"
```

Wait for the crawler to finish:

```bash
aws glue get-crawler \
  --name "$(terraform -chdir=infra output -raw glue_crawler_name)" \
  --query "Crawler.State"
```

Then open Athena, select the workgroup from Terraform output, and run a sample
query against the discovered table:

```sql
SELECT *
FROM "<glue_database_name>"."<processed_table_name>"
LIMIT 10;
```

Use these outputs to find the database and workgroup names:

```bash
terraform -chdir=infra output -raw glue_database_name
terraform -chdir=infra output -raw athena_workgroup
```

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

lambda_environment = {
  USE_PARQUET = "true"
}
```

Rebuild the Lambda package if needed, then apply Terraform again:

```bash
cd lambda
./package_lambda.sh
cd ..
terraform -chdir=infra plan -out=tfplan
terraform -chdir=infra apply tfplan
```

Invoke the Lambda and verify new objects under `processed/` end in `.parquet`.

## Operations

Useful commands after deployment:

```bash
terraform -chdir=infra output -raw lambda_function_name
terraform -chdir=infra output -raw data_lake_bucket
terraform -chdir=infra output -raw glue_crawler_name
terraform -chdir=infra output -raw athena_workgroup
```

The EventBridge schedule is controlled by `lambda_schedule_expression`. The Glue
crawler schedule is controlled by `crawler_schedule_expression`.

## Teardown

S3 buckets must be emptied before destroying the stack, including versioned
objects.

```bash
aws s3 rm "s3://$(terraform -chdir=infra output -raw data_lake_bucket)" --recursive
aws s3 rm "s3://$(terraform -chdir=infra output -raw athena_results_bucket)" --recursive
terraform -chdir=infra destroy
```

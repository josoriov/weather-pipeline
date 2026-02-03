# Weather Pipeline

Infrastructure-as-code and Lambda ETL to collect near-real-time weather metrics,
persist the raw/processed payloads, and expose the data through AWS analytics
services.

## Repository Layout
- `lambda/` – Python Lambda handler (`app.py`) plus helper packaging script.
- `dist/` – Deployment artifacts produced by packaging the Lambda or Lambda layer.
- `infra/` – Terraform modules that provision the full pipeline (S3, Glue, Athena, scheduling, IAM).
- `sql/`, `data/`, `logs/`, `tests/` – Supporting assets for experimentation and validation.

## Prerequisites
Before deploying, ensure you have:
- Terraform >= 1.5 installed locally.
- AWS CLI configured with credentials that can administer Lambda, S3, Glue, and Athena.
- Python 3.11 (matching the Lambda runtime) if you plan to edit or repackage the function.

Export AWS credentials (for example with `aws configure`) so Terraform can assume the desired IAM identity.

## Package the Lambda Function
If you update `lambda/app.py`, rebuild the deployment artifact so Terraform uploads fresh code:

```bash
cd lambda
./package_lambda.sh    # outputs ../dist/function.zip
```

The Terraform stack reads the archive from `dist/function.zip` by default. Update `infra/terraform.tfvars` or `-var lambda_package=...` if you store the bundle elsewhere.

## Deploy with Terraform
Run the following from the `infra/` directory:

```bash
cd infra
terraform init                    # downloads providers and initializes state
terraform fmt                     # optional formatting pass
terraform plan -out=tfplan        # review changes
terraform apply tfplan            # create / update resources
```

You can override default variables via CLI flags or `infra/terraform.tfvars`, for example:

```hcl
project_name            = "weather-pipeline-dev"
aws_region              = "us-west-2"
lambda_schedule_expression = "rate(15 minutes)"
lambda_environment = {
  CITY_LIST = "London,New York,Tokyo"
  API_KEY   = "replace-with-your-key"
}
common_tags = {
  Environment = "dev"
  Owner       = "data-eng"
}
```

## Post-Deployment Tasks
1. **Verify Lambda Execution** – Use the AWS Console or `aws lambda invoke` to confirm the function runs and drops files into the `raw/` prefix of the data lake bucket.
2. **Glue Crawler** – The Terraform-created crawler can be started manually (`aws glue start-crawler --name <output>`) or triggered by the Lambda when data lands, updating the catalog schema automatically.
3. **Athena Queries** – Point Athena to the workgroup output by Terraform and query tables discovered by Glue. The query results are stored automatically in the dedicated Athena results bucket.

To tear everything down later, run `terraform destroy` from the `infra/` directory (ensure S3 buckets are empty or versioning objects are removed before this succeeds).

## Troubleshooting
- `terraform fmt` missing? Install Terraform from <https://developer.hashicorp.com/terraform/downloads>.
- Lambda deployment fails with `AccessDenied`? Verify the IAM identity used for Terraform has sufficient permissions to manage Lambda, IAM, S3, Glue, and Athena.
- Glue crawler errors about access? Check the `aws_iam_role.glue` policy in Terraform and confirm the bucket ARN matches the deployed data lake bucket.

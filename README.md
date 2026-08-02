# Weather Pipeline

Serverless ETL pipeline that collects near-real-time weather observations from the
[Open-Meteo API](https://open-meteo.com/) for 14 cities worldwide, stores
raw and processed datasets in an S3 data lake, and exposes the data through
AWS Glue and Athena for analytics.

## Architecture

```
Open-Meteo API  ──▶  AWS Lambda (Python 3.11)  ──▶  S3 Data Lake
                           │                          ├── raw/ (1 gzip batch/run)
                       EventBridge                    └── processed/ (1 batch/run)
                      (every 15 min)                          │
                                                  Projected Glue table
                                                   (no scheduled crawler)
                                                              │
                                                         Athena ─▶ queries
```

**Cities tracked:** Berlin, Madrid, Regensburg, Paris, London, New York, Toronto,
Buenos Aires, Bogota, CDMX, Cali, Medellin, Tokyo, Sydney.

**Weather fields (16):** temperature, apparent temperature, humidity, precipitation,
rain, snowfall, weather code, wind speed/direction/gusts, surface & sea-level
pressure, cloud cover, dew point, visibility, is_day.

## Repository Layout

| Path | Description |
|------|-------------|
| `lambda/` | Python Lambda handler (`app.py`) and packaging script |
| `infra/` | Terraform stack — S3, Lambda, IAM, EventBridge, Glue, Athena |
| `tests/` | Unit tests for the Lambda handler |
| `data/` | Sample city coordinates (`cities.json`) |
| `layer_build/` | Scripts to build and publish a PyArrow Lambda layer |
| `scripts/` | Exploratory Jupyter notebook used during prototyping |
| `dist/` | Build artifacts (generated — not committed) |

## Current Status

| Component | Status |
|-----------|--------|
| Lambda ETL function | **Complete** — batches 14 cities into two S3 objects per invocation |
| Terraform infrastructure | **Defined** — S3 lifecycle, Lambda, EventBridge, projected Glue table, Athena, logs and optional budget |
| Local checks | **Passing** — unit tests, mypy, and Terraform formatting |
| Terraform validation | **Passing** — validated with Terraform 1.15.4 and AWS provider 5.100.0 |
| Lambda deployment package | **Generated locally** — `dist/function.zip` is ignored by Git and should be rebuilt before deploy |
| PyArrow Lambda layer | **Optional, not built** — scripts target Python 3.11 and Terraform accepts layer ARNs |
| CI/CD pipeline | **Not implemented** |
| Cost controls | **Defined** — 30-day logs, Athena scan cutoff, version cleanup and optional retention/budget |

See [setup.md](setup.md) for the end-to-end build and deployment guide, and
[TODO.md](TODO.md) for the current repo state and remaining work.

## Prerequisites

- **Terraform** >= 1.5
- **AWS CLI** v2 configured with credentials for Lambda, S3, IAM, Glue, Athena, and EventBridge
- **Python** 3.11 (matching the Lambda runtime)
- **uv** *(optional)* — for local dependency management via `pyproject.toml`

## Quick Start

### 1. Package the Lambda

Rebuild the deployment artifact whenever `lambda/app.py` changes:

```bash
bash lambda/package_lambda.sh # outputs dist/function.zip
```

### 2. Deploy with Terraform

```bash
cd infra
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Override defaults by creating `infra/terraform.tfvars`:

```hcl
project_name               = "weather-pipeline-dev"
aws_region                 = "us-west-2"
lambda_schedule_expression = "rate(15 minutes)"
lambda_environment         = {}
lambda_layer_arns          = []
use_parquet_output         = false
raw_retention_days         = null # Set to 90 only after approving deletion.
budget_alert_email         = null # Set after activating the Project cost tag.
common_tags = {
  Environment = "dev"
  Owner       = "data-eng"
}
```

### 3. Verify

```bash
# Invoke Lambda manually
aws lambda invoke \
  --function-name $(terraform -chdir=infra output -raw lambda_function_name) \
  /dev/stdout

terraform -chdir=infra output -raw glue_table_name
```

Then query the data in Athena using the workgroup created by Terraform.

## Parquet Support (Optional)

The Lambda defaults to **CSV** output. To enable Parquet you need a PyArrow Lambda
layer. The build scripts in `layer_build/` target the Lambda Python 3.11 runtime:

```bash
cd layer_build
./build_layer.sh       # requires Docker
./publish_layer.sh     # publishes to AWS
```

After publishing, set the layer ARN and enable Parquet in `infra/terraform.tfvars`:

```hcl
lambda_layer_arns = ["arn:aws:lambda:<region>:<account-id>:layer:pyarrow-311:<version>"]
use_parquet_output = true
```

## Run Tests

```bash
python3 -m unittest discover -s tests -p "test_*.py"
```

With `uv`:

```bash
uv sync
python3 -m unittest discover -s tests -p "test_*.py"
uv run mypy
```

Terraform checks:

```bash
terraform fmt -check -diff infra
terraform -chdir=infra init
terraform -chdir=infra validate
```

## Teardown

```bash
cd infra
terraform destroy
```

> S3 buckets must be emptied (including versioned objects) before `terraform destroy`
> can succeed.

## Troubleshooting

- **`AccessDenied` during deploy** — verify the IAM identity used by Terraform has
  permissions for Lambda, IAM, S3, Glue, Athena, and EventBridge.
- **No rows in Athena** — filter `ingest_hour` within the projected range and verify
  objects exist under `processed/ingest_hour=yyyy-MM-dd-HH/`.
- **Log group already exists** — import it before the first apply; see
  [setup.md](setup.md#5-migrate-an-existing-deployment).
- **Lambda timeout** — the function has a 15-minute timeout and 512 MB memory;
  increase via Terraform variables if needed.

## License

This project is licensed under the GNU General Public License v3. See [LICENSE](LICENSE).

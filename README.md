# Weather Pipeline

[![CI](https://github.com/josoriov/weather-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/josoriov/weather-pipeline/actions/workflows/ci.yml)

Serverless ETL pipeline that collects near-real-time weather observations from the
[Open-Meteo API](https://open-meteo.com/) for 14 cities worldwide, stores
raw and processed datasets in an S3 data lake, and exposes the data through
AWS Glue and Athena for analytics.

## Architecture

![Weather Pipeline architecture: EventBridge invokes Lambda, which fetches Open-Meteo observations and writes raw and processed batches to S3. Athena reads processed data using Glue metadata and writes to a separate results bucket.](docs/assets/weather-pipeline.svg)

[Interactive architecture diagram](.archify/architecture-weather-pipeline-20261005-160328/weather-pipeline.html)
— download the HTML and open it in a browser to explore source references,
switch between light and dark themes, and export portfolio images.

When execution is enabled, EventBridge invokes Lambda every 15 minutes by default.
Lambda fetches each city's observations, normalizes timestamps, and writes one
compressed JSON batch plus one CSV batch (or optional Parquet) per successful run.
Both datasets use UTC hourly partitions in the same private, encrypted S3 bucket.
Glue supplies the static schema and partition projection; Athena reads
`processed/` directly and writes query output to a separate bucket.

**Execution is disabled by default:** `execution_enabled = false` disables the
schedule and Athena workgroup and sets Lambda reserved concurrency to zero.
The diagram shows the configured execution paths when enabled; it does not imply
that the pipeline is currently running.

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
| `docs/` | Architecture SVG preview, operational notes, and resolved incident documentation |
| `.archify/` | Diagram specification and interactive HTML; local validation evidence is ignored |
| `tests/` | Unit tests for the Lambda handler |
| `data/` | Canonical city coordinates and timezones (`cities.json`), bundled into the Lambda package |
| `layer_build/` | Scripts to build and publish a PyArrow Lambda layer |
| `scripts/` | Exploratory Jupyter notebook used during prototyping |
| `dist/` | Build artifacts (generated — not committed) |

## Current Status

| Component | Status |
|-----------|--------|
| Lambda ETL function | **Complete** — batches 14 cities into two S3 objects per invocation |
| Live execution | **Halted** — EventBridge and Athena are disabled; managed and legacy Lambdas have zero reserved concurrency |
| Terraform infrastructure | **Reconciled** — live plan reported no changes on 2026-08-26 |
| Glue catalog | **Cost optimized** — static projected table; no crawler, crawler schedule, or crawler IAM role |
| Local checks | **Passing** — unit tests, mypy, and Terraform formatting |
| Terraform validation | **Passing** — validated with Terraform 1.15.4 and AWS provider 6.67.0 |
| Lambda deployment package | **Generated locally** — `dist/function.zip` is ignored by Git and should be rebuilt before deploy |
| PyArrow Lambda layer | **Optional, not built** — scripts target Python 3.11 and Terraform accepts layer ARNs |
| CI/CD pipeline | **GitHub Actions** — unit tests, mypy, Terraform fmt/validate |
| Cost controls | **Active** — 30-day logs, Athena scan cutoff, version cleanup, USD 1.50 monthly budget, and anomaly alerts |

See [setup.md](setup.md) for the end-to-end build and deployment guide, and
[TODO.md](TODO.md) for the current repo state.

## Prerequisites

- **Terraform** >= 1.5
- **AWS CLI** v2 configured with credentials for Lambda, S3, IAM, Glue, Athena,
  EventBridge, and—when cost alerts are managed—Budgets and Cost Explorer
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
execution_enabled          = false # Set true only when the pipeline should run.
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

`execution_enabled = false` is the default safety state: it disables the
EventBridge rule, sets Lambda reserved concurrency to zero, and disables the
Athena workgroup without removing data or cost controls.

### 3. Verify

With the default halted configuration, verify the controls instead of invoking
the function:

```bash
aws events describe-rule --name weather-pipeline-etl-schedule --query State
aws lambda get-function-concurrency \
  --function-name weather-pipeline-etl-orchestrator
aws athena get-work-group --work-group weather-pipeline_weather \
  --query WorkGroup.State
terraform -chdir=infra output -raw glue_table_name
```

Set `execution_enabled = true` before invoking Lambda or querying Athena.

## Halt and Resume

`execution_enabled` is the Terraform source of truth for the managed execution
paths. Keep it `false` to preserve the current halt. Changing it does not delete
S3 objects, the projected Glue table, logs, IAM roles, budgets, or anomaly alerts.

To resume intentionally, set it to `true`, review `terraform plan`, and apply.
To halt again, set it to `false` and repeat the reviewed plan/apply workflow.

An older unmanaged Lambda named `weather-pipeline` also exists in the deployed
account. It has no configured trigger and is independently held at zero reserved
concurrency; keep that limit in place until the legacy function is decommissioned.

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
> can succeed. A recursive `aws s3 rm` removes current objects only; versions and
> delete markers require version-aware cleanup.

## Troubleshooting

- **`AccessDenied` during deploy** — verify the IAM identity used by Terraform has
  permissions for Lambda, IAM, S3, Glue, Athena, and EventBridge.
- **No rows in Athena** — filter `ingest_hour` within the projected range and verify
  objects exist under `processed/ingest_hour=yyyy-MM-dd-HH/`.
- **Duplicate columns in Athena** — this was a legacy crawler issue; see the
  [resolved metadata note](docs/athena-duplicate-columns.md).
- **Log group already exists** — import it before the first apply; see
  [setup.md](setup.md#5-migrate-an-existing-deployment).
- **Lambda timeout** — the function has a 15-minute timeout and 512 MB memory;
  increase via Terraform variables if needed.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).

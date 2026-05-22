# TODO

Last reviewed: 2026-05-12

## Current State

- Lambda ETL code is implemented for 14 cities. It writes gzipped raw JSON and processed CSV by default, with optional Parquet support when PyArrow is available.
- Terraform defines the AWS stack: S3 data lake, Lambda, IAM, EventBridge schedule, Glue crawler/catalog, and Athena workgroup.
- Local validation is green for unit tests, mypy, and Terraform formatting:
  - `python3 -m unittest discover -s tests -p "test_*.py"`
  - `uv run mypy`
  - `terraform fmt -check -diff infra`
- `dist/function.zip` has been rebuilt locally from the current `lambda/app.py`, but `dist/` is ignored by Git and should be treated as a generated deployment artifact.
- Terraform has not been initialized in this checkout. `terraform validate` currently stops because the AWS and random providers have not been installed yet.
- No local Terraform state is present under `infra/`, so an AWS deployment has not been confirmed from this checkout.
- The PyArrow layer scripts target Python 3.11, matching the Lambda runtime, but the layer artifact has not been built or published.

## Remaining Work

- [ ] Run `terraform -chdir=infra init` to install providers and generate `infra/.terraform.lock.hcl`.
- [ ] Commit `infra/.terraform.lock.hcl` after Terraform initialization so provider selections are reproducible.
- [ ] Run `terraform -chdir=infra validate` after initialization.
- [ ] Run `terraform -chdir=infra plan -out=tfplan` with the target AWS account and review the planned resources.
- [ ] Apply the Terraform stack once AWS credentials, region, and project variables are confirmed.
- [ ] Invoke the deployed Lambda manually and verify objects are written under both `raw/` and `processed/` in S3.
- [ ] Check CloudWatch Logs after the first Lambda invocation and confirm the EventBridge schedule is enabled.
- [ ] Run the Glue crawler once after processed data exists, then verify tables and a sample query in Athena.
- [ ] Decide whether to keep CSV as the production format or enable Parquet.
- [ ] If enabling Parquet, build and publish the PyArrow layer, set `lambda_layer_arns`, set `USE_PARQUET=true`, and re-apply Terraform.
- [ ] Add CI for unit tests, mypy, Terraform formatting, and Terraform validation.
- [ ] Decide whether `data/cities.json` is only sample data or should become the source of truth for the Lambda city list.

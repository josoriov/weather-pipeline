# TODO

Last reviewed: 2026-08-02

## Current State

- Lambda ETL batches all successful cities into one raw and one processed object per invocation.
- Processed data includes `city` as a column and uses one hourly `ingest_hour` partition.
- Terraform replaces the scheduled Glue crawler with a static projected table.
- Cost controls include S3 housekeeping, optional current-data retention, 30-day logs,
  an Athena scan cutoff, mandatory project tags, and an optional USD 1 budget.
- Local validation commands:
  - `python3 -m unittest discover -s tests -p "test_*.py"`
  - `uv run mypy`
  - `terraform fmt -check -diff infra`
- `dist/function.zip` is ignored by Git and must be rebuilt before planning.
- Local Terraform state is ignored by Git and may describe an existing AWS deployment;
  always inspect the plan rather than treating repository documentation as live state.
- The cost-remediation stack was deployed and verified in AWS on 2026-08-02:
  the Lambda returned 14 records, Athena read 14 cities from the projected table,
  and the final Terraform plan reported no drift.
- The PyArrow layer scripts target Python 3.11, matching the Lambda runtime, but the layer artifact has not been built or published.

## Remaining Work

- [x] Use Terraform >= 1.5 for the migration.
- [x] Import the existing Lambda CloudWatch log group before the migration plan.
- [x] Run `terraform -chdir=infra validate` and review the crawler/IAM removals.
- [x] Apply the stack and confirm the final plan has no drift.
- [x] Invoke Lambda manually and verify `records=15` plus one raw and one processed key.
- [x] Check CloudWatch Logs after the first Lambda invocation and confirm the EventBridge schedule is enabled.
- [x] Query the projected table with an `ingest_hour` predicate and verify all 14 cities.
- [ ] Activate the `Project` cost allocation tag and configure `budget_alert_email`.
- [ ] Approve a raw retention period, then set `raw_retention_days` (recommended: 90).
- [ ] Compare S3 and Glue costs after one complete billing month.
- [ ] Decide whether to keep CSV as the production format or enable Parquet.
- [ ] If enabling Parquet, build and publish the PyArrow layer, set `lambda_layer_arns`, set `use_parquet_output=true`, and re-apply Terraform.
- [ ] Add CI for unit tests, mypy, Terraform formatting, and Terraform validation.
- [ ] Decide whether `data/cities.json` is only sample data or should become the source of truth for the Lambda city list.

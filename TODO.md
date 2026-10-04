# TODO

## Current State

- Lambda ETL batches all successful cities into one raw and one processed object per invocation.
- Processed data includes `city` as a column and uses one hourly `ingest_hour` partition.
- Terraform manages a static projected Glue table; the former crawler and its
  schedule/IAM role have been removed.
- Cost controls include S3 housekeeping, optional current-data retention, 30-day logs,
  an Athena scan cutoff, mandatory project tags, a USD 1.50 monthly budget, and
  daily anomaly alerts.
- Execution is intentionally halted through `execution_enabled=false`: the
  EventBridge rule and Athena workgroup are disabled, and the managed Lambda has
  zero reserved concurrency.
- A legacy unmanaged Lambda named `weather-pipeline` has no trigger and is also
  held at zero reserved concurrency pending decommissioning.
- Local validation commands:
  - `python3 -m unittest discover -s tests -p "test_*.py"`
  - `uv run mypy`
  - `terraform fmt -check -diff infra`
- `dist/function.zip` is ignored by Git and must be rebuilt before planning.
- Local Terraform state is ignored by Git and may describe an existing AWS deployment;
  always inspect the plan rather than treating repository documentation as live state.
- The cost-remediation stack was deployed and verified in AWS on 2026-08-02:
  the Lambda returned 14 records, Athena read 14 cities from the projected table,
  and the final Terraform plan reported no drift. After reconciling the halt on
  2026-08-26, a refreshed live plan again reported no changes.
- The PyArrow layer scripts target Python 3.11, matching the Lambda runtime, but the layer artifact has not been built or published.

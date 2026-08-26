# Resolved Athena Duplicate-Column Metadata

Status: resolved by the cost-optimization migration on 2026-08-02.

## Original Symptom

The legacy crawler-created table failed with duplicate column metadata:

```sql
SELECT * FROM "weather_pipeline_weather"."processed" LIMIT 10;
```

```text
HIVE_INVALID_METADATA: Hive metadata for table processed is invalid:
Table descriptor contains duplicate columns
Query ID: ee7794f8-1dfa-4c82-97d4-cabb68865c87
```

## Resolution

The crawler and its IAM role were removed. Terraform now owns a static table
named `weather_pipeline_processed`; `city` is a regular data column and
`ingest_hour` is the only projected partition key. No crawler run is required.

When `execution_enabled = true`, validate the current table with a bounded
partition query:

```sql
SELECT *
FROM "weather_pipeline_weather"."weather_pipeline_processed"
WHERE ingest_hour >= date_format(
  current_timestamp - interval '1' day,
  '%Y-%m-%d-%H'
)
LIMIT 10;
```

The deployed Athena workgroup is currently disabled as part of the infrastructure
halt. Do not enable it solely to retest this historical error.

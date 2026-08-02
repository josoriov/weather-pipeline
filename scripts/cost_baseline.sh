#!/usr/bin/env bash
set -euo pipefail

if (( $# < 2 || $# > 4 )); then
  echo "Usage: $0 START_DATE END_DATE [DATA_LAKE_BUCKET] [LEGACY_CRAWLER_NAME]" >&2
  echo "Dates use YYYY-MM-DD and END_DATE is exclusive." >&2
  exit 2
fi

start_date="$1"
end_date="$2"
data_lake_bucket="${3:-}"
legacy_crawler_name="${4:-}"

service_filter='{"Dimensions":{"Key":"SERVICE","Values":["Amazon Simple Storage Service","AWS Glue"]}}'

echo "Cost by service and usage type"
aws ce get-cost-and-usage \
  --time-period "Start=${start_date},End=${end_date}" \
  --granularity MONTHLY \
  --metrics UnblendedCost UsageQuantity \
  --filter "${service_filter}" \
  --group-by Type=DIMENSION,Key=SERVICE Type=DIMENSION,Key=USAGE_TYPE \
  --output table

echo "Cost by service and operation"
aws ce get-cost-and-usage \
  --time-period "Start=${start_date},End=${end_date}" \
  --granularity MONTHLY \
  --metrics UnblendedCost UsageQuantity \
  --filter "${service_filter}" \
  --group-by Type=DIMENSION,Key=SERVICE Type=DIMENSION,Key=OPERATION \
  --output table

if [[ -n "${data_lake_bucket}" ]]; then
  echo "Current S3 object count and logical size"
  aws s3 ls "s3://${data_lake_bucket}" --recursive --summarize

  echo "Incomplete multipart uploads"
  aws s3api list-multipart-uploads \
    --bucket "${data_lake_bucket}" \
    --query '{count:length(Uploads),uploads:Uploads[].{key:Key,initiated:Initiated}}'
fi

if [[ -n "${legacy_crawler_name}" ]]; then
  echo "Legacy Glue crawler metrics"
  aws glue get-crawler-metrics --crawler-name-list "${legacy_crawler_name}"
fi

import csv
import datetime as dt
import gzip
import io
import json
import os
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Optional
from zoneinfo import ZoneInfo

try:
    import boto3
except ImportError:  # pragma: no cover - local test environments may not ship boto3.
    boto3 = None

try:
    import pyarrow as pa
    import pyarrow.parquet as pq
except ImportError:  # pragma: no cover - Lambda can run in CSV mode without pyarrow.
    pa = None
    pq = None

CURRENT_FIELDS = [
    "temperature_2m",
    "relative_humidity_2m",
    "apparent_temperature",
    "precipitation",
    "rain",
    "snowfall",
    "weather_code",
    "wind_speed_10m",
    "wind_direction_10m",
    "wind_gusts_10m",
    "surface_pressure",
    "pressure_msl",
    "cloud_cover",
    "dew_point_2m",
    "visibility",
    "is_day",
]

CITY_COORDS: dict[str, tuple[float, float, str]] = {
    "Berlin": (52.52, 13.405, "Europe/Berlin"),
    "Madrid": (40.4168, -3.7038, "Europe/Madrid"),
    "Regensburg": (49.0134, 12.1016, "Europe/Berlin"),
    "Bogota": (4.711, -74.0721, "America/Bogota"),
    "CDMX": (19.4326, -99.1332, "America/Mexico_City"),
    "Cali": (3.4516, -76.532, "America/Bogota"),
    "Medellin": (6.2442, -75.5812, "America/Bogota"),
    "Paris": (48.8566, 2.3522, "Europe/Paris"),
    "New York": (40.7128, -74.006, "America/New_York"),
    "Buenos Aires": (-34.6037, -58.3816, "America/Argentina/Buenos_Aires"),
    "London": (51.5074, -0.1278, "Europe/London"),
    "Tokyo": (35.6895, 139.6917, "Asia/Tokyo"),
    "Toronto": (43.6511, -79.3839, "America/Toronto"),
    "Sydney": (-33.8688, 151.2093, "Australia/Sydney"),
}

class MissingS3Client:
    def put_object(self, **_: Any) -> None:
        """Fail fast when boto3 is unavailable in the runtime environment."""
        raise RuntimeError("boto3 is required to upload objects to S3")


S3: Any = None


def get_s3_client() -> Any:
    """Create the S3 client on first use instead of during module import."""
    global S3
    if S3 is None:
        S3 = boto3.client("s3") if boto3 is not None else MissingS3Client()
    return S3


@dataclass(frozen=True)
class RuntimeConfig:
    """Runtime settings derived from environment variables."""

    raw_bucket: str
    raw_prefix: str
    processed_bucket: str
    processed_prefix: str
    use_parquet: bool


def normalize_prefix(prefix: str) -> str:
    """Normalize an S3 prefix by removing leading and trailing slashes.

    Args:
        prefix: Raw prefix value from configuration.

    Returns:
        Prefix with surrounding "/" removed, preserving inner path separators.
    """
    return prefix.strip("/")


def str_to_bool(raw: Optional[str], default: bool = False) -> bool:
    """Parse a string flag into a boolean.

    Args:
        raw: String representation of a boolean value, usually from env vars.
        default: Value returned when ``raw`` is ``None``.

    Returns:
        ``True`` for ``1/true/yes/on`` (case-insensitive), else ``False``.
    """
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def load_runtime_config() -> RuntimeConfig:
    """Build runtime configuration from environment variables.

    Expected variables:
    - ``RAW_BUCKET`` (or legacy ``S3_BUCKET``)
    - ``PROCESSED_BUCKET`` (defaults to raw bucket)
    - ``RAW_PREFIX`` (defaults to ``raw``)
    - ``PROCESSED_PREFIX`` (defaults to ``processed``)
    - ``USE_PARQUET`` (optional boolean flag)

    Returns:
        Parsed and normalized runtime configuration.

    Raises:
        ValueError: If the required bucket configuration is missing.
    """
    # Keep backward compatibility with the old single-bucket env var naming.
    raw_bucket = os.environ.get("RAW_BUCKET") or os.environ.get("S3_BUCKET")
    processed_bucket = os.environ.get("PROCESSED_BUCKET") or raw_bucket
    if not raw_bucket or not processed_bucket:
        raise ValueError("RAW_BUCKET/PROCESSED_BUCKET or S3_BUCKET must be configured")

    raw_prefix = normalize_prefix(os.environ.get("RAW_PREFIX", "raw"))
    processed_prefix = normalize_prefix(os.environ.get("PROCESSED_PREFIX", "processed"))

    # If pyarrow is missing, fall back to CSV even when USE_PARQUET=true.
    wants_parquet = str_to_bool(os.environ.get("USE_PARQUET"), default=False)
    can_use_parquet = wants_parquet and pa is not None and pq is not None

    return RuntimeConfig(
        raw_bucket=raw_bucket,
        raw_prefix=raw_prefix,
        processed_bucket=processed_bucket,
        processed_prefix=processed_prefix,
        use_parquet=can_use_parquet,
    )


def fetch_open_meteo(lat: float, lon: float) -> dict[str, Any]:
    """Fetch current weather metrics for one coordinate pair from Open-Meteo.

    Args:
        lat: Latitude for the target city.
        lon: Longitude for the target city.

    Returns:
        Decoded JSON payload from the Open-Meteo API.
    """
    params = {
        "latitude": lat,
        "longitude": lon,
        "current": ",".join(CURRENT_FIELDS),
    }
    url = f"https://api.open-meteo.com/v1/forecast?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def to_partition_path(time_of_query: dt.datetime) -> str:
    """Format a timestamp into the hourly partition used by the data lake.

    Args:
        time_of_query: Capture timestamp used for partitioning.

    Returns:
        Partition string shaped as ``ingest_hour=YYYY-MM-DD-HH``.

    Keeping city and minute out of the partition path prevents one partition
    per record. City remains a queryable column in the processed dataset.
    """
    return f"ingest_hour={time_of_query:%Y-%m-%d-%H}"


def to_local_timestamp(time_utc: dt.datetime, timezone: str) -> dt.datetime:
    """Convert a UTC timestamp into a target local timezone.

    Args:
        time_utc: Timezone-aware UTC datetime.
        timezone: IANA timezone name (for example ``Europe/Berlin``).

    Returns:
        Datetime converted to the requested timezone.
    """
    return time_utc.astimezone(ZoneInfo(timezone))


def resolve_observation_times(
    raw: Optional[str],
    timezone: str,
) -> tuple[Optional[dt.datetime], Optional[dt.datetime]]:
    """Parse the observation timestamp and return UTC and local variants.

    Args:
        raw: ISO-8601 timestamp from the API payload.
        timezone: IANA timezone name used for localized output.

    Returns:
        ``(obs_utc, obs_local)`` if parsing succeeds, otherwise ``(None, None)``.
    """
    if not raw:
        return None, None

    # Open-Meteo usually emits UTC with "Z"; `fromisoformat` expects an explicit offset.
    candidate = raw.replace("Z", "+00:00")
    try:
        obs_dt = dt.datetime.fromisoformat(candidate)
    except ValueError:
        return None, None

    # Be defensive in case an offset is omitted in upstream data.
    if obs_dt.tzinfo is None:
        obs_dt = obs_dt.replace(tzinfo=dt.timezone.utc)

    obs_utc = obs_dt.astimezone(dt.timezone.utc)
    obs_local = obs_dt.astimezone(ZoneInfo(timezone))
    return obs_utc, obs_local


def write_s3_bytes(
    bucket: str,
    key: str,
    data_bytes: bytes,
    content_type: str = "application/json",
    gz: bool = False,
) -> None:
    """Upload a byte payload to S3, with optional gzip compression.

    Args:
        bucket: Destination S3 bucket name.
        key: Destination object key. ``.gz`` is appended when ``gz=True``.
        data_bytes: Object contents as raw bytes.
        content_type: MIME content type stored in S3 metadata.
        gz: Whether to gzip the payload before upload.
    """
    if gz:
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb") as gzip_file:
            gzip_file.write(data_bytes)
        data_bytes = buf.getvalue()
        # Keep the key deterministic and add .gz only for compressed payloads.
        get_s3_client().put_object(
            Bucket=bucket,
            Key=f"{key}.gz",
            Body=data_bytes,
            ContentType=content_type,
            ContentEncoding="gzip",
        )
        return

    get_s3_client().put_object(Bucket=bucket, Key=key, Body=data_bytes, ContentType=content_type)


def write_raw(
    time_of_query: dt.datetime,
    observations: list[dict[str, Any]],
    bucket: str,
    prefix: str,
) -> str:
    """Persist one batched raw snapshot to partitioned S3 storage.

    Args:
        time_of_query: Capture timestamp used in partitions and file name.
        observations: Successful API responses and their city metadata.
        bucket: Destination raw-data bucket.
        prefix: Root prefix for raw objects.

    Returns:
        Full S3 key for the uploaded gzipped JSON object.
    """
    if not observations:
        raise ValueError("At least one raw observation is required")

    path = f"{prefix}/{to_partition_path(time_of_query)}/"
    key = f"{path}snapshot_{int(time_of_query.timestamp())}.json"
    document = {
        "ingest_ts_utc": time_of_query.isoformat(),
        "observations": observations,
    }
    write_s3_bytes(bucket, key, json.dumps(document).encode("utf-8"), gz=True)
    return f"{key}.gz"


def write_processed(
    time_of_query: dt.datetime,
    records: list[dict[str, Any]],
    bucket: str,
    prefix: str,
    use_parquet: bool,
) -> str:
    """Store a batch of flattened records in Parquet or CSV.

    Args:
        time_of_query: Capture timestamp used for key generation.
        records: Flattened weather records ready for analytics.
        bucket: Destination processed-data bucket.
        prefix: Root prefix for processed objects.
        use_parquet: Desired storage format; falls back to CSV if pyarrow is unavailable.

    Returns:
        S3 key of the written Parquet or CSV object.
    """
    if not records:
        raise ValueError("At least one processed record is required")

    path = f"{prefix}/{to_partition_path(time_of_query)}/"

    if use_parquet and pa is not None and pq is not None:
        table = pa.Table.from_pylist(records)
        key = f"{path}part-{int(time_of_query.timestamp())}.parquet"
        parquet_buffer = io.BytesIO()
        pq.write_table(table, parquet_buffer, compression="snappy")
        get_s3_client().put_object(
            Bucket=bucket,
            Key=key,
            Body=parquet_buffer.getvalue(),
            ContentType="application/octet-stream",
        )
        return key

    # CSV fallback keeps the pipeline operable when pyarrow is unavailable.
    key = f"{path}part-{int(time_of_query.timestamp())}.csv"
    csv_buffer = io.StringIO()
    writer = csv.DictWriter(csv_buffer, fieldnames=list(records[0].keys()))
    writer.writeheader()
    writer.writerows(records)
    write_s3_bytes(
        bucket=bucket,
        key=key,
        data_bytes=csv_buffer.getvalue().encode("utf-8"),
        content_type="text/csv",
        gz=False,
    )
    return key


def build_processed_record(
    city: str,
    lat: float,
    lon: float,
    timezone_name: str,
    time_of_query: dt.datetime,
    payload: dict[str, Any],
) -> dict[str, Any]:
    """Build one normalized analytics record from raw API data.

    The output includes:
    - Geographic metadata
    - Ingestion timestamps (UTC and local)
    - Observation timestamps (UTC and local, when parseable)
    - Current weather measurements from ``payload["current"]``

    Args:
        city: Human-readable city name.
        lat: City latitude.
        lon: City longitude.
        timezone_name: IANA timezone for local timestamp fields.
        time_of_query: Ingestion timestamp in UTC.
        payload: Raw Open-Meteo payload.

    Returns:
        Flat dictionary ready for CSV/Parquet serialization.
    """
    current = payload.get("current", {})
    # Persist both ingest time and observation time. They can drift if the API
    # publishes measurements on a different cadence than our scheduler.
    now_local = to_local_timestamp(time_of_query, timezone_name)
    obs_utc, obs_local = resolve_observation_times(current.get("time"), timezone_name)

    return {
        "city": city,
        "latitude": lat,
        "longitude": lon,
        "ingest_ts_utc": time_of_query.isoformat(),
        "ingest_ts_local": now_local.isoformat(),
        "ingest_date_local": now_local.date().isoformat(),
        "ingest_time_local": now_local.time().isoformat(timespec="seconds"),
        "timezone": timezone_name,
        "obs_ts_utc": obs_utc.isoformat() if obs_utc else current.get("time"),
        "obs_ts_local": obs_local.isoformat() if obs_local else None,
        "obs_date_local": obs_local.date().isoformat() if obs_local else None,
        "obs_time_local": obs_local.time().isoformat(timespec="seconds") if obs_local else None,
        "temperature_2m": current.get("temperature_2m"),
        "relative_humidity_2m": current.get("relative_humidity_2m"),
        "apparent_temperature": current.get("apparent_temperature"),
        "precipitation": current.get("precipitation"),
        "rain": current.get("rain"),
        "snowfall": current.get("snowfall"),
        "weather_code": current.get("weather_code"),
        "wind_speed_10m": current.get("wind_speed_10m"),
        "wind_direction_10m": current.get("wind_direction_10m"),
        "wind_gusts_10m": current.get("wind_gusts_10m"),
        "surface_pressure": current.get("surface_pressure"),
        "pressure_msl": current.get("pressure_msl"),
        "cloud_cover": current.get("cloud_cover"),
        "dew_point_2m": current.get("dew_point_2m"),
        "visibility": current.get("visibility"),
        "is_day": current.get("is_day"),
    }


def utc_now() -> dt.datetime:
    """Return the current timezone-aware UTC timestamp.

    Returns:
        Current datetime with ``tzinfo=UTC``.
    """
    return dt.datetime.now(dt.timezone.utc)


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Ingest weather data for all configured cities and persist raw/processed outputs.

    The handler performs one capture cycle per invocation:
    1. Loads runtime configuration from environment variables.
    2. Uses one shared ingestion timestamp for all cities.
    3. Fetches Open-Meteo current conditions per city.
    4. Batches all successful cities into one raw and one processed S3 object.

    Args:
        event: Lambda invocation payload (unused).
        context: Lambda runtime context (unused).

    Returns:
        Summary with status, record count, successful cities, and S3 keys.
    """
    del event, context

    config = load_runtime_config()
    # Use one capture timestamp for every city in this invocation so records align.
    now_utc = utc_now()
    raw_observations: list[dict[str, Any]] = []
    processed_records: list[dict[str, Any]] = []
    successful_cities: list[str] = []
    errors: list[dict[str, str]] = []

    for city, (lat, lon, timezone_name) in CITY_COORDS.items():
        try:
            payload = fetch_open_meteo(lat, lon)
            raw_observations.append(
                {
                    "city": city,
                    "latitude": lat,
                    "longitude": lon,
                    "timezone": timezone_name,
                    "payload": payload,
                }
            )

            record = build_processed_record(
                city=city,
                lat=lat,
                lon=lon,
                timezone_name=timezone_name,
                time_of_query=now_utc,
                payload=payload,
            )
            processed_records.append(record)
            successful_cities.append(city)
        except Exception as exc:
            print(f"[ERROR] {city}: {exc}")
            errors.append({"city": city, "error": str(exc)})

    raw_key: Optional[str] = None
    processed_key: Optional[str] = None
    if processed_records:
        # Storage failures are allowed to fail the invocation so EventBridge can retry.
        raw_key = write_raw(
            time_of_query=now_utc,
            observations=raw_observations,
            bucket=config.raw_bucket,
            prefix=config.raw_prefix,
        )
        processed_key = write_processed(
            time_of_query=now_utc,
            records=processed_records,
            bucket=config.processed_bucket,
            prefix=config.processed_prefix,
            use_parquet=config.use_parquet,
        )

    return {
        "ok": len(errors) == 0 and bool(processed_records),
        "records": len(processed_records),
        "cities": successful_cities,
        "errors": errors,
        "raw": raw_key,
        "processed": processed_key,
    }

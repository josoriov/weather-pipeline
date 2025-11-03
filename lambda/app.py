# Imports
import csv
import datetime as dt
import gzip
import io
import json
import os
import urllib.request
from typing import Any, Optional
from zoneinfo import ZoneInfo

import boto3
import pyarrow as pa
import pyarrow.parquet as pq

# Constants
# Switch to disable Parquet and use CSV instead
USE_PARQUET = True
S3_BUCKET = os.environ.get("S3_BUCKET")


# Simple city->(lat,lon,timezone) mapping; feel free to expand or load from SSM
CITY_COORDS: dict[str, tuple[float, float, str]] = {
    "Berlin": (52.5200, 13.4050, "Europe/Berlin"),
    "Madrid": (40.4168, -3.7038, "Europe/Madrid"),
    "Regensburg": (49.0134, 12.1016, "Europe/Berlin"),
    "Bogota": (4.7110, -74.0721, "America/Bogota"),
    "CDMX": (19.4326, -99.1332, "America/Mexico_City"),
    "Cali": (3.4516, -76.5320, "America/Bogota"),
    "Medellin": (6.2442, -75.5812, "America/Bogota"),
    "Paris": (48.8566, 2.3522, "Europe/Paris"),
    "New York": (40.7128, -74.0060, "America/New_York"),
    "Buenos Aires": (-34.6037, -58.3816, "America/Argentina/Buenos_Aires"),
    "London": (51.5074, -0.1278, "Europe/London"),
    "Tokyo": (35.6895, 139.6917, "Asia/Tokyo"),
    "Toronto": (43.6511, -79.3839, "America/Toronto"),
    "Sydney": (-33.8688, 151.2093, "Australia/Sydney")
}

S3 = boto3.client("s3")


def fetch_open_meteo(lat: float, lon: float) -> dict[str, Any]:
    """Return the latest Open-Meteo observations for the provided coordinates.

    Args:
        lat: Latitude in decimal degrees.
        lon: Longitude in decimal degrees.

    Returns:
        A parsed JSON document containing current weather metrics such as temperature,
        humidity, precipitation breakdown, wind statistics, cloud cover, pressure, and visibility.
    """
    # Open-Meteo is free and does not require API keys, but limit requested fields
    # to keep payloads compact.
    base = ("https://api.open-meteo.com/v1/forecast?"
            f"latitude={lat}&longitude={lon}"
            "&current=temperature_2m,relative_humidity_2m,apparent_temperature,"
            "precipitation,rain,snowfall,weather_code,wind_speed_10m,wind_direction_10m,"
            "wind_gusts_10m,surface_pressure,pressure_msl,cloud_cover,dew_point_2m,visibility,is_day")
    with urllib.request.urlopen(base, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def to_partition_path(time_of_query: dt.datetime) -> str:
    """Create a Hive-style partition string based on the UTC timestamp.

    Args:
        time_of_query: UTC datetime used to build the directory structure.
    """
    return (
        f"year={time_of_query:%Y}/month={time_of_query:%m}/day={time_of_query:%d}/"
        f"hour={time_of_query:%H}/minute={time_of_query:%M}"
    )


def to_local_timestamp(time_utc: dt.datetime, timezone: str) -> dt.datetime:
    """Convert a UTC datetime into the provided timezone."""
    return time_utc.astimezone(ZoneInfo(timezone))


def resolve_observation_times(raw: Optional[str], timezone: str) -> tuple[Optional[dt.datetime], Optional[dt.datetime]]:
    """Return the observation timestamp in UTC and localized forms.

    Args:
        raw: ISO 8601 timestamp from the API (UTC or with offset).
        timezone: IANA timezone to convert into.

    Returns:
        Tuple with UTC datetime and localized datetime (both aware) or ``None`` when unavailable.
    """
    if not raw:
        return None, None
    candidate = raw.replace("Z", "+00:00")
    try:
        obs_dt = dt.datetime.fromisoformat(candidate)
    except ValueError:
        return None, None
    if obs_dt.tzinfo is None:
        obs_dt = obs_dt.replace(tzinfo=dt.timezone.utc)
    obs_utc = obs_dt.astimezone(dt.timezone.utc)
    obs_local = obs_dt.astimezone(ZoneInfo(timezone))
    return obs_utc, obs_local


def write_s3_bytes(key: str, data_bytes: bytes, content_type: str = "application/json", gz: bool = False) -> None:
    """Upload the provided payload to S3, optionally gzipping it to save space.

    Args:
        key: Destination object key inside the bucket.
        data_bytes: Raw payload to store.
        content_type: MIME type metadata for the object.
        gz: When ``True``, gzip-compress before uploading.
    """
    if gz:
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb") as gzf:
            gzf.write(data_bytes)
        data_bytes = buf.getvalue()
        S3.put_object(
            Bucket=S3_BUCKET,
            Key=key + ".gz",
            Body=data_bytes,
            ContentType=content_type,
            ContentEncoding="gzip"
        )
    else:
        S3.put_object(Bucket=S3_BUCKET, Key=key, Body=data_bytes, ContentType=content_type)


def write_raw(city: str, time_of_query: dt.datetime, payload: dict[str, Any]) -> str:
    """Persist the raw Open-Meteo payload for a city and return the S3 object key.

    Args:
        city: City identifier matching ``CITY_COORDS``.
        time_of_query: UTC timestamp for the fetch.
        payload: JSON response from Open-Meteo.
    """
    city = city.replace(" ", "_").lower()
    path = f"raw/{city}/{to_partition_path(time_of_query)}/"
    key = f"{path}snapshot_{int(time_of_query.timestamp())}.json"
    write_s3_bytes(key, json.dumps(payload).encode("utf-8"), gz=True)
    return f"{key}.gz"


def write_processed(
        city: str, time_of_query: dt.datetime, record: dict[str, Any]
    ) -> str:
    """Store the normalized record in either Parquet or CSV format and return the S3 key.

    Args:
        city: City identifier matching ``CITY_COORDS``.
        t: UTC timestamp associated with the normalized record.
        record: Flattened weather data ready for persistence.
    """
    city = city.replace(" ", "_").lower()
    path = f"processed/{city}/{to_partition_path(time_of_query)}/"
    if USE_PARQUET:
        table = pa.Table.from_pylist([record])
        key = f"{path}part-{int(time_of_query.timestamp())}.parquet"
        buf = io.BytesIO()
        pq.write_table(table, buf, compression="snappy")
        S3.put_object(
            Bucket=S3_BUCKET,
            Key=key,
            Body=buf.getvalue(),
            ContentType="application/octet-stream"
        )
        return key
    else:
        # Fallback CSV to avoid layer
        key = f"{path}part-{int(time_of_query.timestamp())}.csv"
        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=list(record.keys()))
        writer.writeheader()
        writer.writerow(record)
        write_s3_bytes(key, buf.getvalue().encode("utf-8"), content_type="text/csv", gz=False)
        return key


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Lambda entrypoint that fetches weather data for each city and saves UTC and local-time artifacts.

    Args:
        event: AWS Lambda invocation payload.
        context: AWS Lambda runtime context.
    """
    now_utc = dt.datetime.now(dt.timezone.utc)
    results = []
    # Iterate deterministically over configured cities so the results list is predictable.
    for city in CITY_COORDS.keys():
        lat, lon, tz_name = CITY_COORDS[city]
        data = fetch_open_meteo(lat, lon)
        raw_key = write_raw(city, now_utc, data)

        cur = data.get("current", {})
        now_local = to_local_timestamp(now_utc, tz_name)
        obs_utc_dt, obs_local_dt = resolve_observation_times(cur.get("time"), tz_name)
        rec = {
            "city": city,
            "latitude": lat,
            "longitude": lon,
            "ingest_ts_utc": now_utc.isoformat(),
            "ingest_ts_local": now_local.isoformat(),
            "ingest_date_local": now_local.date().isoformat(),
            "ingest_time_local": now_local.time().isoformat(timespec="seconds"),
            "timezone": tz_name,
            "obs_ts_utc": obs_utc_dt.isoformat() if obs_utc_dt else cur.get("time"),
            "obs_ts_local": obs_local_dt.isoformat() if obs_local_dt else None,
            "obs_date_local": obs_local_dt.date().isoformat() if obs_local_dt else None,
            "obs_time_local": obs_local_dt.time().isoformat(timespec="seconds") if obs_local_dt else None,
            "temperature_2m": cur.get("temperature_2m"),
            "relative_humidity_2m": cur.get("relative_humidity_2m"),
            "apparent_temperature": cur.get("apparent_temperature"),
            "precipitation": cur.get("precipitation"),
            "rain": cur.get("rain"),
            "snowfall": cur.get("snowfall"),
            "weather_code": cur.get("weather_code"),
            "wind_speed_10m": cur.get("wind_speed_10m"),
            "wind_direction_10m": cur.get("wind_direction_10m"),
            "wind_gusts_10m": cur.get("wind_gusts_10m"),
            "surface_pressure": cur.get("surface_pressure"),
            "pressure_msl": cur.get("pressure_msl"),
            "cloud_cover": cur.get("cloud_cover"),
            "dew_point_2m": cur.get("dew_point_2m"),
            "visibility": cur.get("visibility"),
            "is_day": cur.get("is_day")
        }
        proc_key = write_processed(city, now_utc, rec)
        results.append({"city": city, "raw": raw_key, "processed": proc_key})

    return {"ok": True, "results": results}

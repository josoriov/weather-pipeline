import csv
import datetime as dt
import gzip
import io
import json
import os
import pathlib
import sys
import unittest
from typing import Literal
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lambda"))

import app


class DummyResponse:
    """Tiny context-manager stub that mimics `urlopen` responses."""

    def __init__(self, payload: bytes) -> None:
        self._payload = payload

    def __enter__(self) -> "DummyResponse":
        return self

    def __exit__(self, exc_type, exc, tb) -> Literal[False]:
        del exc_type, exc, tb
        return False

    def read(self) -> bytes:
        return self._payload


class WeatherExtractorTests(unittest.TestCase):
    def test_city_config_loads_canonical_file(self) -> None:
        self.assertEqual(len(app.CITY_COORDS), 14)
        self.assertEqual(app.CITY_COORDS["Bogota"], (4.711, -74.0721, "America/Bogota"))

    def test_to_partition_path(self) -> None:
        stamp = dt.datetime(2026, 3, 5, 10, 15, tzinfo=dt.timezone.utc)
        partition = app.to_partition_path(stamp)
        self.assertEqual(partition, "ingest_hour=2026-03-05-10")

    def test_resolve_observation_times_handles_utc_zulu(self) -> None:
        obs_utc, obs_local = app.resolve_observation_times("2026-03-05T10:00:00Z", "Europe/Berlin")

        self.assertEqual(obs_utc, dt.datetime(2026, 3, 5, 10, 0, tzinfo=dt.timezone.utc))
        self.assertIsNotNone(obs_local)
        assert obs_local is not None
        self.assertEqual(obs_local.isoformat(), "2026-03-05T11:00:00+01:00")

    def test_fetch_open_meteo_parses_json_response(self) -> None:
        payload = {"current": {"temperature_2m": 19.4}}
        payload_bytes = json.dumps(payload).encode("utf-8")

        with mock.patch("app.urllib.request.urlopen", return_value=DummyResponse(payload_bytes)) as urlopen_mock:
            result = app.fetch_open_meteo(52.52, 13.405)

        self.assertEqual(result, payload)
        called_url = urlopen_mock.call_args.args[0]
        self.assertIn("latitude=52.52", called_url)
        self.assertIn("longitude=13.405", called_url)
        self.assertEqual(urlopen_mock.call_args.kwargs["timeout"], 20)

    def test_load_runtime_config_requires_bucket(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError):
                app.load_runtime_config()

    def test_write_raw_uploads_one_gzipped_batch(self) -> None:
        stamp = dt.datetime(2026, 3, 5, 10, 15, tzinfo=dt.timezone.utc)
        observations = [
            {"city": "New York", "payload": {"a": 1}},
            {"city": "Berlin", "payload": {"a": 2}},
        ]

        with mock.patch.object(app, "S3", mock.Mock()) as s3_mock:
            key = app.write_raw(
                time_of_query=stamp,
                observations=observations,
                bucket="weather-bucket",
                prefix="raw",
            )

        self.assertEqual(
            key,
            "raw/ingest_hour=2026-03-05-10/snapshot_1772705700.json.gz",
        )

        kwargs = s3_mock.put_object.call_args.kwargs
        self.assertEqual(kwargs["Bucket"], "weather-bucket")
        self.assertEqual(kwargs["Key"], key)
        self.assertEqual(kwargs["ContentType"], "application/json")
        self.assertEqual(kwargs["ContentEncoding"], "gzip")

        decoded_payload = json.loads(gzip.decompress(kwargs["Body"]).decode("utf-8"))
        self.assertEqual(decoded_payload["ingest_ts_utc"], stamp.isoformat())
        self.assertEqual(decoded_payload["observations"], observations)

    def test_write_processed_uploads_one_csv_batch(self) -> None:
        stamp = dt.datetime(2026, 3, 5, 10, 15, tzinfo=dt.timezone.utc)
        records = [
            {"city": "Berlin", "temperature_2m": 14.0},
            {"city": "Madrid", "temperature_2m": 18.0},
        ]

        with mock.patch.object(app, "S3", mock.Mock()) as s3_mock:
            key = app.write_processed(
                time_of_query=stamp,
                records=records,
                bucket="weather-bucket",
                prefix="processed",
                use_parquet=False,
            )

        self.assertEqual(key, "processed/ingest_hour=2026-03-05-10/part-1772705700.csv")
        kwargs = s3_mock.put_object.call_args.kwargs
        rows = list(csv.DictReader(io.StringIO(kwargs["Body"].decode("utf-8"))))
        self.assertEqual([row["city"] for row in rows], ["Berlin", "Madrid"])

    def test_lambda_handler_fetches_and_writes_data(self) -> None:
        fake_now = dt.datetime(2026, 3, 5, 10, 15, tzinfo=dt.timezone.utc)
        config = app.RuntimeConfig(
            raw_bucket="weather-bucket",
            raw_prefix="raw",
            processed_bucket="weather-bucket",
            processed_prefix="processed",
            use_parquet=False,
        )
        payload = {
            "current": {
                "time": "2026-03-05T10:00:00Z",
                "temperature_2m": 14.0,
                "relative_humidity_2m": 80,
            }
        }

        # Patch I/O boundaries so this test validates orchestration only.
        cities = {
            "Berlin": (52.52, 13.405, "Europe/Berlin"),
            "Madrid": (40.4168, -3.7038, "Europe/Madrid"),
        }
        with mock.patch.object(app, "CITY_COORDS", cities):
            with mock.patch.object(app, "load_runtime_config", return_value=config):
                with mock.patch.object(app, "utc_now", return_value=fake_now):
                    with mock.patch.object(app, "fetch_open_meteo", return_value=payload) as fetch_mock:
                        with mock.patch.object(app, "write_raw", return_value="raw-key") as raw_mock:
                            with mock.patch.object(app, "write_processed", return_value="processed-key") as processed_mock:
                                result = app.lambda_handler({}, None)

        self.assertTrue(result["ok"])
        self.assertEqual(result["records"], 2)
        self.assertEqual(result["cities"], ["Berlin", "Madrid"])
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["raw"], "raw-key")
        self.assertEqual(result["processed"], "processed-key")

        self.assertEqual(fetch_mock.call_count, 2)
        fetch_mock.assert_has_calls([mock.call(52.52, 13.405), mock.call(40.4168, -3.7038)])
        raw_mock.assert_called_once()
        processed_mock.assert_called_once()
        self.assertEqual(raw_mock.call_args.kwargs["observations"][0]["city"], "Berlin")
        self.assertEqual(
            [record["city"] for record in processed_mock.call_args.kwargs["records"]],
            ["Berlin", "Madrid"],
        )

    def test_lambda_handler_survives_city_failure(self) -> None:
        fake_now = dt.datetime(2026, 3, 5, 10, 15, tzinfo=dt.timezone.utc)
        config = app.RuntimeConfig(
            raw_bucket="weather-bucket",
            raw_prefix="raw",
            processed_bucket="weather-bucket",
            processed_prefix="processed",
            use_parquet=False,
        )
        cities = {
            "Berlin": (52.52, 13.405, "Europe/Berlin"),
            "Madrid": (40.4168, -3.7038, "Europe/Madrid"),
        }

        def fake_fetch(lat: float, lon: float) -> dict[str, object]:
            if lat == 40.4168:
                raise OSError("timeout")
            return {"current": {"temperature_2m": 14.0}}

        with mock.patch.object(app, "CITY_COORDS", cities):
            with mock.patch.object(app, "load_runtime_config", return_value=config):
                with mock.patch.object(app, "utc_now", return_value=fake_now):
                    with mock.patch.object(app, "fetch_open_meteo", side_effect=fake_fetch):
                        with mock.patch.object(app, "write_raw", return_value="raw-key"):
                            with mock.patch.object(app, "write_processed", return_value="processed-key"):
                                result = app.lambda_handler({}, None)

        self.assertFalse(result["ok"])
        self.assertEqual(result["records"], 1)
        self.assertEqual(len(result["errors"]), 1)
        self.assertEqual(result["errors"][0]["city"], "Madrid")
        self.assertIn("timeout", result["errors"][0]["error"])
        self.assertEqual(result["cities"], ["Berlin"])
        self.assertEqual(result["raw"], "raw-key")
        self.assertEqual(result["processed"], "processed-key")


if __name__ == "__main__":
    unittest.main()

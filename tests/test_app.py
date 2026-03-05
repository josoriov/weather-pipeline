import datetime as dt
import gzip
import json
import os
import pathlib
import sys
import unittest
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

    def __exit__(self, exc_type, exc, tb) -> bool:
        del exc_type, exc, tb
        return False

    def read(self) -> bytes:
        return self._payload


class WeatherExtractorTests(unittest.TestCase):
    def test_to_partition_path(self) -> None:
        stamp = dt.datetime(2026, 3, 5, 10, 15, tzinfo=dt.timezone.utc)
        partition = app.to_partition_path(stamp)
        self.assertEqual(partition, "year=2026/month=03/day=05/hour=10/minute=15")

    def test_resolve_observation_times_handles_utc_zulu(self) -> None:
        obs_utc, obs_local = app.resolve_observation_times("2026-03-05T10:00:00Z", "Europe/Berlin")

        self.assertEqual(obs_utc, dt.datetime(2026, 3, 5, 10, 0, tzinfo=dt.timezone.utc))
        self.assertIsNotNone(obs_local)
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

    def test_write_raw_uploads_gzipped_json(self) -> None:
        stamp = dt.datetime(2026, 3, 5, 10, 15, tzinfo=dt.timezone.utc)
        payload = {"a": 1}

        with mock.patch.object(app.S3, "put_object") as put_object_mock:
            key = app.write_raw(
                city="New York",
                time_of_query=stamp,
                payload=payload,
                bucket="weather-bucket",
                prefix="raw",
            )

        self.assertEqual(
            key,
            "raw/city=new_york/year=2026/month=03/day=05/hour=10/minute=15/snapshot_1772705700.json.gz",
        )

        kwargs = put_object_mock.call_args.kwargs
        self.assertEqual(kwargs["Bucket"], "weather-bucket")
        self.assertEqual(kwargs["Key"], key)
        self.assertEqual(kwargs["ContentType"], "application/json")
        self.assertEqual(kwargs["ContentEncoding"], "gzip")

        decoded_payload = json.loads(gzip.decompress(kwargs["Body"]).decode("utf-8"))
        self.assertEqual(decoded_payload, payload)

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
        with mock.patch.object(app, "CITY_COORDS", {"Berlin": (52.52, 13.405, "Europe/Berlin")}):
            with mock.patch.object(app, "load_runtime_config", return_value=config):
                with mock.patch.object(app, "utc_now", return_value=fake_now):
                    with mock.patch.object(app, "fetch_open_meteo", return_value=payload) as fetch_mock:
                        with mock.patch.object(app, "write_raw", return_value="raw-key") as raw_mock:
                            with mock.patch.object(app, "write_processed", return_value="processed-key") as processed_mock:
                                result = app.lambda_handler({}, None)

        self.assertTrue(result["ok"])
        self.assertEqual(result["records"], 1)
        self.assertEqual(result["results"], [{"city": "Berlin", "raw": "raw-key", "processed": "processed-key"}])

        fetch_mock.assert_called_once_with(52.52, 13.405)
        raw_mock.assert_called_once()
        processed_mock.assert_called_once()


if __name__ == "__main__":
    unittest.main()

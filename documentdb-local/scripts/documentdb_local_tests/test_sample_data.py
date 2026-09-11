"""Unit coverage for counts derived from the compressed sample exports."""

import gzip
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_image import _sample_data_counts  # noqa: E402


class SampleDataCountTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.sample_dir = Path(self.directory.name)
        self.write_sample("stores", [{"_id": "store-a"}, {"_id": "store-b"}])
        self.write_sample("ratings", [{"_id": "store-a"}])

    def write_sample(self, collection, documents):
        source = self.sample_dir / f"StoreData.{collection}.json.gz"
        with gzip.open(source, "wt", encoding="utf-8") as stream:
            json.dump(documents, stream)

    def test_counts_follow_source_files(self):
        self.assertEqual(
            _sample_data_counts(self.sample_dir), {"stores": 2, "ratings": 1}
        )
        self.write_sample("stores", [{"_id": "replacement"}])
        self.write_sample("ratings", [{"_id": "a"}, {"_id": "b"}, {"_id": "c"}])
        self.assertEqual(
            _sample_data_counts(self.sample_dir), {"stores": 1, "ratings": 3}
        )

    def test_extended_json_values_do_not_change_document_counts(self):
        self.write_sample("stores", [
            {"_id": "date", "created": {"$date": "2024-01-01T00:00:00Z"}},
            {"_id": "timestamp", "updated": {"$timestamp": {"t": 123, "i": 1}}},
        ])
        self.assertEqual(
            _sample_data_counts(self.sample_dir), {"stores": 2, "ratings": 1}
        )

    def test_empty_or_non_array_sources_fail(self):
        for collection in ("stores", "ratings"):
            for invalid in ([], {}, None):
                with self.subTest(collection=collection, documents=invalid):
                    self.write_sample(collection, invalid)
                    with self.assertRaisesRegex(ValueError, "non-empty document array"):
                        _sample_data_counts(self.sample_dir)
            self.write_sample(collection, [{"_id": "valid"}])

    def test_missing_source_fails(self):
        (self.sample_dir / "StoreData.ratings.json.gz").unlink()
        with self.assertRaises(FileNotFoundError):
            _sample_data_counts(self.sample_dir)

    def test_invalid_json_fails(self):
        source = self.sample_dir / "StoreData.stores.json.gz"
        with gzip.open(source, "wt", encoding="utf-8") as stream:
            stream.write("[")
        with self.assertRaises(json.JSONDecodeError):
            _sample_data_counts(self.sample_dir)

    def test_corrupt_archive_fails(self):
        source = self.sample_dir / "StoreData.stores.json.gz"
        source.write_bytes(b"not gzip")
        with self.assertRaises(gzip.BadGzipFile):
            _sample_data_counts(self.sample_dir)


if __name__ == "__main__":
    unittest.main()

import io
import json
import unittest
from unittest.mock import patch

import asc


def build(number):
    return {"attributes": {"version": number}}


class LatestBuildTests(unittest.TestCase):
    def setUp(self):
        self.token = patch.object(asc, "token", return_value="token").start()
        self.app_id = patch.object(asc, "app_id", return_value="app-id").start()
        self.get = patch.object(asc, "get").start()
        self.addCleanup(patch.stopall)

    def test_unscoped_lookup_keeps_previous_marketing_versions(self):
        self.get.return_value = {"data": [build("69"), build("1")]}
        self.assertEqual(asc.latest_build("com.example.app"), 69)
        query = self.get.call_args.kwargs
        self.assertEqual(query["filter[app]"], "app-id")
        self.assertNotIn("filter[preReleaseVersion.version]", query)

    def test_review_lookup_remains_version_scoped(self):
        self.get.return_value = {"data": [build("2"), build("1")]}
        self.assertEqual(asc.latest_build("com.example.app", "3.2.0"), 2)
        self.assertEqual(self.get.call_args.kwargs["filter[preReleaseVersion.version]"], "3.2.0")

    def test_maximum_can_be_on_later_page(self):
        next_page = f"{asc.API}/builds?cursor=abc%2Bdef%3D&limit=200"
        self.get.side_effect = [
            {"data": [build("1")], "links": {"next": next_page}},
            {"data": [build("69")], "links": {"next": None}},
        ]
        self.assertEqual(asc.latest_build("com.example.app"), 69)
        self.get.assert_called_with(next_page, "token")

    def test_no_builds(self):
        self.get.return_value = {"data": [], "links": {"next": None}}
        self.assertEqual(asc.latest_build("com.example.app"), 0)

    def test_no_app(self):
        self.app_id.return_value = None
        self.assertEqual(asc.latest_build("com.example.app"), 0)
        self.get.assert_not_called()

    def test_later_page_failure_does_not_return_partial_maximum(self):
        self.get.side_effect = [
            {"data": [build("1")], "links": {"next": f"{asc.API}/builds?cursor=next"}},
            OSError("request failed"),
        ]
        with self.assertRaisesRegex(OSError, "request failed"):
            asc.latest_build("com.example.app")

    def test_unscoped_lookup_refuses_to_ignore_dotted_build(self):
        self.get.return_value = {"data": [build("69"), build("100.1")]}
        with self.assertRaisesRegex(SystemExit, "non-integer build 100.1"):
            asc.latest_build("com.example.app")


class WaitProcessedTests(unittest.TestCase):
    def setUp(self):
        patch.object(asc, "token", return_value="token").start()
        patch.object(asc, "app_id", return_value="app-id").start()
        self.get = patch.object(asc, "get").start()
        self.sleep = patch.object(asc.time, "sleep").start()
        self.addCleanup(patch.stopall)

    @staticmethod
    def state(value):
        return {"data": [{"attributes": {"processingState": value, "version": "70"}}]}

    def test_returns_once_valid(self):
        self.get.side_effect = [self.state("PROCESSING"), self.state("PROCESSING"), self.state("VALID")]
        asc.wait_processed("com.example.app", "3.2.0", "70")
        self.assertEqual(self.get.call_count, 3)
        self.assertEqual(self.sleep.call_count, 2)
        query = self.get.call_args.kwargs
        self.assertEqual(query["filter[version]"], "70")
        self.assertEqual(query["filter[preReleaseVersion.version]"], "3.2.0")

    def test_build_not_listed_yet_keeps_waiting(self):
        self.get.side_effect = [{"data": []}, self.state("VALID")]
        asc.wait_processed("com.example.app", "3.2.0", "70")
        self.assertEqual(self.sleep.call_count, 1)

    def test_failed_processing_stops(self):
        self.get.return_value = self.state("INVALID")
        with self.assertRaisesRegex(SystemExit, "failed processing"):
            asc.wait_processed("com.example.app", "3.2.0", "70")
        self.sleep.assert_not_called()

    def test_gives_up_after_timeout(self):
        self.get.return_value = self.state("PROCESSING")
        with patch.object(asc.time, "time", side_effect=[0, 0, 61]):
            with self.assertRaisesRegex(SystemExit, "still PROCESSING after 1 minutes"):
                asc.wait_processed("com.example.app", "3.2.0", "70", "1")


class GetTests(unittest.TestCase):
    @patch.object(asc.urllib.request, "urlopen")
    def test_encoded_pagination_url_is_unchanged(self, urlopen):
        url = f"{asc.API}/builds?cursor=abc%2Bdef%3D&limit=200"
        urlopen.return_value = io.BytesIO(json.dumps({"data": []}).encode())
        self.assertEqual(asc.get(url, "token"), {"data": []})
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, url)
        self.assertEqual(request.get_header("Authorization"), "Bearer token")

    @patch.object(asc.urllib.request, "urlopen")
    def test_initial_query_is_encoded(self, urlopen):
        urlopen.return_value = io.BytesIO(b'{"data": []}')
        asc.get("builds", "token", **{"filter[app]": "app-id"})
        self.assertEqual(urlopen.call_args.args[0].full_url, f"{asc.API}/builds?filter%5Bapp%5D=app-id")

    @patch.object(asc.urllib.request, "urlopen")
    def test_pagination_cannot_leak_token_to_another_origin(self, urlopen):
        for url in ("https://example.com/builds", "http://api.appstoreconnect.apple.com/v1/builds"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                asc.get(url, "token")
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()

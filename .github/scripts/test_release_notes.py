import tempfile
import unittest
from pathlib import Path

import release_notes


class ProblemsTests(unittest.TestCase):
    def test_clean_text_passes(self):
        self.assertEqual(release_notes.problems("Faster search.\nPress Command-K to open it."), [])

    def test_each_store_copy_rule(self):
        cases = {
            "": "empty",
            "   \n": "empty",
            "TODO write this": "TODO",
            "New — faster": "dash",
            "Range 1–9": "dash",
            "Press ⌘K": "command key",
            "Mahmut is free": "free",
            "x" * 4001: "over the",
        }
        for text, expected in cases.items():
            with self.subTest(text=text[:20]):
                self.assertTrue(any(expected in p for p in release_notes.problems(text)), release_notes.problems(text))

    def test_plain_hyphens_and_free_inside_words_are_fine(self):
        self.assertEqual(release_notes.problems("On-device and pretty-printed. Freeze-proof."), [])


class LoadTests(unittest.TestCase):
    def directory(self, files):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        for name, text in files.items():
            Path(folder.name, name).write_text(text, encoding="utf-8")
        return folder.name

    def test_loads_default_and_locale_overrides(self):
        notes = release_notes.load(self.directory({"default.txt": " Hello \n", "tr.txt": "Merhaba"}))
        self.assertEqual(notes, {"default": "Hello", "tr": "Merhaba"})

    def test_default_is_required(self):
        with self.assertRaisesRegex(SystemExit, "default.txt is missing"):
            release_notes.load(self.directory({"tr.txt": "Merhaba"}))

    def test_reports_the_file_and_the_reason(self):
        with self.assertRaisesRegex(SystemExit, r"tr\.txt has an en or em dash"):
            release_notes.load(self.directory({"default.txt": "Fine", "tr.txt": "Olmaz — bu"}))


if __name__ == "__main__":
    unittest.main()

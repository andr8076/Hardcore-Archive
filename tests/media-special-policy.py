#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import pathlib
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("hardcore_media", ROOT / "lib/hardcore-archive-media.py")
MEDIA = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MEDIA)


def stream(kind, codec, *, tags=None, disposition=None, **extra):
    value = {
        "codec_type": kind,
        "codec_name": codec,
        "tags": tags or {},
        "disposition": disposition or {},
    }
    value.update(extra)
    return value


class MediaPolicyTests(unittest.TestCase):
    def capture_classification(self, data):
        output = io.StringIO()
        with mock.patch.object(MEDIA, "probe", return_value=data), contextlib.redirect_stdout(output):
            rc = MEDIA.classify("movie.mkv")
        self.assertEqual(rc, 0)
        return output.getvalue().strip()

    def test_ordinary_movie_is_not_special(self):
        data = {"streams": [stream("video", "h264"), stream("audio", "aac", channels=2)]}
        self.assertEqual(self.capture_classification(data), "")

    def test_unusual_features_are_explained(self):
        data = {
            "streams": [
                stream("video", "hevc", color_transfer="smpte2084", pix_fmt="yuva420p", field_order="tt"),
                stream("video", "mjpeg"),
                stream("video", "mjpeg", disposition={"attached_pic": 1}),
                stream("audio", "truehd", channels=8, profile="Dolby Atmos"),
                stream("subtitle", "mov_text"),
                stream("data", "bin_data"),
            ]
        }
        result = self.capture_classification(data)
        for expected in (
            "2 primary video streams",
            "embedded data streams",
            "attached cover-art video",
            "HDR video",
            "video alpha channel",
            "interlaced video",
            "lossless/object audio (truehd)",
            "object/ambisonic audio",
            "container-sensitive subtitles (mov_text)",
        ):
            self.assertIn(expected, result)

    def fixtures(self):
        common_tags = {"language": "eng", "title": "Main"}
        source = {
            "streams": [
                stream("video", "h264", tags=common_tags, disposition={"default": 1}, color_transfer="bt709"),
                stream("video", "mjpeg", tags={"title": "Angle 2"}),
                stream("video", "mjpeg", disposition={"attached_pic": 1}, tags={"filename": "cover.jpg", "mimetype": "image/jpeg"}),
                stream("audio", "aac", channels=2, tags={"language": "eng", "title": "Stereo"}, disposition={"default": 1}),
                stream("subtitle", "ass", tags={"language": "dan"}, disposition={"forced": 1}),
                stream("data", "bin_data", tags={"title": "Telemetry"}),
                stream("attachment", "ttf", tags={"filename": "font.ttf", "mimetype": "application/x-truetype-font"}),
            ],
            "chapters": [{"start_time": "0.000", "end_time": "10.000", "tags": {"title": "Intro"}}],
            "format": {"tags": {"title": "Example", "artist": "Camera", "encoder": "ignored"}},
        }
        output = {
            "streams": [
                stream("video", "av1", tags=common_tags, disposition={"default": 1}, color_transfer="bt709"),
                stream("video", "mjpeg", tags={"title": "Angle 2"}),
                stream("video", "mjpeg", disposition={"attached_pic": 1}, tags={"filename": "cover.jpg", "mimetype": "image/jpeg"}),
                stream("audio", "opus", channels=2, tags={"language": "eng", "title": "Stereo"}, disposition={"default": 1}),
                stream("subtitle", "ass", tags={"language": "dan"}, disposition={"forced": 1}),
                stream("data", "bin_data", tags={"title": "Telemetry"}),
                stream("attachment", "ttf", tags={"filename": "font.ttf", "mimetype": "application/x-truetype-font"}),
            ],
            "chapters": [{"start_time": "0.001", "end_time": "10.001", "tags": {"title": "Intro"}}],
            "format": {"tags": {"title": "Example", "artist": "Camera", "encoder": "changed but ignored"}},
        }
        return source, output

    def test_semantic_round_trip_accepts_intentional_primary_and_audio_conversion(self):
        source, output = self.fixtures()
        with mock.patch.object(MEDIA, "probe", side_effect=[source, output]):
            self.assertEqual(MEDIA.validate("source", "output"), 0)

    def test_semantic_round_trip_rejects_lost_streams_and_metadata(self):
        source, output = self.fixtures()
        output["streams"] = [item for item in output["streams"] if item["codec_type"] != "subtitle"]
        output["streams"][3]["tags"]["language"] = "deu"
        errors = io.StringIO()
        with mock.patch.object(MEDIA, "probe", side_effect=[source, output]), contextlib.redirect_stderr(errors):
            self.assertEqual(MEDIA.validate("source", "output"), 1)
        self.assertIn("subtitle count changed", errors.getvalue())
        self.assertIn("audio stream 1 metadata changed", errors.getvalue())


if __name__ == "__main__":
    unittest.main()

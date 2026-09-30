#!/usr/bin/env python3
"""Regenerate tests/fixtures from the upstream (independent) reference encoder.

The WeRead chapter payload decoder in this project is a Lua port of
weread.koplugin's implementation. To avoid validating a port against itself,
the fixtures are produced by upstream's *Python* encoder
(scripts/fetch_weread_epub.py + scripts/mock_weread.py from
https://github.com/QiuYukang/weread.koplugin, AGPL-3.0) and committed, so the
Lua test suite stays hermetic (no network, no python) while still
cross-checking two independent implementations.

Usage:
    scripts/gen_fixtures.py /path/to/weread.koplugin

Requires the koplugin checkout because the encoder lives there:

    git clone --depth 1 https://github.com/QiuYukang/weread.koplugin /tmp/wrk
    scripts/gen_fixtures.py /tmp/wrk
"""

import base64
import hashlib
import importlib.util
import io
import json
import pathlib
import struct
import sys
import tarfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE.parent / "tests" / "fixtures"
BASE_PLACEHOLDER = "{{BASE}}"


def load_upstream(repo: pathlib.Path):
    """Import upstream's swap_positions + weread_e without running its main()."""
    path = repo / "scripts" / "fetch_weread_epub.py"
    spec = importlib.util.spec_from_file_location("weread_upstream_encoder", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses need the module registered
    spec.loader.exec_module(module)
    return module


def shards(upstream, text: str, count: int = 3) -> list:
    """Upstream's encoder: plaintext -> N md5-prefixed shards."""
    encoded = base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")
    chars = list(encoded)
    positions = upstream.swap_positions(encoded)
    for i in range(0, len(positions), 2):
        for k in (0, 1):
            a, b = positions[i] + k, positions[i + 1] + k
            chars[a], chars[b] = chars[b], chars[a]
    body = "0" + "".join(chars)
    parts = [body[len(body) * i // count:len(body) * (i + 1) // count] for i in range(count)]
    return [hashlib.md5(part.encode()).hexdigest().upper() + part for part in parts]


def single_shard(upstream, text: str) -> str:
    return shards(upstream, text, 1)[0]


# ------------------------------------------------------------------ images

def png_bytes(width=2, height=2, color=(200, 30, 30)):
    """Minimal, valid, real PNG (no external deps)."""
    raw = b""
    for _ in range(height):
        raw += b"\x00" + bytes(color) * width

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack("!I", len(data))
            + kind
            + data
            + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def jpeg_bytes():
    """A tiny but structurally valid JPEG (SOI + APP0 + minimal SOF/EOI)."""
    return bytes.fromhex(
        "ffd8ffe000104a46494600010100000100010000"
        "ffdb004300ff" * 1
        + "ffdb0043" + "01" * 64
        + "ffc00011080001000103012200021101031101"
        + "ffc4001f0000010501010101010100000000000000000102030405060708090a0b"
        + "ffda0008010100003f00d2cf20ffd9"
    )


def build_tar() -> bytes:
    """A POSIX tar shaped like WeRead's chapter resource packages.

    Entries are nested under a numeric directory and carry no file extension,
    which is how WeRead ships chapter images -- the reader is expected to sniff
    the type from the magic bytes.
    """
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:

        def add(name: str, data: bytes):
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            info.mtime = 0
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))

        def add_dir(name: str):
            info = tarfile.TarInfo(name=name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.mtime = 0
            tar.addfile(info)

        add_dir("36/")
        add("36/epub_43208843_44", png_bytes())
        add("36/epub_43208843_45", jpeg_bytes())
        add("36/epub_43208843_46", b"not an image at all")
    return buf.getvalue()


# ------------------------------------------------------------------ corpus

XHTML_BODY = (
    '<div class="readerChapterContent">'
    '<h1 class="title">第 3 章&nbsp;宇宙闪烁</h1>'
    "<p>汪淼把车停在楼下，抬头看天。</p>"
    '<p class="content">他想起叶文洁说过的那句话：<em>“不要回答！”</em></p>'
    '<p><img src="https://res.weread.qq.com/wrepub/epub_43208843_44"/></p>'
    '<p>图 1-6：三体世界的第一张照片</p>'
    '<p><img src="https://res.weread.qq.com/wrepub/epub_43208843_45"/></p>'
    "</div>"
)

CHAPTER_CSS = (
    ".readerChapterContent p { margin: 0 0 1em 0; text-indent: 2em; }\n"
    ".readerChapterContent h1.title { font-size: 1.4em; font-weight: bold; }\n"
)

TXT_BODY = (
    "第一章　重启\n"
    "\n"
    "　　许阳睁开眼睛，闻到了熟悉的消毒水味。\r\n"
    "　　他记得自己明明已经死了。\r\n"
)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    repo = pathlib.Path(sys.argv[1])
    upstream = load_upstream(repo)
    FIXTURES.mkdir(parents=True, exist_ok=True)

    payloads = {
        "very_short": "hi",
        "boundary_10": "0123456789",
        "boundary_11": "0123456789a",
        "chinese": "第一章 测试\n这是一段中文正文，用来验证解码链是否与上游实现一致。\n",
        "xhtml": XHTML_BODY,
        "css": CHAPTER_CSS,
        "txt": TXT_BODY,
    }

    encoded = {}
    for name, text in payloads.items():
        count = 3 if name == "xhtml" else 1
        encoded[name] = {
            "plain": text,
            "shards": shards(upstream, text, count),
        }

    (FIXTURES / "shards.json").write_text(
        json.dumps(encoded, ensure_ascii=False, indent=1), encoding="utf-8"
    )

    (FIXTURES / "images.tar").write_bytes(build_tar())

    reader_html = (
        "<!DOCTYPE html><html><head><title>微信读书</title></head><body>"
        "<script>window.__INITIAL_STATE__ = "
        + json.dumps(
            {
                "reader": {
                    "bookInfo": {
                        "bookId": "43208843",
                        "title": "持续交付2.0",
                        "author": "乔梁",
                    },
                    "psvts": "9a1b2c3d4e5f60718293a4b5c6d7e8f0",
                    "pclts": "11223344556677889900112233445566",
                    "token": "t0ken-fixture",
                    "currentChapter": {"chapterUid": 2, "chapterIdx": 1},
                    "progress": {"book": {"progress": 3, "chapterUid": 2}},
                }
            },
            ensure_ascii=False,
        )
        + ";(function(){/* boot */})()</script></body></html>"
    )
    (FIXTURES / "reader.html").write_text(reader_html, encoding="utf-8")

    catalog = {
        "data": [
            {
                "bookId": "43208843",
                "format": "epub",
                "synckey": 11,
                "book": {"title": "持续交付2.0", "author": "乔梁"},
                "updated": [
                    {
                        "chapterUid": 1,
                        "chapterIdx": 1,
                        "title": "封面",
                        "wordCount": 0,
                        "level": 1,
                        "paid": 0,
                    },
                    {
                        "chapterUid": 2,
                        "chapterIdx": 2,
                        "title": "第 3 章 宇宙闪烁",
                        "wordCount": 151,
                        "level": 1,
                        "paid": 0,
                        "tar": BASE_PLACEHOLDER + "/wrco/tar_43208843_36",
                    },
                    {
                        "chapterUid": 119,
                        "chapterIdx": 3,
                        "title": "第 4 章 三体、牛顿、秦始皇",
                        "wordCount": 200,
                        "level": 1,
                        "paid": 1,
                    },
                ],
            }
        ]
    }
    (FIXTURES / "catalog.json").write_text(
        json.dumps(catalog, ensure_ascii=False, indent=1), encoding="utf-8"
    )

    print("fixtures written to", FIXTURES)
    for name, data in encoded.items():
        print(f"  {name}: {len(data['plain'].encode())} bytes -> {len(data['shards'])} shard(s)")
    print(f"  images.tar: {(FIXTURES / 'images.tar').stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

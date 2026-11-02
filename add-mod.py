#!/usr/bin/env python3
"""Add a Nexus mod to a Preflight stack, so the queue knows about it.

Paste the mod's Files-tab URL and a fragment of the file name; the script appends a member to the
stack YAML. Nothing is downloaded and no Nexus page is fetched: this only writes the line the queue
needs, because Nexus allows one website click per file and Preflight never builds download links.

Usage:
    python add-mod.py --stack stacks/my-mods.yaml \\
        --url "https://www.nexusmods.com/cyberpunk2077/mods/12345?tab=files" \\
        --name "Better Saves" --file "*BetterSaves*"

    python add-mod.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

GAME = "cyberpunk2077"
PAGE = re.compile(r"^https://www\.nexusmods\.com/(?P<game>[a-z0-9]+)/mods/(?P<mod_id>\d+)(?:/.*)?(?:\?.*)?$")


def parse_page(url: str) -> tuple[str, int]:
    """Returns (game, mod id) or raises ValueError. Only file pages are accepted."""
    match = PAGE.match(url.strip())
    if not match:
        raise ValueError(f"not a Nexus mod page: {url!r}")
    if match.group("game") != GAME:
        raise ValueError(f"this stack is for {GAME}, the URL is for {match.group('game')}")
    return match.group("game"), int(match.group("mod_id"))


def member_id(mod_id: int, name: str | None) -> str:
    """Stable, unique id for the queue: the Nexus mod number, with a readable prefix when known."""
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    return f"nexus-{mod_id}" if not slug else f"{slug}-{mod_id}"


def block(id_: str, name: str, url: str, file_pattern: str) -> str:
    page = url.split("?", 1)[0].rstrip("/") + "?tab=files"
    return (
        f"  - mod: {id_}\n"
        f"    name: {name}\n"
        f"    page: {page}\n"
        f'    file: "{file_pattern}"\n'
    )


def append(stack: Path, text: str) -> None:
    body = stack.read_text(encoding="utf-8")
    if "members:" not in body:
        body = body.rstrip() + "\nmembers:\n"
    body = body.rstrip() + "\n" + text
    stack.write_text(body, encoding="utf-8")


def self_test() -> None:
    assert parse_page("https://www.nexusmods.com/cyberpunk2077/mods/12345?tab=files") == (GAME, 12345)
    assert parse_page("https://www.nexusmods.com/cyberpunk2077/mods/12345")[1] == 12345
    for bad in [
        "https://www.nexusmods.com/skyrimspecialedition/mods/1",
        "https://example.com/mods/1",
        "ftp://www.nexusmods.com/cyberpunk2077/mods/1",
    ]:
        try:
            parse_page(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"accepted {bad!r}")
    assert member_id(12345, "Better Saves") == "better-saves-12345"
    assert member_id(12345, None) == "nexus-12345"
    expected = (
        "  - mod: better-saves-12345\n"
        "    name: Better Saves\n"
        "    page: https://www.nexusmods.com/cyberpunk2077/mods/12345?tab=files\n"
        '    file: "*BetterSaves*"\n'
    )
    assert block("better-saves-12345", "Better Saves", "https://www.nexusmods.com/cyberpunk2077/mods/12345?tab=files&file_id=9", "*BetterSaves*") == expected
    print("self-test ok")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stack", type=Path, help="stack YAML to append to")
    parser.add_argument("--url", help="the mod's Files-tab URL from your browser")
    parser.add_argument("--name", help="mod name shown in the queue")
    parser.add_argument("--file", help='download name fragment, e.g. "*BetterSaves*"')
    parser.add_argument("--self-test", action="store_true", help="run the built-in checks")
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        return 0
    if not args.stack or not args.url:
        parser.error("--stack and --url are required (or pass --self-test)")

    try:
        _, mod_id = parse_page(args.url)
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2

    if not args.stack.is_file():
        print(f"error: no stack at {args.stack}", file=sys.stderr)
        return 2

    name = args.name
    if not name:
        if not sys.stdin.isatty():
            parser.error("--name is required when not running interactively")
        name = input("mod name: ").strip() or f"mod {mod_id}"

    file_pattern = args.file
    if not file_pattern:
        if not sys.stdin.isatty():
            parser.error('--file is required when not running interactively (e.g. --file "*BetterSaves*")')
        file_pattern = input('file name fragment (e.g. "*BetterSaves*"): ').strip()
    if not file_pattern:
        print("error: without a file pattern the queue cannot tell when the download landed", file=sys.stderr)
        return 2

    id_ = member_id(mod_id, name)
    append(args.stack, block(id_, name, args.url, file_pattern))
    print(f"added {id_} to {args.stack}")
    print(f"next: preflight stack plan {args.stack} --game <game folder>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

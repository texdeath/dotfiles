#!/usr/bin/env python3
"""Notion Enhanced Markdown を標準 Markdown に変換する。"""

import re
import sys
from pathlib import Path


def convert(text: str) -> str:
    m = re.search(r"<content>\n?(.*?)\n?</content>", text, re.DOTALL)
    if m:
        text = m.group(1)

    text = re.sub(
        r'<page url="([^"]+)">([^<]+)</page>',
        r"[\2](\1)",
        text,
    )
    text = re.sub(r"<empty-block\s*/>", "", text)
    text = re.sub(r"<colgroup>.*?</colgroup>", "", text, flags=re.DOTALL)
    text = re.sub(r"<col\b[^/]*/>", "", text)
    text = text.replace("<br>", "  \n")

    text = _convert_tables(text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


def _convert_tables(text: str) -> str:
    def repl(m: re.Match) -> str:
        body = m.group(1)
        rows = re.findall(r"<tr>\s*(.*?)\s*</tr>", body, re.DOTALL)
        lines: list[str] = []
        for i, row in enumerate(rows):
            cells = re.findall(
                r"<t[dh]>\s*(.*?)\s*</t[dh]>", row, re.DOTALL
            )
            cells = [_clean_cell(c) for c in cells]
            lines.append("| " + " | ".join(cells) + " |")
            if i == 0:
                lines.append("| " + " | ".join(["---"] * len(cells)) + " |")
        return "\n" + "\n".join(lines) + "\n"

    return re.sub(
        r'<table header-row="true">(.*?)</table>',
        repl,
        text,
        flags=re.DOTALL,
    )


def _clean_cell(cell: str) -> str:
    cell = cell.strip()
    cell = re.sub(r"\n+", "<br>", cell)
    cell = cell.replace("|", "\\|")
    return cell


def main() -> None:
    if len(sys.argv) != 3:
        print("Usage: notion-to-md.py INPUT OUTPUT", file=sys.stderr)
        sys.exit(1)
    src = Path(sys.argv[1]).read_text()
    Path(sys.argv[2]).write_text(convert(src))
    print(f"wrote: {sys.argv[2]}")


if __name__ == "__main__":
    main()

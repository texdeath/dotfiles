#!/usr/bin/env python3
"""
Convert standard Markdown to Notion-flavored Markdown.

Transformations:
  1. Pipe tables → <table> XML (with header-row detection)
  2. Consecutive blockquote lines → single blockquote with <br>
  3. Strip first H1 heading (Notion uses page title property)

Usage:
  md-to-notion.py input.md                # output to stdout
  md-to-notion.py input.md -o output.md   # output to file
  md-to-notion.py input.md -o -           # explicit stdout
"""

import argparse
import re
import sys
from pathlib import Path


def convert_pipe_tables(lines: list[str]) -> list[str]:
    """Convert pipe tables to Notion <table> XML format."""
    result = []
    i = 0
    while i < len(lines):
        # Detect table: line with pipes, followed by separator line (---|---)
        if (
            i + 1 < len(lines)
            and "|" in lines[i]
            and re.match(r"^\s*\|[\s\-:|]+\|\s*$", lines[i + 1])
        ):
            header_line = lines[i]
            # skip separator
            i += 2
            body_lines = []
            while i < len(lines) and "|" in lines[i] and lines[i].strip().startswith("|"):
                body_lines.append(lines[i])
                i += 1

            # Parse cells from a pipe-table row
            def parse_row(line: str) -> list[str]:
                line = line.strip()
                if line.startswith("|"):
                    line = line[1:]
                if line.endswith("|"):
                    line = line[:-1]
                return [c.strip() for c in line.split("|")]

            header_cells = parse_row(header_line)
            result.append('<table header-row="true">')
            result.append("<tr>")
            for cell in header_cells:
                result.append(f"<td>{cell}</td>")
            result.append("</tr>")
            for body_line in body_lines:
                cells = parse_row(body_line)
                result.append("<tr>")
                for cell in cells:
                    result.append(f"<td>{cell}</td>")
                result.append("</tr>")
            result.append("</table>")
        else:
            result.append(lines[i])
            i += 1
    return result


def merge_blockquotes(lines: list[str]) -> list[str]:
    """Merge consecutive blockquote lines with <br>."""
    result = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("> "):
            bq_parts = [lines[i][2:]]  # strip "> "
            i += 1
            while i < len(lines) and lines[i].startswith("> "):
                bq_parts.append(lines[i][2:])
                i += 1
            result.append("> " + "<br>".join(bq_parts))
        else:
            result.append(lines[i])
            i += 1
    return result


def strip_first_h1(lines: list[str]) -> list[str]:
    """Remove the first H1 heading (Notion page title property handles it)."""
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == "":
            continue
        if stripped.startswith("# "):
            # Remove the H1 line and any immediately following blank line
            remaining = lines[i + 1 :]
            if remaining and remaining[0].strip() == "":
                remaining = remaining[1:]
            return lines[:i] + remaining
        # First non-blank line is not H1 — stop looking
        break
    return lines


def convert(text: str) -> str:
    lines = text.split("\n")
    # Remove trailing newline artifact
    if lines and lines[-1] == "":
        lines = lines[:-1]

    lines = strip_first_h1(lines)
    lines = convert_pipe_tables(lines)
    lines = merge_blockquotes(lines)

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(
        description="Convert Markdown to Notion-flavored Markdown"
    )
    parser.add_argument("input", help="Input markdown file")
    parser.add_argument(
        "-o",
        "--output",
        default="-",
        help="Output file (default: stdout, use '-' for stdout)",
    )
    args = parser.parse_args()

    text = Path(args.input).read_text(encoding="utf-8")
    result = convert(text)

    if args.output == "-":
        sys.stdout.write(result)
    else:
        Path(args.output).write_text(result, encoding="utf-8")
        print(f"Written to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()

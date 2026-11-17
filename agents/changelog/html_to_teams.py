#!/usr/bin/env python3
"""Convert the Telegram HTML changelog card into a Teams Adaptive Card.

The code card is authored once, as Telegram HTML. Rather than ask Claude for a second
rendering (another paid call for the same content), this rewrites the markup: Telegram's
<b>/<i>/<code> map cleanly onto the limited markdown an Adaptive Card TextBlock accepts.

Usage: html_to_teams.py <card.html> [out.json] [--image URL]
"""
import html
import json
import re
import sys

BULLET = re.compile(r"^[•·]\s*")


def to_markdown(line):
    line = re.sub(r"<b>(.*?)</b>", r"**\1**", line, flags=re.S)
    line = re.sub(r"<i>(.*?)</i>", r"_\1_", line, flags=re.S)
    line = re.sub(r"<code>(.*?)</code>", r"`\1`", line, flags=re.S)
    line = re.sub(r'<a href="([^"]+)">(.*?)</a>', r"[\2](\1)", line, flags=re.S)
    line = re.sub(r"<[^>]+>", "", line)
    return html.unescape(line)


def convert(card_html, image=None):
    body = []
    buf = []

    def flush():
        if buf:
            text = "\n\n".join(buf).strip()
            if text:
                body.append({"type": "TextBlock", "wrap": True, "text": text})
            buf.clear()

    for raw in card_html.splitlines():
        line = to_markdown(raw).rstrip()
        if not line.strip():
            flush()
            continue
        # The heavy rule the card uses as a section divider becomes a real separator.
        if set(line.strip()) <= {"━", "─", "-", "—"} and len(line.strip()) > 3:
            flush()
            continue
        if not body and not buf:
            flush()
            body.append({"type": "TextBlock", "text": line, "weight": "Bolder",
                         "size": "Large", "wrap": True})
            continue
        buf.append(BULLET.sub("- ", line))
    flush()

    if image:
        body.append({"type": "Image", "url": image, "size": "Stretch",
                     "altText": "Flow diagram"})

    return {"type": "message", "attachments": [{
        "contentType": "application/vnd.microsoft.card.adaptive",
        "content": {"$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard", "version": "1.4", "body": body}}]}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    image = None
    for a in sys.argv[1:]:
        if a.startswith("--image="):
            image = a.split("=", 1)[1]
    if not args:
        print("usage: html_to_teams.py <card.html> [out.json] [--image=URL]", file=sys.stderr)
        return 2
    card = open(args[0], errors="replace").read()
    out = json.dumps(convert(card, image), indent=1)
    if len(args) > 1:
        open(args[1], "w").write(out)
    else:
        print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

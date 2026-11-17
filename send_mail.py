#!/usr/bin/env python3
"""CBA mailer — sends an email with file attachments via SMTP.

Usage: send_mail.py <to> <subject> <body> [file1 file2 ...]
SMTP settings are read from config.env (same dir): CBA_SMTP_HOST/PORT/USER/PASS/FROM.
Exits 0 on success, non-zero on failure (prints a short reason to stdout).
"""
import os
import sys
import smtplib
import ssl
from email.message import EmailMessage
from pathlib import Path


def load_config(path: Path) -> dict:
    cfg = {}
    if not path.exists():
        return cfg
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: send_mail.py <to> <subject> <body> [files...]")
        return 2

    to_addr, subject, body = sys.argv[1], sys.argv[2], sys.argv[3]
    files = sys.argv[4:]

    cfg = load_config(Path(__file__).resolve().parent / "config.env")
    host = cfg.get("CBA_SMTP_HOST", "")
    port = int(cfg.get("CBA_SMTP_PORT", "587") or "587")
    user = cfg.get("CBA_SMTP_USER", "")
    pwd = cfg.get("CBA_SMTP_PASS", "")
    sender = cfg.get("CBA_SMTP_FROM", user)

    if not host or not user or not pwd:
        print("SMTP not configured (set CBA_SMTP_HOST/USER/PASS in config.env)")
        return 3

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = to_addr
    msg["Subject"] = subject
    msg.set_content(body)

    for f in files:
        p = Path(f)
        if not p.is_file():
            continue
        data = p.read_bytes()
        # Let EmailMessage guess a reasonable type; default to octet-stream.
        maintype, subtype = "application", "octet-stream"
        if p.suffix in (".md", ".txt", ".csv"):
            maintype, subtype = "text", "plain"
        elif p.suffix == ".json":
            maintype, subtype = "application", "json"
        elif p.suffix == ".pdf":
            maintype, subtype = "application", "pdf"
        msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=p.name)

    try:
        ctx = ssl.create_default_context()
        if port == 465:
            with smtplib.SMTP_SSL(host, port, timeout=60, context=ctx) as s:
                s.login(user, pwd)
                s.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=60) as s:
                s.ehlo()
                s.starttls(context=ctx)
                s.login(user, pwd)
                s.send_message(msg)
    except Exception as e:  # noqa: BLE001
        print(f"send failed: {e}")
        return 1

    print("sent")
    return 0


if __name__ == "__main__":
    sys.exit(main())

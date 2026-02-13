#!/usr/bin/env python3
"""ignite_mime.py — IGNITE MIMEメッセージ構築・パース・CLIラッパー

Python標準ライブラリのみ使用（追加依存なし）。
サブコマンド: build, parse, extract-body, extract-attachment, update-status
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone, timedelta
from email.utils import formatdate, make_msgid


# =========================================================================
# 定数
# =========================================================================
IGNITE_DOMAIN = "ignite.local"
HEADER_PREFIX = "X-IGNITE-"

JST = timezone(timedelta(hours=9))


# =========================================================================
# 構築 (build)
# =========================================================================
def build_message(
    *,
    from_agent: str,
    to_agents: list[str],
    msg_type: str,
    body: str = "",
    cc: list[str] | None = None,
    priority: str = "normal",
    thread_id: str | None = None,
    in_reply_to: str | None = None,
    repo: str | None = None,
    issue: str | None = None,
    status: str | None = None,
) -> str:
    """MIMEメッセージ文字列を構築する（RFC 2045準拠、CTE=8bit）。"""
    msg_id = make_msgid(domain=IGNITE_DOMAIN)
    now = formatdate(localtime=True)

    lines: list[str] = []
    lines.append(f"MIME-Version: 1.0")
    lines.append(f"Message-ID: {msg_id}")
    lines.append(f"From: {from_agent}")
    lines.append(f"To: {', '.join(to_agents)}")
    if cc:
        lines.append(f"Cc: {', '.join(cc)}")
    lines.append(f"Date: {now}")
    lines.append(f"{HEADER_PREFIX}Type: {msg_type}")
    lines.append(f"{HEADER_PREFIX}Priority: {priority}")
    if thread_id:
        lines.append(f"{HEADER_PREFIX}Thread-ID: {thread_id}")
    if in_reply_to:
        lines.append(f"In-Reply-To: {in_reply_to}")
    if repo:
        lines.append(f"{HEADER_PREFIX}Repository: {repo}")
    if issue:
        lines.append(f"{HEADER_PREFIX}Issue: {issue}")
    if status:
        lines.append(f"{HEADER_PREFIX}Status: {status}")
    lines.append("Content-Type: text/x-yaml; charset=utf-8")
    lines.append("Content-Transfer-Encoding: 8bit")
    lines.append("")  # 空行でヘッダーとボディを区切る
    lines.append(body)

    return "\n".join(lines)


# =========================================================================
# パース (parse)
# =========================================================================
def parse_message(raw: str) -> dict:
    """MIMEメッセージ文字列をパースしてdictを返す。"""
    header_part, _, body_part = raw.partition("\n\n")
    if not body_part and "\r\n\r\n" in raw:
        header_part, _, body_part = raw.partition("\r\n\r\n")

    headers: dict[str, str] = {}
    current_key = ""
    for line in header_part.splitlines():
        if line.startswith((" ", "\t")) and current_key:
            # 折り返しヘッダー (continuation)
            headers[current_key] += " " + line.strip()
        elif ":" in line:
            key, _, value = line.partition(":")
            current_key = key.strip()
            headers[current_key] = value.strip()

    # X-IGNITE-* ヘッダーをフラットに展開
    result: dict = {}
    result["message_id"] = headers.get("Message-ID", "")
    result["from"] = headers.get("From", "")

    to_raw = headers.get("To", "")
    result["to"] = [t.strip() for t in to_raw.split(",") if t.strip()]

    cc_raw = headers.get("Cc", "")
    result["cc"] = [c.strip() for c in cc_raw.split(",") if c.strip()] if cc_raw else []

    result["date"] = headers.get("Date", "")
    result["in_reply_to"] = headers.get("In-Reply-To", "")
    result["type"] = headers.get(f"{HEADER_PREFIX}Type", "")
    result["priority"] = headers.get(f"{HEADER_PREFIX}Priority", "normal")
    result["thread_id"] = headers.get(f"{HEADER_PREFIX}Thread-ID", "")
    result["repository"] = headers.get(f"{HEADER_PREFIX}Repository", "")
    result["issue"] = headers.get(f"{HEADER_PREFIX}Issue", "")
    result["status"] = headers.get(f"{HEADER_PREFIX}Status", "")
    result["content_type"] = headers.get("Content-Type", "")
    result["body"] = body_part

    # 追加の X-IGNITE-* ヘッダー（未マッピング分）をキャプチャ
    _mapped_ignite = {"Type", "Priority", "Thread-ID", "Repository", "Issue", "Status"}
    for key, value in headers.items():
        if key.startswith(HEADER_PREFIX):
            short = key[len(HEADER_PREFIX):]
            if short not in _mapped_ignite:
                snake = short.lower().replace("-", "_")
                result[snake] = value

    return result


def extract_body(raw: str) -> str:
    """ボディ部分のみ返す。"""
    _, _, body = raw.partition("\n\n")
    if not body and "\r\n\r\n" in raw:
        _, _, body = raw.partition("\r\n\r\n")
    return body


# =========================================================================
# ステータス更新 (update-status)
# =========================================================================
def update_status(raw: str, new_status: str, **extra_headers: str) -> str:
    """X-IGNITE-Status ヘッダーを追加/更新する。

    追加ヘッダーも **extra_headers で渡せる。
    例: update_status(raw, "delivered", **{"X-IGNITE-Processed-At": "..."})
    """
    header_part, _, body_part = raw.partition("\n\n")
    if not body_part and "\r\n\r\n" in raw:
        header_part, _, body_part = raw.partition("\r\n\r\n")

    lines = header_part.splitlines()
    new_lines: list[str] = []
    status_set = False

    for line in lines:
        if line.startswith(f"{HEADER_PREFIX}Status:"):
            new_lines.append(f"{HEADER_PREFIX}Status: {new_status}")
            status_set = True
        else:
            new_lines.append(line)

    if not status_set:
        new_lines.append(f"{HEADER_PREFIX}Status: {new_status}")

    # 追加ヘッダー
    for key, value in extra_headers.items():
        # 既存行があれば置換、なければ追加
        replaced = False
        for i, line in enumerate(new_lines):
            if line.startswith(f"{key}:"):
                new_lines[i] = f"{key}: {value}"
                replaced = True
                break
        if not replaced:
            new_lines.append(f"{key}: {value}")

    return "\n".join(new_lines) + "\n\n" + body_part


def update_header(raw: str, header_name: str, value: str) -> str:
    """任意のヘッダーを追加/更新する。"""
    header_part, _, body_part = raw.partition("\n\n")
    if not body_part and "\r\n\r\n" in raw:
        header_part, _, body_part = raw.partition("\r\n\r\n")

    lines = header_part.splitlines()
    replaced = False
    for i, line in enumerate(lines):
        if line.startswith(f"{header_name}:"):
            lines[i] = f"{header_name}: {value}"
            replaced = True
            break
    if not replaced:
        lines.append(f"{header_name}: {value}")

    return "\n".join(lines) + "\n\n" + body_part


def remove_header(raw: str, header_name: str) -> str:
    """指定ヘッダーを削除する。"""
    header_part, _, body_part = raw.partition("\n\n")
    if not body_part and "\r\n\r\n" in raw:
        header_part, _, body_part = raw.partition("\r\n\r\n")

    lines = [line for line in header_part.splitlines()
             if not line.startswith(f"{header_name}:")]

    return "\n".join(lines) + "\n\n" + body_part


# =========================================================================
# CLI
# =========================================================================
def cmd_build(args: argparse.Namespace) -> None:
    body = ""
    if args.body_file:
        if args.body_file == "-":
            body = sys.stdin.read()
        else:
            with open(args.body_file, "r", encoding="utf-8") as f:
                body = f.read()
    elif args.body:
        body = args.body

    msg = build_message(
        from_agent=args.from_agent,
        to_agents=args.to,
        msg_type=args.type,
        body=body,
        cc=args.cc,
        priority=args.priority,
        thread_id=args.thread_id,
        in_reply_to=args.in_reply_to,
        repo=args.repo,
        issue=args.issue,
        status=args.status,
    )

    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(msg)
    else:
        sys.stdout.write(msg)


def cmd_parse(args: argparse.Namespace) -> None:
    with open(args.file, "r", encoding="utf-8") as f:
        raw = f.read()
    result = parse_message(raw)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


def cmd_extract_body(args: argparse.Namespace) -> None:
    with open(args.file, "r", encoding="utf-8") as f:
        raw = f.read()
    sys.stdout.write(extract_body(raw))


def cmd_update_status(args: argparse.Namespace) -> None:
    with open(args.file, "r", encoding="utf-8") as f:
        raw = f.read()

    extra: dict[str, str] = {}
    if args.processed_at:
        extra[f"{HEADER_PREFIX}Processed-At"] = args.processed_at
    if args.extra:
        for pair in args.extra:
            k, _, v = pair.partition("=")
            extra[k] = v

    updated = update_status(raw, args.status, **extra)
    with open(args.file, "w", encoding="utf-8") as f:
        f.write(updated)


def cmd_update_header(args: argparse.Namespace) -> None:
    with open(args.file, "r", encoding="utf-8") as f:
        raw = f.read()
    updated = update_header(raw, args.header, args.value)
    with open(args.file, "w", encoding="utf-8") as f:
        f.write(updated)


def cmd_remove_header(args: argparse.Namespace) -> None:
    with open(args.file, "r", encoding="utf-8") as f:
        raw = f.read()
    updated = remove_header(raw, args.header)
    with open(args.file, "w", encoding="utf-8") as f:
        f.write(updated)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="ignite_mime",
        description="IGNITE MIMEメッセージ構築・パース・CLIツール",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # --- build ---
    p_build = sub.add_parser("build", help="MIMEメッセージを構築")
    p_build.add_argument("--from", dest="from_agent", required=True)
    p_build.add_argument("--to", nargs="+", required=True)
    p_build.add_argument("--cc", nargs="*", default=None)
    p_build.add_argument("--type", required=True)
    p_build.add_argument("--priority", default="normal")
    p_build.add_argument("--thread-id", default=None)
    p_build.add_argument("--in-reply-to", default=None)
    p_build.add_argument("--repo", default=None)
    p_build.add_argument("--issue", default=None)
    p_build.add_argument("--status", default=None)
    p_build.add_argument("--body", default=None)
    p_build.add_argument("--body-file", default=None)
    p_build.add_argument("--output", "-o", default=None)
    p_build.set_defaults(func=cmd_build)

    # --- parse ---
    p_parse = sub.add_parser("parse", help="MIMEメッセージをJSON出力")
    p_parse.add_argument("file")
    p_parse.set_defaults(func=cmd_parse)

    # --- extract-body ---
    p_body = sub.add_parser("extract-body", help="ボディのみ出力")
    p_body.add_argument("file")
    p_body.set_defaults(func=cmd_extract_body)

    # --- update-status ---
    p_status = sub.add_parser("update-status", help="X-IGNITE-Statusを更新")
    p_status.add_argument("file")
    p_status.add_argument("status")
    p_status.add_argument("--processed-at", default=None)
    p_status.add_argument("--extra", nargs="*", default=None,
                          help="追加ヘッダー (KEY=VALUE 形式)")
    p_status.set_defaults(func=cmd_update_status)

    # --- update-header ---
    p_uh = sub.add_parser("update-header", help="任意のヘッダーを追加/更新")
    p_uh.add_argument("file")
    p_uh.add_argument("header")
    p_uh.add_argument("value")
    p_uh.set_defaults(func=cmd_update_header)

    # --- remove-header ---
    p_rh = sub.add_parser("remove-header", help="指定ヘッダーを削除")
    p_rh.add_argument("file")
    p_rh.add_argument("header")
    p_rh.set_defaults(func=cmd_remove_header)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

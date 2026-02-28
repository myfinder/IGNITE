#!/usr/bin/env python3
"""
slack_watcher.py — Slack Socket Mode イベントレシーバー

slack-bolt の SocketModeHandler で Slack イベントをリアルタイム受信し、
JSON ファイルとして spool ディレクトリに atomic write する。
Shell ラッパー (slack_watcher.sh) がスプールを定期的に読み取り、
MIME メッセージとして Leader キューに投入する。

IPC: ファイルスプール（JSON）
  - Python が spool ディレクトリに書き込み
  - Shell がポーリングで読み取り・処理後に削除

使い方:
  python3 slack_watcher.py --spool-dir /path/to/spool --config /path/to/config.yaml
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import signal
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

try:
    from slack_bolt import App
    from slack_bolt.adapter.socket_mode import SocketModeHandler
except ImportError:
    print(
        "ERROR: slack-bolt is not installed. "
        "Run: pip install slack-bolt>=1.18.0",
        file=sys.stderr,
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [slack_watcher.py] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stderr,
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# In-memory deduplication (event_ts based)
# ---------------------------------------------------------------------------
_SEEN_EVENTS: Dict[str, float] = {}
_SEEN_EVENTS_MAX = 10000
_SEEN_EVENTS_TTL = 3600  # 1 hour


def _is_duplicate(event_ts: str) -> bool:
    """Check if event_ts has already been seen. Auto-prune old entries."""
    now = time.time()

    # Prune expired entries periodically
    if len(_SEEN_EVENTS) > _SEEN_EVENTS_MAX:
        expired = [k for k, v in _SEEN_EVENTS.items() if now - v > _SEEN_EVENTS_TTL]
        for k in expired:
            del _SEEN_EVENTS[k]

    if event_ts in _SEEN_EVENTS:
        return True

    _SEEN_EVENTS[event_ts] = now
    return False


# ---------------------------------------------------------------------------
# Thread message fetcher
# ---------------------------------------------------------------------------
def _fetch_thread_messages(client, channel: str, thread_ts: str) -> List[dict]:
    """Fetch thread replies via conversations.replies (up to 50 messages)."""
    if not thread_ts:
        return []
    try:
        result = client.conversations_replies(
            channel=channel, ts=thread_ts, limit=50
        )
        return [
            {"user": m.get("user", ""), "text": m.get("text", ""), "ts": m.get("ts", "")}
            for m in result.get("messages", [])
        ]
    except Exception as e:
        logger.warning("Failed to fetch thread: %s", e)
        return []


# ---------------------------------------------------------------------------
# Spool writer (atomic write)
# ---------------------------------------------------------------------------
def _write_spool(spool_dir: Path, event_data: dict) -> None:
    """Write event data to spool directory as a JSON file (atomic)."""
    spool_dir.mkdir(parents=True, exist_ok=True)

    event_ts = event_data.get("event_ts", str(time.time()))
    # Sanitize event_ts for safe filename (digits and dots only)
    safe_ts = re.sub(r"[^0-9.]", "", event_ts) or str(time.time())
    filename = f"slack_event_{safe_ts.replace('.', '_')}.json"
    target = spool_dir / filename

    # Atomic write: write to temp file, then rename
    fd, tmp_path = tempfile.mkstemp(dir=str(spool_dir), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(event_data, f, ensure_ascii=False)
        os.rename(tmp_path, str(target))
        logger.info("Spooled event: %s", filename)
    except Exception:
        # Clean up temp file on error
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Config loader
# ---------------------------------------------------------------------------
def _load_config(config_path: Optional[str]) -> dict:
    """Load watcher config from YAML file."""
    config = {
        "events": {"app_mention": True, "channel_message": False},
        "mention_filter": {"enabled": False, "user_ids": []},
    }
    if not config_path or not os.path.exists(config_path):
        return config

    try:
        import yaml

        with open(config_path) as f:
            data = yaml.safe_load(f) or {}
        if "events" in data:
            config["events"].update(data["events"])
        if "mention_filter" in data:
            mf = data["mention_filter"]
            config["mention_filter"]["enabled"] = bool(mf.get("enabled", False))
            config["mention_filter"]["user_ids"] = [
                str(uid) for uid in (mf.get("user_ids") or [])
            ]
        return config
    except ImportError:
        # yaml not available, try basic parsing
        logger.warning("PyYAML not available, using default config")
        return config
    except Exception as e:
        logger.warning("Failed to load config %s: %s", config_path, e)
        return config


# ---------------------------------------------------------------------------
# Slack App setup
# ---------------------------------------------------------------------------
def _create_app(slack_token: str, spool_dir: Path, config: dict) -> App:
    """Create and configure the Slack Bolt app."""
    app = App(token=slack_token)

    if config["events"].get("app_mention", True):

        @app.event("app_mention")
        def handle_app_mention(event: dict, client, say) -> None:  # noqa: ARG001
            event_ts = event.get("event_ts", "")
            if _is_duplicate(event_ts):
                logger.debug("Duplicate app_mention event: %s", event_ts)
                return

            # Note: Slack event payload does not include channel_name/user_name.
            # Resolving names would require additional API calls (conversations.info,
            # users.info). Phase 1 uses IDs only; name resolution is a future enhancement.
            channel_id = event.get("channel", "")
            thread_ts = event.get("thread_ts", "")
            event_data = {
                "event_type": "app_mention",
                "channel_id": channel_id,
                "user_id": event.get("user", ""),
                "text": event.get("text", ""),
                "thread_ts": thread_ts,
                "event_ts": event_ts,
                "ts": event.get("ts", ""),
                "thread_messages": _fetch_thread_messages(client, channel_id, thread_ts),
            }

            logger.info(
                "app_mention from user=%s in channel=%s",
                event_data["user_id"],
                event_data["channel_id"],
            )
            _write_spool(spool_dir, event_data)

    if config["events"].get("channel_message", False):
        # mention_filter: User Token 使用時に特定ユーザーへの mention のみ処理
        mention_filter = config.get("mention_filter", {})
        mf_enabled = mention_filter.get("enabled", False)
        mf_user_ids = mention_filter.get("user_ids", [])

        @app.event("message")
        def handle_message(event: dict, client) -> None:
            # Skip bot messages and message subtypes (edits, deletes, etc.)
            if event.get("bot_id") or event.get("subtype"):
                return

            # mention_filter が有効な場合、対象ユーザーへの mention を含むメッセージのみ通過
            if mf_enabled and mf_user_ids:
                text = event.get("text", "")
                if not any(f"<@{uid}>" in text for uid in mf_user_ids):
                    return

            event_ts = event.get("event_ts", event.get("ts", ""))
            if _is_duplicate(event_ts):
                return

            channel_id = event.get("channel", "")
            thread_ts = event.get("thread_ts", "")
            event_data = {
                "event_type": "channel_message",
                "channel_id": channel_id,
                "user_id": event.get("user", ""),
                "text": event.get("text", ""),
                "thread_ts": thread_ts,
                "event_ts": event_ts,
                "ts": event.get("ts", ""),
                "thread_messages": _fetch_thread_messages(client, channel_id, thread_ts),
            }

            logger.info(
                "channel_message from user=%s in channel=%s",
                event_data["user_id"],
                event_data["channel_id"],
            )
            _write_spool(spool_dir, event_data)

    return app


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------
_handler: Optional[SocketModeHandler] = None


def _signal_handler(signum: int, frame) -> None:  # noqa: ARG001
    """Handle SIGTERM/SIGINT for graceful shutdown."""
    logger.info("Signal %d received, shutting down...", signum)
    if _handler is not None:
        try:
            _handler.close()
        except Exception as e:
            logger.warning("Error closing handler: %s", e)
    sys.exit(0)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    global _handler

    parser = argparse.ArgumentParser(description="Slack Socket Mode event receiver")
    parser.add_argument(
        "--spool-dir",
        required=True,
        help="Directory to write event JSON files",
    )
    parser.add_argument(
        "--config",
        default=None,
        help="Path to slack-watcher.yaml config file",
    )
    args = parser.parse_args()

    spool_dir = Path(args.spool_dir)

    # Token validation
    slack_token = os.environ.get("SLACK_TOKEN", "")
    app_token = os.environ.get("SLACK_APP_TOKEN", "")

    if not slack_token:
        logger.error("SLACK_TOKEN is not set")
        sys.exit(1)
    if not app_token:
        logger.error("SLACK_APP_TOKEN is not set")
        sys.exit(1)
    if not app_token.startswith("xapp-"):
        logger.error("SLACK_APP_TOKEN must start with 'xapp-' (Socket Mode token)")
        sys.exit(1)

    # Load config
    config = _load_config(args.config)

    # Create Slack app
    app = _create_app(slack_token, spool_dir, config)

    # Setup signal handlers
    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    # Start Socket Mode
    logger.info("Starting Slack Socket Mode receiver...")
    logger.info("Spool directory: %s", spool_dir)
    logger.info("Monitored events: %s", {k: v for k, v in config["events"].items() if v})

    _handler = SocketModeHandler(app, app_token)

    try:
        _handler.start()  # Blocking call
    except KeyboardInterrupt:
        logger.info("KeyboardInterrupt received, shutting down...")
    except Exception as e:
        logger.error("Socket Mode error: %s", e)
        sys.exit(1)
    finally:
        if _handler is not None:
            try:
                _handler.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()

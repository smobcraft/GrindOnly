import sqlite3
from pathlib import Path
from typing import Optional


SCHEMA_VERSION = "4"


class BotState:
    def __init__(self, database_path: Path):
        self.database_path = Path(database_path)

    def connect(self) -> sqlite3.Connection:
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(str(self.database_path), timeout=5)
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA journal_mode = WAL")
        return connection

    def initialize(self) -> None:
        connection = self.connect()
        try:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE IF NOT EXISTS submission_records (
                    interaction_id TEXT PRIMARY KEY,
                    fingerprint TEXT,
                    github_issue_number INTEGER,
                    github_issue_url TEXT,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE IF NOT EXISTS delivery_cursors (
                    name TEXT PRIMARY KEY,
                    cursor TEXT,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE IF NOT EXISTS approval_records (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    issue_number INTEGER NOT NULL,
                    issue_url TEXT NOT NULL,
                    issue_revision_hash TEXT NOT NULL,
                    approver_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE IF NOT EXISTS notification_outbox (
                    event_key TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    message TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    attempts INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    delivered_at TEXT
                );

                CREATE TABLE IF NOT EXISTS tracked_issues (
                    issue_number INTEGER PRIMARY KEY,
                    status_signature TEXT NOT NULL,
                    title TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS seen_releases (
                    release_id TEXT PRIMARY KEY,
                    tag_name TEXT NOT NULL,
                    seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );

                CREATE UNIQUE INDEX IF NOT EXISTS submission_records_fingerprint
                    ON submission_records(fingerprint)
                    WHERE fingerprint IS NOT NULL;
                """
            )
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=CURRENT_TIMESTAMP",
                ("schema_version", SCHEMA_VERSION),
            )
            connection.commit()
        finally:
            connection.close()

    def get_meta(self, key: str) -> Optional[str]:
        connection = self.connect()
        try:
            row = connection.execute(
                "SELECT value FROM metadata WHERE key = ?", (key,)
            ).fetchone()
            return None if row is None else str(row[0])
        finally:
            connection.close()

    def set_meta(self, key: str, value: str) -> None:
        connection = self.connect()
        try:
            connection.execute(
                "INSERT INTO metadata(key, value) VALUES(?, ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=CURRENT_TIMESTAMP",
                (key, value),
            )
            connection.commit()
        finally:
            connection.close()

    def claim_submission(self, interaction_id, fingerprint):
        connection = self.connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT interaction_id, status, github_issue_number, github_issue_url "
                "FROM submission_records WHERE fingerprint = ?",
                (fingerprint,),
            ).fetchone()
            if existing is not None:
                connection.commit()
                return existing

            connection.execute(
                "INSERT INTO submission_records("
                "interaction_id, fingerprint, status"
                ") VALUES(?, ?, ?)",
                (interaction_id, fingerprint, "pending"),
            )
            connection.commit()
            return None
        finally:
            connection.close()

    def complete_submission(self, interaction_id, status, issue_number=None, issue_url=None):
        connection = self.connect()
        try:
            connection.execute(
                "UPDATE submission_records "
                "SET status = ?, github_issue_number = ?, github_issue_url = ?, "
                "updated_at = CURRENT_TIMESTAMP "
                "WHERE interaction_id = ?",
                (status, issue_number, issue_url, interaction_id),
            )
            connection.commit()
        finally:
            connection.close()

    def get_submission(self, interaction_id):
        connection = self.connect()
        try:
            return connection.execute(
                "SELECT interaction_id, status, github_issue_number, github_issue_url "
                "FROM submission_records WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()
        finally:
            connection.close()

    def create_approval(self, issue_number, issue_url, revision_hash, approver_id):
        connection = self.connect()
        try:
            cursor = connection.execute(
                "INSERT INTO approval_records("
                "issue_number, issue_url, issue_revision_hash, approver_id, status"
                ") VALUES(?, ?, ?, ?, ?)",
                (
                    issue_number,
                    issue_url,
                    revision_hash,
                    str(approver_id),
                    "pending",
                ),
            )
            connection.commit()
            return cursor.lastrowid
        finally:
            connection.close()

    def set_approval_status(self, approval_id, status):
        connection = self.connect()
        try:
            connection.execute(
                "UPDATE approval_records "
                "SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
                (status, approval_id),
            )
            connection.commit()
        finally:
            connection.close()

    def get_approval(self, approval_id):
        connection = self.connect()
        try:
            return connection.execute(
                "SELECT id, issue_number, issue_url, issue_revision_hash, "
                "approver_id, status, created_at, updated_at "
                "FROM approval_records WHERE id = ?",
                (approval_id,),
            ).fetchone()
        finally:
            connection.close()

    def find_approved_revision(self, issue_number, revision_hash):
        connection = self.connect()
        try:
            return connection.execute(
                "SELECT id, issue_number, issue_url, issue_revision_hash, "
                "approver_id, status, created_at, updated_at "
                "FROM approval_records "
                "WHERE issue_number = ? AND issue_revision_hash = ? "
                "AND status = 'approved' ORDER BY id DESC LIMIT 1",
                (issue_number, revision_hash),
            ).fetchone()
        finally:
            connection.close()

    def get_cursor(self, name):
        connection = self.connect()
        try:
            row = connection.execute(
                "SELECT cursor FROM delivery_cursors WHERE name = ?",
                (name,),
            ).fetchone()
            return None if row is None else row[0]
        finally:
            connection.close()

    def set_cursor(self, name, cursor_value):
        connection = self.connect()
        try:
            connection.execute(
                "INSERT INTO delivery_cursors(name, cursor) VALUES(?, ?) "
                "ON CONFLICT(name) DO UPDATE SET "
                "cursor=excluded.cursor, updated_at=CURRENT_TIMESTAMP",
                (name, cursor_value),
            )
            connection.commit()
        finally:
            connection.close()

    def get_issue_signature(self, issue_number):
        connection = self.connect()
        try:
            row = connection.execute(
                "SELECT status_signature FROM tracked_issues WHERE issue_number = ?",
                (issue_number,),
            ).fetchone()
            return None if row is None else row[0]
        finally:
            connection.close()

    def baseline_releases(self, releases):
        connection = self.connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            for release in releases:
                connection.execute(
                    "INSERT OR IGNORE INTO seen_releases(release_id, tag_name) "
                    "VALUES(?, ?)",
                    (str(release["id"]), release.get("tag_name") or ""),
                )
            connection.execute(
                "INSERT INTO delivery_cursors(name, cursor) VALUES(?, ?) "
                "ON CONFLICT(name) DO UPDATE SET "
                "cursor=excluded.cursor, updated_at=CURRENT_TIMESTAMP",
                ("baseline_releases", "complete"),
            )
            connection.commit()
        finally:
            connection.close()

    def record_releases(self, releases, messages):
        connection = self.connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            for release, message in zip(releases, messages):
                cursor = connection.execute(
                    "INSERT OR IGNORE INTO seen_releases(release_id, tag_name) "
                    "VALUES(?, ?)",
                    (str(release["id"]), release.get("tag_name") or ""),
                )
                if cursor.rowcount:
                    connection.execute(
                        "INSERT OR IGNORE INTO notification_outbox("
                        "event_key, kind, message"
                        ") VALUES(?, ?, ?)",
                        (f"release:{release['id']}", "release", message),
                    )
            connection.commit()
        finally:
            connection.close()

    def baseline_issues(self, issues, cursor_value):
        connection = self.connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            for issue, signature in issues:
                connection.execute(
                    "INSERT INTO tracked_issues("
                    "issue_number, status_signature, title, updated_at"
                    ") VALUES(?, ?, ?, ?) "
                    "ON CONFLICT(issue_number) DO UPDATE SET "
                    "status_signature=excluded.status_signature, "
                    "title=excluded.title, updated_at=excluded.updated_at",
                    (
                        issue["number"],
                        signature,
                        issue.get("title") or "",
                        issue.get("updated_at") or cursor_value,
                    ),
                )
            connection.execute(
                "INSERT INTO delivery_cursors(name, cursor) VALUES(?, ?) "
                "ON CONFLICT(name) DO UPDATE SET "
                "cursor=excluded.cursor, updated_at=CURRENT_TIMESTAMP",
                ("baseline_issues", "complete"),
            )
            connection.execute(
                "INSERT INTO delivery_cursors(name, cursor) VALUES(?, ?) "
                "ON CONFLICT(name) DO UPDATE SET "
                "cursor=excluded.cursor, updated_at=CURRENT_TIMESTAMP",
                ("issue_updated_at", cursor_value),
            )
            connection.commit()
        finally:
            connection.close()

    def record_issue_changes(self, issues, cursor_value, messages):
        connection = self.connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            for (issue, signature), message in zip(issues, messages):
                if "pull_request" in issue:
                    continue
                issue_number = int(issue["number"])
                previous = connection.execute(
                    "SELECT status_signature FROM tracked_issues "
                    "WHERE issue_number = ?",
                    (issue_number,),
                ).fetchone()
                changed = previous is None or previous[0] != signature
                connection.execute(
                    "INSERT INTO tracked_issues("
                    "issue_number, status_signature, title, updated_at"
                    ") VALUES(?, ?, ?, ?) "
                    "ON CONFLICT(issue_number) DO UPDATE SET "
                    "status_signature=excluded.status_signature, "
                    "title=excluded.title, updated_at=excluded.updated_at",
                    (
                        issue_number,
                        signature,
                        issue.get("title") or "",
                        issue.get("updated_at") or cursor_value,
                    ),
                )
                if changed:
                    event_key = (
                        f"issue:{issue_number}:"
                        f"{issue.get('updated_at') or cursor_value}:{signature}"
                    )
                    connection.execute(
                        "INSERT OR IGNORE INTO notification_outbox("
                        "event_key, kind, message"
                        ") VALUES(?, ?, ?)",
                        (event_key, "issue", message),
                    )
            if cursor_value:
                connection.execute(
                    "INSERT INTO delivery_cursors(name, cursor) VALUES(?, ?) "
                    "ON CONFLICT(name) DO UPDATE SET "
                    "cursor=excluded.cursor, updated_at=CURRENT_TIMESTAMP",
                    ("issue_updated_at", cursor_value),
                )
            connection.commit()
        finally:
            connection.close()

    def pending_notifications(self, limit=100):
        connection = self.connect()
        try:
            return connection.execute(
                "SELECT event_key, kind, message, attempts "
                "FROM notification_outbox WHERE status = 'pending' "
                "ORDER BY created_at, event_key LIMIT ?",
                (limit,),
            ).fetchall()
        finally:
            connection.close()

    def pending_notification_count(self):
        connection = self.connect()
        try:
            row = connection.execute(
                "SELECT COUNT(*) FROM notification_outbox WHERE status = 'pending'"
            ).fetchone()
            return int(row[0])
        finally:
            connection.close()

    def mark_notification_delivered(self, event_key):
        connection = self.connect()
        try:
            connection.execute(
                "UPDATE notification_outbox SET status = 'delivered', "
                "delivered_at = CURRENT_TIMESTAMP WHERE event_key = ?",
                (event_key,),
            )
            connection.commit()
        finally:
            connection.close()

    def mark_notification_attempt_failed(self, event_key):
        connection = self.connect()
        try:
            connection.execute(
                "UPDATE notification_outbox SET attempts = attempts + 1 "
                "WHERE event_key = ? AND status = 'pending'",
                (event_key,),
            )
            connection.commit()
        finally:
            connection.close()

import json
import logging
from datetime import datetime, timezone
from urllib.parse import quote

import aiohttp
import discord


LOGGER = logging.getLogger(__name__)
PAGE_SIZE = 100


class GitHubResponseError(Exception):
    pass


class NotificationDeliveryError(Exception):
    pass


def issue_status_signature(issue):
    labels = sorted(
        label.get("name", "")
        for label in issue.get("labels", [])
        if isinstance(label, dict) and isinstance(label.get("name"), str)
    )
    signature = {
        "labels": labels,
        "state": issue.get("state") or "",
        "state_reason": issue.get("state_reason") or "",
    }
    return json.dumps(signature, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _escaped(value, limit):
    text = discord.utils.escape_markdown(str(value or ""))
    return text[:limit]


def _release_message(repository, release):
    name = release.get("name") or release.get("tag_name") or "New release"
    tag = release.get("tag_name") or ""
    tag_path = quote(tag, safe="")
    url = f"https://github.com/{repository}/releases/tag/{tag_path}"
    return f"New Grind Only release: **{_escaped(name, 180)}** (`{_escaped(tag, 80)}`)\n{url}"


def _issue_message(repository, issue, previous_signature):
    number = int(issue["number"])
    title = _escaped(issue.get("title") or "Untitled issue", 160)
    labels = sorted(
        label.get("name", "")
        for label in issue.get("labels", [])
        if isinstance(label, dict) and isinstance(label.get("name"), str)
    )
    state = _escaped(issue.get("state") or "unknown", 30)
    rendered_labels = ", ".join(_escaped(label, 60) for label in labels[:12]) or "none"
    prefix = "New issue" if previous_signature is None else "Issue status updated"
    url = f"https://github.com/{repository}/issues/{number}"
    return (
        f"{prefix} #{number}: **{title}**\n"
        f"State: {state} · Labels: {rendered_labels}\n{url}"
    )


def _utc_timestamp():
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


class NotificationPoller:
    def __init__(self, state, github, deliver, repository):
        self.state = state
        self.github = github
        self.deliver = deliver
        self.repository = repository
        self.last_poll_at = None
        self.last_poll_status = "not yet polled"
        self.consecutive_failures = 0
        self._poll_failed = False

    def backoff_seconds(self, base_interval):
        if self.consecutive_failures == 0:
            return base_interval
        exponent = min(self.consecutive_failures, 10)
        return min(base_interval * (2 ** exponent), max(base_interval, 3600))

    async def _repository_is_public(self):
        try:
            repository = await self.github("GET", "")
        except (aiohttp.ClientError, TimeoutError, GitHubResponseError) as error:
            self._poll_failed = True
            LOGGER.warning("GitHub visibility check failed (%s)", type(error).__name__)
            return False
        if not isinstance(repository, dict) or repository.get("private") is not False:
            LOGGER.warning("GitHub notifications paused because public visibility was not confirmed")
            return False
        return True

    async def _fetch_pages(self, path, params):
        results = []
        page = 1
        while True:
            page_params = dict(params)
            page_params.update({"per_page": PAGE_SIZE, "page": page})
            result = await self.github("GET", path, params=page_params)
            if not isinstance(result, list):
                raise GitHubResponseError("GitHub returned an unexpected list response")
            results.extend(result)
            if len(result) < PAGE_SIZE:
                return results
            page += 1

    async def _poll_releases(self):
        try:
            releases = await self._fetch_pages("/releases", {})
        except (aiohttp.ClientError, TimeoutError, GitHubResponseError) as error:
            self._poll_failed = True
            LOGGER.warning("GitHub release poll failed (%s)", type(error).__name__)
            return

        stable = [
            release
            for release in releases
            if isinstance(release, dict)
            and release.get("id") is not None
            and release.get("published_at")
            and not release.get("draft")
            and not release.get("prerelease")
        ]
        stable.sort(key=lambda release: release.get("published_at") or "")

        if self.state.get_cursor("baseline_releases") is None:
            self.state.baseline_releases(stable)
            return

        messages = [
            _release_message(self.repository, release)
            for release in stable
        ]
        self.state.record_releases(stable, messages)

    async def _poll_issues(self):
        if self.state.get_cursor("baseline_issues") is None:
            baseline_started = _utc_timestamp()
            try:
                issues = await self._fetch_pages(
                    "/issues",
                    {"state": "all", "sort": "updated", "direction": "asc"},
                )
            except (aiohttp.ClientError, TimeoutError, GitHubResponseError) as error:
                self._poll_failed = True
                LOGGER.warning("GitHub issue baseline failed (%s)", type(error).__name__)
                return

            snapshots = [
                (issue, issue_status_signature(issue))
                for issue in issues
                if isinstance(issue, dict)
                and "pull_request" not in issue
                and issue.get("number") is not None
            ]
            self.state.baseline_issues(snapshots, baseline_started)
            return

        cursor = self.state.get_cursor("issue_updated_at")
        if cursor is None:
            LOGGER.warning("Issue polling cursor is missing; baseline required")
            return

        try:
            issues = await self._fetch_pages(
                "/issues",
                {
                    "state": "all",
                    "sort": "updated",
                    "direction": "asc",
                    "since": cursor,
                },
            )
        except (aiohttp.ClientError, TimeoutError, GitHubResponseError) as error:
            self._poll_failed = True
            LOGGER.warning("GitHub issue poll failed (%s)", type(error).__name__)
            return

        valid_issues = [
            issue
            for issue in issues
            if isinstance(issue, dict) and issue.get("number") is not None
        ]
        updated_times = [
            issue["updated_at"]
            for issue in valid_issues
            if isinstance(issue.get("updated_at"), str)
        ]
        next_cursor = max(updated_times) if updated_times else None
        tracked = [
            issue for issue in valid_issues if "pull_request" not in issue
        ]
        snapshots = [
            (issue, issue_status_signature(issue))
            for issue in tracked
        ]
        messages = [
            _issue_message(
                self.repository,
                issue,
                self.state.get_issue_signature(issue["number"]),
            )
            for issue in tracked
        ]
        self.state.record_issue_changes(snapshots, next_cursor, messages)

    async def _deliver_pending(self):
        for event_key, kind, message, attempts in self.state.pending_notifications():
            try:
                await self.deliver(message)
            except (
                aiohttp.ClientError,
                TimeoutError,
                discord.HTTPException,
                NotificationDeliveryError,
            ) as error:
                self._poll_failed = True
                self.state.mark_notification_attempt_failed(event_key)
                LOGGER.warning(
                    "Discord notification delivery failed (kind=%s, attempt=%s, error=%s)",
                    kind,
                    attempts + 1,
                    type(error).__name__,
                )
            else:
                self.state.mark_notification_delivered(event_key)

    async def poll_once(self):
        self._poll_failed = False
        if not await self._repository_is_public():
            self.last_poll_at = _utc_timestamp()
            if self._poll_failed:
                self.consecutive_failures = min(self.consecutive_failures + 1, 10)
                self.last_poll_status = "degraded"
                return False
            self.consecutive_failures = 0
            self.last_poll_status = "visibility unconfirmed"
            return True
        await self._poll_releases()
        await self._poll_issues()
        await self._deliver_pending()
        self.last_poll_at = _utc_timestamp()
        if self._poll_failed:
            self.consecutive_failures = min(self.consecutive_failures + 1, 10)
            self.last_poll_status = "degraded"
            return False
        self.consecutive_failures = 0
        self.last_poll_status = "ok"
        return True

import asyncio
import os
import logging
import discord
from discord import app_commands
from discord.ext import tasks
import aiohttp
from urllib.parse import urlsplit
from dotenv import load_dotenv
from pathlib import Path
from config import load_config
from state import BotState
from submissions import normalized_issue_title, normalize_text, submission_fingerprint
from approvals import issue_revision_hash
from notifications import NotificationDeliveryError, NotificationPoller
from instance_lock import AlreadyRunningError, InstanceLock
from logging_setup import configure_logging

load_dotenv(Path(__file__).with_name('.env'))
CONFIG = load_config()
GUILD = CONFIG.guild_id
CHANNEL = CONFIG.feedback_channel_id
REPO = 'smobcraft/GrindOnly'
BASE = 'https://api.github.com/repos/' + REPO
TOKEN = CONFIG.github_token
DOWNLOAD = f'https://github.com/{REPO}/releases/latest/download/GrindOnly.zip'
guild = discord.Object(id=GUILD)
STATE = BotState(CONFIG.database_path)

class Client(discord.Client):
    async def setup_hook(self):
        STATE.initialize()
        await tree.sync(guild=guild)
        notification_poll.change_interval(seconds=CONFIG.poll_interval_seconds)
        notification_poll.start()

    async def close(self):
        poll_task = notification_poll.get_task()
        if notification_poll.is_running():
            notification_poll.cancel()
        try:
            if poll_task is not None:
                await poll_task
        except asyncio.CancelledError:
            pass
        finally:
            await super().close()

client = Client(intents=discord.Intents.default())
class RestrictedTree(app_commands.CommandTree):
    async def interaction_check(self, interaction):
        if interaction.guild_id == GUILD and interaction.channel_id == CHANNEL:
            return True
        await interaction.response.send_message('Use the Grind Only feedback channel.', ephemeral=True)
        return False

tree = RestrictedTree(client)

async def github(method, path, **kwargs):
    headers = {'Authorization': 'Bearer '+TOKEN, 'Accept':'application/vnd.github+json', 'X-GitHub-Api-Version':'2022-11-28'}
    async with aiohttp.ClientSession(headers=headers, timeout=aiohttp.ClientTimeout(total=20)) as session:
        async with session.request(method, BASE+path, **kwargs) as response:
            response.raise_for_status()
            return await response.json()

async def deliver_notification(message):
    channel_id = CONFIG.updates_channel_id or CHANNEL
    channel = client.get_channel(channel_id)
    if channel is None:
        channel = await client.fetch_channel(channel_id)
    channel_guild = getattr(channel, 'guild', None)
    if (
        channel_guild is None
        or channel_guild.id != GUILD
        or not hasattr(channel, 'send')
    ):
        raise NotificationDeliveryError('Configured notification destination is not messageable')
    await channel.send(
        message,
        allowed_mentions=discord.AllowedMentions.none(),
    )

NOTIFICATION_POLLER = NotificationPoller(
    STATE,
    github,
    deliver_notification,
    REPO,
)

IMAGE_CONTENT_TYPES = {'image/png', 'image/jpeg', 'image/gif', 'image/webp'}
DISCORD_ATTACHMENT_HOSTS = {'cdn.discordapp.com', 'media.discordapp.net'}
CONTEXT_DETAILS_MAX_LENGTH = 4000


def discord_image_urls(attachments):
    urls = []
    for attachment in attachments:
        content_type = (
            (getattr(attachment, 'content_type', None) or '')
            .split(';', 1)[0]
            .strip()
            .lower()
        )
        if content_type not in IMAGE_CONTENT_TYPES:
            continue
        url = getattr(attachment, 'url', '')
        try:
            parsed = urlsplit(url)
            valid_url = (
                parsed.scheme == 'https'
                and parsed.hostname in DISCORD_ATTACHMENT_HOSTS
                and parsed.path.startswith('/attachments/')
                and parsed.username is None
                and parsed.password is None
                and parsed.port in (None, 443)
                and not parsed.fragment
                and not any(ord(character) < 32 for character in url)
            )
        except ValueError:
            valid_url = False
        if not valid_url:
            raise ValueError('Discord image attachment URL is invalid')
        urls.append(url)
    return urls


def context_details(source_text, image_urls):
    text = source_text.strip()
    if not image_urls:
        if len(text) > 1800:
            return text[:1788] + '\n[truncated]', 1800, True
        return text, 1800, False

    image_section = (
        'Discord-hosted images (links may expire; other files are not included):\n\n'
        + '\n'.join(
            f'![Discord image {index}](<{url}>)'
            for index, url in enumerate(image_urls, start=1)
        )
    )
    if len(image_section) > CONTEXT_DETAILS_MAX_LENGTH:
        raise ValueError('Image links exceed the Discord preview limit')

    available_text = CONTEXT_DETAILS_MAX_LENGTH - len(image_section)
    separator = '\n\n' if text else ''
    available_text -= len(separator)
    if available_text < 0:
        raise ValueError('Image links leave no room for the preview')
    truncated = len(text) > available_text
    if truncated:
        marker = '\n[truncated]'
        if available_text < len(marker):
            raise ValueError('Image links leave no room for the preview')
        text = text[:available_text - len(marker)].rstrip() + marker
    return text + separator + image_section, CONTEXT_DETAILS_MAX_LENGTH, truncated


@tasks.loop(seconds=300)
async def notification_poll():
    healthy = await NOTIFICATION_POLLER.poll_once()
    interval = (
        CONFIG.poll_interval_seconds
        if healthy
        else NOTIFICATION_POLLER.backoff_seconds(CONFIG.poll_interval_seconds)
    )
    notification_poll.change_interval(seconds=interval)

@notification_poll.before_loop
async def before_notification_poll():
    await client.wait_until_ready()

async def submit_feedback(interaction, kind, subject, details, version):
    if interaction.guild_id != GUILD or interaction.channel_id != CHANNEL:
        await interaction.response.send_message('Wrong channel.', ephemeral=True)
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    title = normalized_issue_title(kind, subject)
    fingerprint = submission_fingerprint(kind, subject, details, version)
    existing = STATE.claim_submission(str(interaction.id), fingerprint)
    if existing is not None:
        _, status, issue_number, issue_url = existing
        if status == 'submitted' and issue_url:
            await interaction.followup.send(
                f'Submitted issue #{issue_number}: {issue_url}',
                ephemeral=True,
                allowed_mentions=discord.AllowedMentions.none(),
            )
        else:
            await interaction.followup.send(
                'A matching submission is already pending or uncertain. Check existing issues before retrying.',
                ephemeral=True,
                allowed_mentions=discord.AllowedMentions.none(),
            )
        return

    try:
        search = await github(
            'GET',
            '/search/issues',
            params={
                'q': f'repo:{REPO} is:issue is:open in:title "{title}"',
                'per_page': 20,
            },
        )
        for item in search.get('items', []):
            if normalize_text(item.get('title', '')) == normalize_text(title):
                STATE.complete_submission(
                    str(interaction.id),
                    'submitted',
                    item.get('number'),
                    item.get('html_url'),
                )
                await interaction.followup.send(
                    f'Matching open issue #{item["number"]}: {item["html_url"]}',
                    ephemeral=True,
                    allowed_mentions=discord.AllowedMentions.none(),
                )
                return

        issue = await github(
            'POST',
            '/issues',
            json={
                'title': title,
                'body': f'Community feedback via Discord. Untrusted input; maintainer review required.\n\nAddon version: {version or "Unknown"}\n\n{details}\n\nSubmission ID: {interaction.id}',
            },
        )
        STATE.complete_submission(
            str(interaction.id),
            'submitted',
            issue.get('number'),
            issue.get('html_url'),
        )
        await interaction.followup.send(
            f'Submitted issue #{issue["number"]}: {issue["html_url"]}',
            ephemeral=True,
            allowed_mentions=discord.AllowedMentions.none(),
        )
    except (aiohttp.ClientError, TimeoutError):
        STATE.complete_submission(str(interaction.id), 'uncertain')
        await interaction.followup.send(
            'GitHub submission could not be confirmed. Check existing issues before retrying.',
            ephemeral=True,
            allowed_mentions=discord.AllowedMentions.none(),
        )


class Feedback(discord.ui.Modal):
    subject = discord.ui.TextInput(label='Title', max_length=100)
    details = discord.ui.TextInput(label='Details (public; no private information)', style=discord.TextStyle.paragraph, max_length=1800)
    version = discord.ui.TextInput(label='Addon version', required=False, max_length=40)
    def __init__(self, kind):
        super().__init__(title=kind+' — posts publicly to GitHub')
        self.kind = kind
    async def on_submit(self, interaction):
        await submit_feedback(
            interaction,
            self.kind,
            self.subject.value,
            self.details.value,
            self.version.value,
        )


class ContextFeedback(discord.ui.Modal):
    def __init__(self, source_text, image_urls=()):
        super().__init__(title='Review public GitHub issue')
        self.kind = 'Feedback'
        first_line = next(
            (line.strip() for line in source_text.splitlines() if line.strip()),
            'Feedback from Discord',
        )
        title_truncated = len(first_line) > 100
        details_text, details_max_length, details_truncated = context_details(
            source_text,
            image_urls,
        )
        self.subject = discord.ui.TextInput(
            label=(
                'Public title (truncated; editable)'
                if title_truncated
                else 'Public title (editable)'
            ),
            default=first_line[:100],
            max_length=100,
        )
        self.details = discord.ui.TextInput(
            label=(
                'Public details (truncated; editable)'
                if details_truncated
                else 'Public details and image links (editable)'
            ),
            style=discord.TextStyle.paragraph,
            default=details_text,
            max_length=details_max_length,
        )
        self.version = discord.ui.TextInput(
            label='Addon version (optional)',
            required=False,
            max_length=40,
        )
        self.add_item(self.subject)
        self.add_item(self.details)
        self.add_item(self.version)

    async def on_submit(self, interaction):
        await submit_feedback(
            interaction,
            self.kind,
            self.subject.value,
            self.details.value,
            self.version.value,
        )


@tree.context_menu(
    name='Submit my message as feedback',
    guild=guild,
)
async def submit_own_message(
    interaction: discord.Interaction,
    message: discord.Message,
):
    if interaction.guild_id != GUILD or interaction.channel_id != CHANNEL:
        await interaction.response.send_message(
            'Use the Grind Only feedback channel.',
            ephemeral=True,
        )
        return
    if (
        message.guild_id != GUILD
        or message.channel.id != CHANNEL
    ):
        await interaction.response.send_message(
            'Only messages from the Grind Only feedback channel can be submitted.',
            ephemeral=True,
        )
        return
    if message.author.id != interaction.user.id:
        await interaction.response.send_message(
            'You can only submit your own message.',
            ephemeral=True,
        )
        return
    try:
        image_urls = discord_image_urls(getattr(message, 'attachments', ()))
    except ValueError:
        await interaction.response.send_message(
            'An image attachment URL could not be validated. No issue was created.',
            ephemeral=True,
        )
        return
    if not message.content.strip() and not image_urls:
        await interaction.response.send_message(
            'This message has no text or supported image to preview. PNG, JPEG, GIF, and WebP images are supported; other files are not included.',
            ephemeral=True,
        )
        return

    try:
        modal = ContextFeedback(message.content, image_urls)
    except ValueError:
        await interaction.response.send_message(
            'These image links are too long to preview safely. Submit fewer images.',
            ephemeral=True,
        )
        return
    await interaction.response.send_modal(modal)


@tree.command(guild=guild, description='Report a bug publicly on GitHub')
async def bug(interaction: discord.Interaction):
    await interaction.response.send_modal(Feedback('Bug'))

@tree.command(guild=guild, description='Suggest a feature publicly on GitHub')
async def suggest(interaction: discord.Interaction):
    await interaction.response.send_modal(Feedback('Suggestion'))

@tree.command(guild=guild, description='Submit general feedback publicly on GitHub')
async def feedback(interaction: discord.Interaction):
    await interaction.response.send_modal(Feedback('Feedback'))

@tree.command(guild=guild, description='Download the latest stable addon')
async def latest(interaction: discord.Interaction):
    await interaction.response.send_message(DOWNLOAD, ephemeral=True)

@tree.command(guild=guild, description='Check a GitHub issue')
async def status(interaction: discord.Interaction, number: int):
    await interaction.response.defer(ephemeral=True)
    try:
        issue = await github('GET', f'/issues/{number}')
        await interaction.followup.send(f'#{number}: {issue["state"]}\n{issue["html_url"]}', ephemeral=True)
    except (aiohttp.ClientError, TimeoutError):
        await interaction.followup.send('Unable to retrieve issue.', ephemeral=True)

@tree.command(guild=guild, description='Check bot and notification health')
async def health(interaction: discord.Interaction):
    last_poll = NOTIFICATION_POLLER.last_poll_at or 'not yet run'
    pending = STATE.pending_notification_count()
    await interaction.response.send_message(
        f'Bot online. GitHub notification poll: {NOTIFICATION_POLLER.last_poll_status}. '
        f'Last poll: {last_poll}. Pending Discord notifications: {pending}.',
        ephemeral=True,
    )

@tree.command(guild=guild, description='Approve an open issue for maintainer review')
async def approve(interaction: discord.Interaction, number: int):
    if interaction.guild_id != GUILD or interaction.channel_id != CHANNEL:
        await interaction.response.send_message(
            'Use the Grind Only feedback channel.',
            ephemeral=True,
        )
        return
    if number <= 0:
        await interaction.response.send_message(
            'Issue number must be positive.',
            ephemeral=True,
        )
        return
    if CONFIG.maintainer_id is None:
        await interaction.response.send_message(
            'Approvals are disabled because the maintainer ID is not configured.',
            ephemeral=True,
        )
        return
    if interaction.user.id != CONFIG.maintainer_id:
        await interaction.response.send_message(
            'Only the configured maintainer can approve issues.',
            ephemeral=True,
        )
        return

    await interaction.response.defer(ephemeral=True, thinking=True)
    try:
        issue = await github('GET', f'/issues/{number}')
    except (aiohttp.ClientError, TimeoutError):
        await interaction.followup.send(
            'Unable to verify the issue; no approval was recorded.',
            ephemeral=True,
        )
        return

    if issue.get('state') != 'open' or 'pull_request' in issue:
        await interaction.followup.send(
            'Only open issues can be approved.',
            ephemeral=True,
        )
        return

    revision_hash = issue_revision_hash(
        REPO,
        number,
        issue.get('title'),
        issue.get('body'),
    )
    approval_id = STATE.create_approval(
        number,
        issue.get('html_url', ''),
        revision_hash,
        interaction.user.id,
    )

    try:
        await github(
            'POST',
            f'/issues/{number}/labels',
            json={'labels': ['ai-ready']},
        )
    except (aiohttp.ClientError, TimeoutError):
        STATE.set_approval_status(approval_id, 'uncertain')
        await interaction.followup.send(
            'The label update could not be confirmed. Approval is not valid; inspect the issue before retrying.',
            ephemeral=True,
            allowed_mentions=discord.AllowedMentions.none(),
        )
        return

    STATE.set_approval_status(approval_id, 'approved')
    await interaction.followup.send(
        f'Issue #{number} approved for review. Revision: `{revision_hash}`. '
        'This does not authorize automated execution.',
        ephemeral=True,
        allowed_mentions=discord.AllowedMentions.none(),
    )

@tree.command(guild=guild, description='View latest release notes')
async def changelog(interaction: discord.Interaction):
    await interaction.response.send_message(f'https://github.com/{REPO}/releases/latest', ephemeral=True)

@tree.command(guild=guild, description='Show Grind Only commands')
async def help(interaction: discord.Interaction):
    await interaction.response.send_message(
        '/bug, /suggest, /feedback, /latest, /status, /health, /approve, /changelog. '
        'You can also right-click your own feedback-channel message and choose '
        '"Submit my message as feedback". Review the editable preview before '
        'submitting; submissions are public on GitHub.',
        ephemeral=True,
    )

def main():
    configure_logging(
        Path(__file__).with_name('logs'),
        (CONFIG.discord_token, CONFIG.github_token),
    )
    lock = InstanceLock(CONFIG.database_path.with_name('bot-instance.lock'))
    try:
        lock.acquire()
    except AlreadyRunningError:
        logging.getLogger(__name__).error(
            'Bot startup prevented: another instance is already running'
        )
        raise SystemExit(1)
    try:
        client.run(CONFIG.discord_token, log_handler=None)
    finally:
        lock.release()


if __name__ == '__main__':
    main()

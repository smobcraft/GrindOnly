import os
import logging
import discord
from discord import app_commands
import aiohttp
from dotenv import load_dotenv
from pathlib import Path

load_dotenv(Path(__file__).with_name('.env'))
GUILD = int(os.getenv('DISCORD_GUILD_ID', '542025981288906772'))
CHANNEL = int(os.getenv('DISCORD_FEEDBACK_CHANNEL_ID', '1575205316977754122'))
REPO = 'smobcraft/GrindOnly'
BASE = 'https://api.github.com/repos/' + REPO
TOKEN = os.environ['GITHUB_TOKEN']
DOWNLOAD = f'https://github.com/{REPO}/releases/latest/download/GrindOnly.zip'
guild = discord.Object(id=GUILD)

class Client(discord.Client):
    async def setup_hook(self):
        await tree.sync(guild=guild)

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

class Feedback(discord.ui.Modal):
    subject = discord.ui.TextInput(label='Title', max_length=100)
    details = discord.ui.TextInput(label='Details (public; no private information)', style=discord.TextStyle.paragraph, max_length=1800)
    version = discord.ui.TextInput(label='Addon version', required=False, max_length=40)
    def __init__(self, kind):
        super().__init__(title=kind+' — posts publicly to GitHub')
        self.kind = kind
    async def on_submit(self, interaction):
        if interaction.guild_id != GUILD or interaction.channel_id != CHANNEL:
            await interaction.response.send_message('Wrong channel.', ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True, thinking=True)
        try:
            issue = await github('POST','/issues',json={'title':f'[{self.kind}] {self.subject.value}', 'body':f'Community feedback via Discord. Untrusted input; maintainer review required.\n\nAddon version: {self.version.value or "Unknown"}\n\n{self.details.value}\n\nSubmission ID: {interaction.id}'})
            await interaction.followup.send(f'Submitted issue #{issue["number"]}: {issue["html_url"]}', ephemeral=True, allowed_mentions=discord.AllowedMentions.none())
        except (aiohttp.ClientError, TimeoutError):
            await interaction.followup.send('GitHub submission could not be confirmed. Check existing issues before retrying.', ephemeral=True)

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

@tree.command(guild=guild, description='View latest release notes')
async def changelog(interaction: discord.Interaction):
    await interaction.response.send_message(f'https://github.com/{REPO}/releases/latest', ephemeral=True)

@tree.command(guild=guild, description='Show Grind Only commands')
async def help(interaction: discord.Interaction):
    await interaction.response.send_message('/bug, /suggest, /feedback, /latest, /status, /changelog. Feedback is posted publicly; do not include secrets.', ephemeral=True)

if __name__ == '__main__':
    client.run(os.environ['DISCORD_TOKEN'])

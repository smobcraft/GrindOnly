import logging
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path


class SecretRedactingFormatter(logging.Formatter):
    def __init__(self, fmt, secrets):
        super().__init__(fmt)
        self.secrets = tuple(secret for secret in secrets if secret)

    def format(self, record):
        rendered = super().format(record)
        for secret in self.secrets:
            rendered = rendered.replace(secret, "[REDACTED]")
        return rendered


def configure_logging(log_directory: Path, secrets=()):
    log_directory = Path(log_directory)
    log_directory.mkdir(parents=True, exist_ok=True)
    formatter = SecretRedactingFormatter(
        "%(asctime)s %(levelname)s %(name)s: %(message)s",
        secrets,
    )
    file_handler = TimedRotatingFileHandler(
        log_directory / "bot.log",
        when="midnight",
        backupCount=7,
        encoding="utf-8",
        utc=True,
    )
    file_handler.setFormatter(formatter)
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.INFO)
    root_logger.addHandler(file_handler)
    root_logger.addHandler(console_handler)
    logging.getLogger("discord").setLevel(logging.WARNING)
    return file_handler, console_handler

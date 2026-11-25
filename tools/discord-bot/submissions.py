import hashlib
import unicodedata


def normalize_text(value):
    normalized = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return " ".join(normalized.split())


def normalized_issue_title(kind, subject):
    subject_text = " ".join(unicodedata.normalize("NFKC", str(subject or "")).split())
    title = f"[{str(kind).strip()}] {subject_text}"
    return title


def submission_fingerprint(kind, subject, details, version):
    payload = "\n".join((
        normalize_text(kind),
        normalize_text(subject),
        normalize_text(details),
        normalize_text(version),
    ))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()

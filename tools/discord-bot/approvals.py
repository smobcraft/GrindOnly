import hashlib
import json


def issue_revision_hash(repository, issue_number, title, body):
    revision = {
        "body": body or "",
        "issue_number": int(issue_number),
        "repository": repository,
        "title": title or "",
    }
    canonical = json.dumps(
        revision,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()

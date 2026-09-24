"""Knowledge administration API: Add Knowledge, KBValidation, KBViewer.

Employees submit knowledge through a guided form; admins (the Cognito admins
group) edit, approve or reject it; only approved Markdown is indexed into
Eddie's knowledge base. Everything lives in the private documents bucket
(modules/chatbot/kb.tf), whose data source reads only approved/:

  pending/<id>.json               a submission awaiting review
  rejected/<id>.json              a rejected submission, with the reason
  approved/<folder>/<slug>-<id>.md  live knowledge (Markdown only)

Routes (all need a signed-in employee's ID token; admin routes need the
admins group):
  POST   /kb/entries                 employee  submit
  GET    /kb/entries/mine            employee  own submissions and status
  GET    /kb/entries/pending         admin     the review queue
  POST   /kb/entries/{id}/approve    admin     optional edits, publish, re-index
  POST   /kb/entries/{id}/reject     admin     with a reason
  GET    /kb/documents               employee  all live knowledge + index status
  DELETE /kb/documents/{id}          admin     remove, re-index
  POST   /kb/sync                    admin     re-index

The Markdown is always built here from structured fields, so every file has
the template structure Eddie's prompts rely on (the "Also possible with this
setup" heading). Headings carry the topic so a ~300-token passage cut out of
the middle of a file still says what it's about.

Logs only the caller's ID and the route, never content.
"""

import base64
import datetime
import json
import os
import re
import uuid
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote, unquote

import boto3
from botocore.exceptions import ClientError

from claims import claims_of, parse_groups, respond

BUCKET = os.environ["KB_DOCS_BUCKET"]
KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DATA_SOURCE_ID = os.environ["KB_DATA_SOURCE_ID"]

PENDING, REJECTED, APPROVED = "pending/", "rejected/", "approved/"
FOLDERS = {"capability": "capabilities", "faq": "faq", "note": "notes"}

MAX_TITLE = 120
MAX_QUESTION = 300
MAX_HEADING = 120
MAX_TEXT = 4000
MAX_PAIRS = 20
MAX_SECTIONS = 10
MAX_MARKDOWN_BYTES = 20_000
MAX_REASON = 500
ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-agent")


class BadRequest(Exception):
    pass


# --- Fields -> Markdown -------------------------------------------------------

def one_line(value, name, limit):
    text = " ".join(str(value or "").split())
    if not text:
        raise BadRequest(f"{name} is required.")
    if len(text) > limit:
        raise BadRequest(f"{name} must be {limit} characters or fewer.")
    return text


def body_text(value, name):
    text = str(value or "").replace("\r\n", "\n").strip()
    if not text:
        raise BadRequest(f"{name} is required.")
    if len(text) > MAX_TEXT:
        raise BadRequest(f"{name} must be {MAX_TEXT} characters or fewer.")
    # A line starting with # would become a heading and break the template
    # structure, so it's escaped to plain text.
    return re.sub(r"(?m)^(\s*)#", r"\1\\#", text)


def clean_fields(entry_type, fields):
    """Validates the form fields for a type; returns the cleaned fields."""
    if not isinstance(fields, dict):
        raise BadRequest("fields must be an object.")
    if entry_type == "capability":
        return {
            "title": one_line(fields.get("title"), "Title", MAX_TITLE),
            "whatItTakes": body_text(fields.get("whatItTakes"), "What it takes"),
            "howWeSetItUp": body_text(fields.get("howWeSetItUp"), "How A&E sets it up"),
            "alsoPossible": body_text(fields.get("alsoPossible"), "Also possible with this setup"),
        }
    if entry_type == "faq":
        pairs = fields.get("pairs")
        if not isinstance(pairs, list) or not 1 <= len(pairs) <= MAX_PAIRS:
            raise BadRequest(f"Add between 1 and {MAX_PAIRS} questions.")
        return {
            "title": one_line(fields.get("title"), "Topic", MAX_TITLE),
            "pairs": [
                {
                    "question": one_line(p.get("question") if isinstance(p, dict) else None,
                                         f"Question {i}", MAX_QUESTION),
                    "answer": body_text(p.get("answer") if isinstance(p, dict) else None, f"Answer {i}"),
                }
                for i, p in enumerate(pairs, start=1)
            ],
        }
    if entry_type == "note":
        sections = fields.get("sections")
        if not isinstance(sections, list) or not 1 <= len(sections) <= MAX_SECTIONS:
            raise BadRequest(f"Add between 1 and {MAX_SECTIONS} sections.")
        return {
            "title": one_line(fields.get("title"), "Title", MAX_TITLE),
            "sections": [
                {
                    "heading": one_line(s.get("heading") if isinstance(s, dict) else None,
                                        f"Section {i} heading", MAX_HEADING),
                    "body": body_text(s.get("body") if isinstance(s, dict) else None, f"Section {i} text"),
                }
                for i, s in enumerate(sections, start=1)
            ],
        }
    raise BadRequest("type must be capability, faq, or note.")


def build_markdown(entry_type, f):
    title = f["title"]
    if entry_type == "capability":
        parts = [
            f"# Capability: {title}",
            f"## What it takes: {title}\n\n{f['whatItTakes']}",
            f"## How A&E sets it up: {title}\n\n{f['howWeSetItUp']}",
            f"## Also possible with this setup: {title}\n\n{f['alsoPossible']}",
        ]
    elif entry_type == "faq":
        parts = [f"# Frequently asked questions: {title}"] + [
            f"## Q: {p['question']}\n\n{p['answer']}" for p in f["pairs"]
        ]
    else:
        parts = [f"# {title}"] + [f"## {title}: {s['heading']}\n\n{s['body']}" for s in f["sections"]]
    markdown = "\n\n".join(parts) + "\n"
    if len(markdown.encode("utf-8")) > MAX_MARKDOWN_BYTES:
        raise BadRequest("This entry is too long. Split it into smaller entries.")
    return markdown


def slugify(title):
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return slug[:60].strip("-") or "entry"


# --- S3 helpers -------------------------------------------------------------

def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def read_json(key):
    return json.loads(s3.get_object(Bucket=BUCKET, Key=key)["Body"].read())


def write_json(key, data):
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(data).encode("utf-8"),
                  ContentType="application/json")


def list_keys(prefix):
    keys = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix):
        keys += [o["Key"] for o in page.get("Contents", [])]
    return keys


def entry_id_of(key):
    match = re.search(r"([0-9a-f]{32})\.(json|md)$", key)
    return match.group(1) if match else None


def meta(values):
    # S3 metadata is ASCII-only, so values are URL-encoded.
    return {k: quote(str(v), safe="@.:-_ ") for k, v in values.items() if v}


def unmeta(values):
    return {k: unquote(v) for k, v in (values or {}).items()}


def load_pending(entry_id):
    if not ID_PATTERN.match(entry_id or ""):
        raise BadRequest("Unknown entry.")
    try:
        return read_json(f"{PENDING}{entry_id}.json")
    except ClientError as err:
        if err.response["Error"]["Code"] in ("NoSuchKey", "404"):
            raise BadRequest("That submission is no longer pending.") from None
        raise


def find_approved_key(entry_id):
    if not ID_PATTERN.match(entry_id or ""):
        return None
    return next((k for k in list_keys(APPROVED) if k.endswith(f"-{entry_id}.md")), None)


# --- Indexing ------------------------------------------------------------------

def start_indexing():
    try:
        job = bedrock.start_ingestion_job(knowledgeBaseId=KNOWLEDGE_BASE_ID, dataSourceId=DATA_SOURCE_ID)
        return {"status": job["ingestionJob"]["status"], "jobId": job["ingestionJob"]["ingestionJobId"]}
    except ClientError as err:
        # Only one ingestion job runs at a time per data source.
        if err.response["Error"]["Code"] in ("ConflictException", "ValidationException"):
            return {"status": "BUSY", "message": "Indexing is already running. Re-index when it finishes."}
        raise


def last_indexing():
    jobs = bedrock.list_ingestion_jobs(
        knowledgeBaseId=KNOWLEDGE_BASE_ID, dataSourceId=DATA_SOURCE_ID,
        sortBy={"attribute": "STARTED_AT", "order": "DESCENDING"}, maxResults=1,
    ).get("ingestionJobSummaries", [])
    if not jobs:
        return None
    job = jobs[0]
    return {
        "status": job["status"],
        "startedAt": job["startedAt"].isoformat(),
        "updatedAt": job["updatedAt"].isoformat(),
        "statistics": job.get("statistics", {}),
    }


# --- Routes -------------------------------------------------------------------

def submit(caller, body):
    entry_type = body.get("type")
    fields = clean_fields(entry_type, body.get("fields"))
    entry = {
        "id": uuid.uuid4().hex,
        "type": entry_type,
        "fields": fields,
        "markdown": build_markdown(entry_type, fields),
        "author": {"email": caller["email"], "sub": caller["sub"]},
        "submittedAt": now(),
    }
    write_json(f"{PENDING}{entry['id']}.json", entry)
    return 201, {"entry": entry}


def mine(caller, body):
    def pending_or_rejected(key):
        data = read_json(key)
        if data.get("author", {}).get("sub") != caller["sub"]:
            return None
        status = "pending" if key.startswith(PENDING) else "rejected"
        return {"id": data["id"], "type": data["type"], "title": data["fields"]["title"], "status": status,
                "submittedAt": data["submittedAt"], "reason": data.get("rejection", {}).get("reason")}

    def approved(key):
        info = unmeta(s3.head_object(Bucket=BUCKET, Key=key).get("Metadata"))
        if info.get("author-sub") != caller["sub"]:
            return None
        return {"id": info.get("entry-id"), "type": info.get("type"), "title": info.get("title"),
                "status": "approved", "submittedAt": info.get("submitted-at"), "approvedAt": info.get("approved-at")}

    with ThreadPoolExecutor(max_workers=16) as pool:
        results = list(pool.map(pending_or_rejected, list_keys(PENDING) + list_keys(REJECTED)))
        results += list(pool.map(approved, list_keys(APPROVED)))
    entries = sorted([r for r in results if r], key=lambda r: r.get("submittedAt") or "", reverse=True)
    return 200, {"entries": entries}


def pending_queue(caller, body):
    with ThreadPoolExecutor(max_workers=16) as pool:
        entries = list(pool.map(read_json, list_keys(PENDING)))
    entries.sort(key=lambda e: e.get("submittedAt") or "")
    return 200, {"entries": entries}


def approve(caller, body, entry_id):
    entry = load_pending(entry_id)
    if body.get("fields") is not None:
        entry["fields"] = clean_fields(entry["type"], body["fields"])
        entry["markdown"] = build_markdown(entry["type"], entry["fields"])
    key = f"{APPROVED}{FOLDERS[entry['type']]}/{slugify(entry['fields']['title'])}-{entry['id']}.md"
    s3.put_object(
        Bucket=BUCKET, Key=key, Body=entry["markdown"].encode("utf-8"),
        ContentType="text/markdown; charset=utf-8",
        Metadata=meta({
            "entry-id": entry["id"], "type": entry["type"], "title": entry["fields"]["title"],
            "author-email": entry["author"]["email"], "author-sub": entry["author"]["sub"],
            "submitted-at": entry["submittedAt"], "approved-by": caller["email"], "approved-at": now(),
        }),
    )
    s3.delete_object(Bucket=BUCKET, Key=f"{PENDING}{entry['id']}.json")
    return 200, {"key": key, "indexing": start_indexing()}


def reject(caller, body, entry_id):
    reason = " ".join(str(body.get("reason") or "").split())
    if not reason:
        raise BadRequest("Give a reason, so the employee knows what to change.")
    if len(reason) > MAX_REASON:
        raise BadRequest(f"The reason must be {MAX_REASON} characters or fewer.")
    entry = load_pending(entry_id)
    entry["rejection"] = {"reason": reason, "by": caller["email"], "at": now()}
    write_json(f"{REJECTED}{entry['id']}.json", entry)
    s3.delete_object(Bucket=BUCKET, Key=f"{PENDING}{entry['id']}.json")
    return 200, {"id": entry["id"], "status": "rejected"}


def documents(caller, body):
    def read(key):
        obj = s3.get_object(Bucket=BUCKET, Key=key)
        info = unmeta(obj.get("Metadata"))
        content = obj["Body"].read().decode("utf-8", errors="replace")
        heading = next((line[2:].strip() for line in content.splitlines() if line.startswith("# ")), None)
        return {
            "id": info.get("entry-id") or entry_id_of(key),
            "key": key,
            "folder": key[len(APPROVED):].split("/", 1)[0],
            "type": info.get("type"),
            "title": info.get("title") or heading or key.rsplit("/", 1)[-1],
            "author": info.get("author-email"),
            "approvedBy": info.get("approved-by"),
            "approvedAt": info.get("approved-at"),
            "updatedAt": obj["LastModified"].isoformat(),
            "content": content,
        }

    with ThreadPoolExecutor(max_workers=16) as pool:
        docs = list(pool.map(read, [k for k in list_keys(APPROVED) if k.endswith(".md")]))
    docs.sort(key=lambda d: (d["folder"], d["title"].lower()))
    return 200, {"documents": docs, "indexing": last_indexing()}


def remove(caller, body, entry_id):
    key = find_approved_key(entry_id)
    if key is None:
        raise BadRequest("That knowledge isn't live.")
    # The bucket is versioned: this leaves a delete marker, and the earlier
    # version stays recoverable (S3 console, Show versions) for a year.
    s3.delete_object(Bucket=BUCKET, Key=key)
    return 200, {"removed": key, "indexing": start_indexing()}


def sync(caller, body):
    return 200, {"indexing": start_indexing()}


ROUTES = {
    "POST /kb/entries": (submit, False),
    "GET /kb/entries/mine": (mine, False),
    "GET /kb/entries/pending": (pending_queue, True),
    "POST /kb/entries/{id}/approve": (approve, True),
    "POST /kb/entries/{id}/reject": (reject, True),
    "GET /kb/documents": (documents, False),
    "DELETE /kb/documents/{id}": (remove, True),
    "POST /kb/sync": (sync, True),
}


def parse_body(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    if not raw:
        return {}
    try:
        body = json.loads(raw)
    except ValueError:
        raise BadRequest("The request body must be JSON.") from None
    if not isinstance(body, dict):
        raise BadRequest("The request body must be a JSON object.")
    return body


def handler(event, context):
    claims = claims_of(event)
    route = event.get("routeKey")

    if claims.get("token_use") != "id":
        return respond(401, {"message": "Send the ID token."})

    groups = parse_groups(claims.get("cognito:groups"))
    is_admin = "admins" in groups
    print(json.dumps({"route": route, "sub": claims.get("sub"), "admin": is_admin}))

    if route not in ROUTES:
        return respond(404, {"message": "Not found."})
    action, admin_only = ROUTES[route]
    if admin_only and not is_admin:
        return respond(403, {"message": "This is for admins only."})

    caller = {"sub": claims.get("sub", ""), "email": claims.get("email", ""), "admin": is_admin}
    try:
        body = parse_body(event)
        entry_id = (event.get("pathParameters") or {}).get("id")
        status, result = action(caller, body, entry_id) if entry_id is not None else action(caller, body)
    except BadRequest as err:
        return respond(400, {"message": str(err)})
    return respond(status, result)

"""The three kinds of knowledge: their fields, validation, and Markdown.

Shared by the knowledge API (kb.py), which stores and publishes entries, and
Herman (assistant.py), which checks the drafts he writes. Pure Python with no
AWS calls, so Herman's eval can import it too.

The Markdown is always built here from structured fields, so every file has
the template structure Eddie's prompts rely on (the "Also possible with this
setup" heading). Headings carry the topic so a ~300-token passage cut out of
the middle of a file still says what it's about.
"""

import re

from claims import BadRequest

TYPES = ("capability", "faq", "note")
FOLDERS = {"capability": "capabilities", "faq": "faq", "note": "notes"}

MAX_TITLE = 120
MAX_QUESTION = 300
MAX_HEADING = 120
MAX_TEXT = 4000
MAX_PAIRS = 20
MAX_SECTIONS = 10
MAX_MARKDOWN_BYTES = 20_000
MAX_REVIEW_NOTE = 500

# A capability's three body fields, with the labels errors use.
CAPABILITY_BODIES = (
    ("whatItTakes", "What it takes"),
    ("howWeSetItUp", "How A&E sets it up"),
    ("alsoPossible", "Also possible with this setup"),
)


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


def _item(items, i, key):
    item = items[i - 1]
    return item.get(key) if isinstance(item, dict) else None


def clean_fields(entry_type, fields):
    """Validates the form fields for a type; returns the cleaned fields."""
    if not isinstance(fields, dict):
        raise BadRequest("fields must be an object.")
    if entry_type == "capability":
        cleaned = {"title": one_line(fields.get("title"), "Title", MAX_TITLE)}
        for key, label in CAPABILITY_BODIES:
            cleaned[key] = body_text(fields.get(key), label)
        return cleaned
    if entry_type == "faq":
        pairs = fields.get("pairs")
        if not isinstance(pairs, list) or not 1 <= len(pairs) <= MAX_PAIRS:
            raise BadRequest(f"Add between 1 and {MAX_PAIRS} questions.")
        return {
            "title": one_line(fields.get("title"), "Topic", MAX_TITLE),
            "pairs": [
                {
                    "question": one_line(_item(pairs, i, "question"), f"Question {i}", MAX_QUESTION),
                    "answer": body_text(_item(pairs, i, "answer"), f"Answer {i}"),
                }
                for i in range(1, len(pairs) + 1)
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
                    "heading": one_line(_item(sections, i, "heading"), f"Section {i} heading", MAX_HEADING),
                    "body": body_text(_item(sections, i, "body"), f"Section {i} text"),
                }
                for i in range(1, len(sections) + 1)
            ],
        }
    raise BadRequest("type must be capability, faq, or note.")


def list_problems(entry_type, fields):
    """Every reason clean_fields would reject these fields, not just the first.

    Herman shows this as a checklist of what the draft still needs.
    """
    problems = []

    def check(fn, *args):
        try:
            fn(*args)
        except BadRequest as err:
            problems.append(str(err))

    if not isinstance(fields, dict):
        return ["fields must be an object."]
    if entry_type == "capability":
        check(one_line, fields.get("title"), "Title", MAX_TITLE)
        for key, label in CAPABILITY_BODIES:
            check(body_text, fields.get(key), label)
    elif entry_type == "faq":
        check(one_line, fields.get("title"), "Topic", MAX_TITLE)
        pairs = fields.get("pairs")
        if not isinstance(pairs, list) or not 1 <= len(pairs) <= MAX_PAIRS:
            problems.append(f"Add between 1 and {MAX_PAIRS} questions.")
        else:
            for i in range(1, len(pairs) + 1):
                check(one_line, _item(pairs, i, "question"), f"Question {i}", MAX_QUESTION)
                check(body_text, _item(pairs, i, "answer"), f"Answer {i}")
    elif entry_type == "note":
        check(one_line, fields.get("title"), "Title", MAX_TITLE)
        sections = fields.get("sections")
        if not isinstance(sections, list) or not 1 <= len(sections) <= MAX_SECTIONS:
            problems.append(f"Add between 1 and {MAX_SECTIONS} sections.")
        else:
            for i in range(1, len(sections) + 1):
                check(one_line, _item(sections, i, "heading"), f"Section {i} heading", MAX_HEADING)
                check(body_text, _item(sections, i, "body"), f"Section {i} text")
    else:
        return ["type must be capability, faq, or note."]
    if not problems:
        # The size limit applies to the whole file.
        check(lambda: build_markdown(entry_type, clean_fields(entry_type, fields)))
    return problems


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

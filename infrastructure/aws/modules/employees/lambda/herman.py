"""Herman without AWS: request checks, prompts, the tool, and reading replies.

assistant.py (the Lambda) sends Bedrock what this builds. Herman's eval
(../eval/intake_eval.py) imports the same functions, so it tests what's
deployed except for the model call itself.

Herman only drafts. Nothing here writes anywhere: the employee submits a
draft through POST /kb/entries, and an admin approves it before Eddie sees it.
"""

import json
import os
import re

from claims import BadRequest
from knowledge_fields import MAX_REVIEW_NOTE, TYPES, list_problems

HERE = os.path.dirname(os.path.abspath(__file__))

ANTHROPIC_VERSION = "bedrock-2023-05-31"
MAX_TOKENS = 2000
TEMPERATURE = 0.2

MAX_MESSAGES = 40
MAX_USER_CHARS = 2000
MAX_ASSISTANT_CHARS = 6000
MAX_DRAFT_CHARS = 60_000
# The same limits as Eddie's chat API, whose exchange the seed quotes.
MAX_SEED_QUESTION = 500
MAX_SEED_REPLY = 2500
SEED_SOURCES = ("knowledge_base", "both", "general")
MARKUP = re.compile(r"</?[^>]*>")

# Each kind's fields, and what an empty one looks like.
FIELD_DEFAULTS = {
    "capability": {"title": "", "whatItTakes": "", "howWeSetItUp": "", "alsoPossible": ""},
    "faq": {"title": "", "pairs": []},
    "note": {"title": "", "sections": []},
}


def read_prompt(name):
    with open(os.path.join(HERE, "prompts", name), encoding="utf-8") as f:
        return f.read()


def _text(description):
    return {"type": "string", "description": description}


# Herman's reply comes back through a forced, schema-strict tool call, so the
# message, the draft and the flags arrive as separate fields. Every field is
# required; the kinds' unused fields are left empty.
INTAKE_TOOL = {
    "name": "intake_turn",
    "description": "Send your reply to the employee, with the whole current draft.",
    "strict": True,
    "input_schema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["reply", "type", "fields", "readyToSubmit", "reviewNote"],
        "properties": {
            "reply": _text("What you say to the employee."),
            "type": {"type": "string", "enum": ["undecided", *TYPES]},
            "fields": {
                "type": "object",
                "additionalProperties": False,
                "required": ["title", "whatItTakes", "howWeSetItUp", "alsoPossible", "pairs", "sections"],
                "properties": {
                    "title": _text("Capability: what the customer wants to do. FAQ: the topic. Note: the subject."),
                    "whatItTakes": _text("Capability only; otherwise empty."),
                    "howWeSetItUp": _text("Capability only; otherwise empty."),
                    "alsoPossible": _text("Capability only; otherwise empty."),
                    "pairs": {
                        "type": "array",
                        "description": "FAQ only; otherwise empty.",
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "required": ["question", "answer"],
                            "properties": {"question": {"type": "string"}, "answer": {"type": "string"}},
                        },
                    },
                    "sections": {
                        "type": "array",
                        "description": "Note only; otherwise empty.",
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "required": ["heading", "body"],
                            "properties": {"heading": {"type": "string"}, "body": {"type": "string"}},
                        },
                    },
                },
            },
            "readyToSubmit": {"type": "boolean"},
            # Nullable rather than "" for none: asked for an empty string, the
            # model sometimes writes markup fragments instead.
            "reviewNote": {"type": ["string", "null"],
                           "description": "A short note for the admin reviewer, or null when there's nothing to flag."},
        },
    },
}

# Each mode is one of Herman's jobs: its prompt, its tool, and who may use it.
# `groups` None means any signed-in employee; otherwise the caller needs one
# of the listed Cognito groups. The server decides, never the model.
MODES = {
    "knowledge": {"groups": None, "prompt": "intake.md", "tool": INTAKE_TOOL},
}

PERSONALITY = read_prompt("herman_personality.md")
MODE_PROMPTS = {name: read_prompt(mode["prompt"]) for name, mode in MODES.items()}


# --- The request ------------------------------------------------------------------

def check_messages(messages):
    if not isinstance(messages, list) or not 1 <= len(messages) <= MAX_MESSAGES:
        raise BadRequest(f"Send between 1 and {MAX_MESSAGES} messages. Start over to keep going.")
    checked = []
    for i, message in enumerate(messages):
        if not isinstance(message, dict) or set(message) != {"role", "content"}:
            raise BadRequest("Each message needs a role and content, and nothing else.")
        # Turns alternate, starting and ending with the employee.
        role = "user" if i % 2 == 0 else "assistant"
        if message["role"] != role:
            raise BadRequest("Messages must alternate, starting with the employee.")
        content = message["content"]
        limit = MAX_USER_CHARS if role == "user" else MAX_ASSISTANT_CHARS
        if not isinstance(content, str) or not content.strip():
            raise BadRequest("Messages can't be empty.")
        if len(content) > limit:
            raise BadRequest(f"Keep each message to {limit} characters or fewer.")
        checked.append({"role": role, "content": content})
    if checked[-1]["role"] != "user":
        raise BadRequest("The last message must be the employee's.")
    return checked


def check_draft(draft):
    if draft is None:
        return None
    if not isinstance(draft, dict) or set(draft) != {"type", "fields"}:
        raise BadRequest("draft must have a type and fields.")
    if draft["type"] not in TYPES or not isinstance(draft["fields"], dict):
        raise BadRequest("draft type must be capability, faq, or note, with fields.")
    if len(json.dumps(draft)) > MAX_DRAFT_CHARS:
        raise BadRequest("The draft is too long. Split it into smaller entries.")
    return {"type": draft["type"], "fields": draft["fields"]}


def check_seed(seed):
    if seed is None:
        return None
    if not isinstance(seed, dict) or set(seed) != {"question", "reply", "source"}:
        raise BadRequest("seed must have a question, reply, and source.")
    question, reply, source = seed["question"], seed["reply"], seed["source"]
    if not isinstance(question, str) or not question.strip() or len(question) > MAX_SEED_QUESTION:
        raise BadRequest(f"The seed question must be 1-{MAX_SEED_QUESTION} characters.")
    if not isinstance(reply, str) or not reply.strip() or len(reply) > MAX_SEED_REPLY:
        raise BadRequest(f"The seed reply must be 1-{MAX_SEED_REPLY} characters.")
    if source not in SEED_SOURCES:
        raise BadRequest("The seed source must be knowledge_base, both, or general.")
    return {"question": question, "reply": reply, "source": source}


def check_request(body):
    """Returns (mode, messages, draft, seed), or raises BadRequest."""
    unknown = sorted(set(body) - {"mode", "messages", "draft", "seed"})
    if unknown:
        raise BadRequest(f"Unknown field: {unknown[0]}.")
    mode = body.get("mode")
    if mode not in MODES:
        raise BadRequest(f"mode must be one of: {', '.join(MODES)}.")
    return mode, check_messages(body.get("messages")), check_draft(body.get("draft")), check_seed(body.get("seed"))


def allowed(mode, groups):
    required = MODES[mode]["groups"]
    return required is None or bool(set(required) & set(groups))


# --- The model call -------------------------------------------------------------------

def as_data(value):
    # JSON with "<" escaped, so quoted text can't close the block it sits in
    # and pose as instructions.
    return json.dumps(value, indent=1, ensure_ascii=False).replace("<", "\\u003c")


def build_body(mode, messages, draft, seed):
    """The Anthropic Messages body for Bedrock InvokeModel.

    System blocks, in order: Herman's personality, the mode's rules, the Eddie
    chat the employee came from (if any), and the current draft. The prompt
    files pass through verbatim; only the last two blocks are built per
    request.
    """
    system = [
        {"type": "text", "text": PERSONALITY},
        {"type": "text", "text": MODE_PROMPTS[mode]},
    ]
    if seed:
        gap = {"customer_question": seed["question"], "eddie_reply": seed["reply"], "source": seed["source"]}
        system.append({"type": "text", "text": f"<eddie_gap>\n{as_data(gap)}\n</eddie_gap>"})
    current = as_data(draft) if draft else "No draft yet."
    system.append({"type": "text", "text": f"<current_draft>\n{current}\n</current_draft>"})
    tool = MODES[mode]["tool"]
    return {
        "anthropic_version": ANTHROPIC_VERSION,
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
        "system": system,
        "messages": messages,
        "tools": [tool],
        "tool_choice": {"type": "tool", "name": tool["name"]},
    }


def read_turn(response):
    """The API's reply from the model's response, or None if it's unusable.

    `ready` is decided here, not by the model: the draft must also pass the
    same checks POST /kb/entries applies.
    """
    calls = [c.get("input") for c in response.get("content", []) if c.get("type") == "tool_use"]
    call = calls[0] if calls and isinstance(calls[0], dict) else None
    reply = str(call.get("reply") or "").strip() if call else ""
    if response.get("stop_reason") != "tool_use" or not reply:
        return None

    entry_type = call.get("type")
    fields = call.get("fields") if isinstance(call.get("fields"), dict) else {}
    draft, missing, ready = None, [], False
    if entry_type in TYPES:
        draft = {"type": entry_type,
                 "fields": {k: fields.get(k, empty) for k, empty in FIELD_DEFAULTS[entry_type].items()}}
        missing = list_problems(entry_type, draft["fields"])
        ready = call.get("readyToSubmit") is True and not missing
    note = " ".join(str(call.get("reviewNote") or "").split())[:MAX_REVIEW_NOTE]
    if not re.search(r"[A-Za-z]{3}", MARKUP.sub("", note)):
        note = ""  # a stray tag or punctuation, not a note
    return {"reply": reply, "draft": draft, "ready": ready, "missing": missing, "reviewNote": note or None}


def fallback(draft):
    """Returned when the model's reply is unusable (cut off, or no tool call).

    The employee's draft comes back unchanged, so nothing is lost.
    """
    return {
        "reply": "Sorry, I lost my place there. Could you say that again? If it was long, try it in smaller pieces.",
        "draft": draft,
        "ready": False,
        "missing": list_problems(draft["type"], draft["fields"]) if draft else [],
        "reviewNote": None,
    }

"""Herman, the employee assistant: /assistant/* on the employee API.

POST /assistant/chat    a conversation turn (below)
GET  /assistant/status  {"enabled": true|false}: whether Herman is switched on

Herman is separate from Eddie, the public chatbot (modules/chatbot). He's
reachable only with a signed-in employee's ID token, so he can later work
with data customers must never reach (work orders, invoices, quotes). Each
job is a `mode` (herman.MODES), and the server decides from the caller's
Cognito groups which modes they get.

Today's only mode, `knowledge`, interviews an employee and drafts a
knowledge entry that teaches Eddie. Herman never writes anything. The
employee submits the draft through POST /kb/entries (kb.py), and an admin
approves it before it's indexed.

Request:  {"mode": "knowledge", "messages": [{"role", "content"}, ...],
           "draft": {"type", "fields"} | null,
           "seed": {"question", "reply", "source"} | null}
Response: {"reply", "draft": {"type", "fields"} | null, "ready", "missing": [...],
           "reviewNote": str | null}

Herman has an on/off switch, the SSM parameter in HERMAN_FLAG, flipped on
the admin Feature Mgr page (features.py). It's read on every request, so a
change takes effect at once. When it's off, or can't be read, chat answers
503 before any model call.

Stateless, like Eddie: the browser sends the conversation and the current
draft every turn. Each chat turn logs one JSON line: the caller's ID and
email, the mode, the model, token counts, and response times (bedrockMs,
Bedrock's own processing time; totalMs, the whole turn), never content. The
admin AI Stats page reads these lines (herman_usage.py).
"""

import json
import os
import time

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

import herman
from claims import BadRequest, claims_of, parse_body, parse_groups, respond

MODEL_ID = os.environ["MODEL_ID"]
# The inference profile's ID (after the ARN's last /), logged with each turn
# so AI Stats can price it.
MODEL = MODEL_ID.rsplit("/", 1)[-1]
FLAG = os.environ["HERMAN_FLAG"]
CHAT = "POST /assistant/chat"
STATUS = "GET /assistant/status"

# The HTTP API gives up on an integration after 30 seconds, and the function
# after 29, so a slow reply is cut off rather than left hanging.
bedrock = boto3.client("bedrock-runtime", config=Config(
    connect_timeout=3, read_timeout=25, retries={"mode": "standard", "total_max_attempts": 2},
))

ssm = boto3.client("ssm")

UNAVAILABLE = "Herman can't answer right now. Try again in a minute."
OFF = "Herman is switched off right now."


def bedrock_ms(raw):
    """Bedrock's own processing time for the call, from its response header,
    or None if it's missing."""
    value = raw.get("ResponseMetadata", {}).get("HTTPHeaders", {}).get("x-amzn-bedrock-invocation-latency")
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def switched_on():
    """Herman's on/off switch. Exactly "true" is on; anything else, or a
    switch that can't be read, is off."""
    try:
        return ssm.get_parameter(Name=FLAG)["Parameter"]["Value"] == "true"
    except (ClientError, BotoCoreError) as err:
        code = err.response["Error"]["Code"] if isinstance(err, ClientError) else type(err).__name__
        print(json.dumps({"flag": FLAG, "error": code}))
        return False


def handler(event, context):
    claims = claims_of(event)
    if claims.get("token_use") != "id":
        return respond(401, {"message": "Send the ID token."})
    route = event.get("routeKey")
    if route not in (CHAT, STATUS):
        return respond(404, {"message": "Not found."})

    enabled = switched_on()
    if route == STATUS:
        return respond(200, {"enabled": enabled})

    started = time.monotonic()
    groups = parse_groups(claims.get("cognito:groups"))
    log = {"route": CHAT, "sub": claims.get("sub"), "email": claims.get("email"), "model": MODEL}
    if not enabled:
        print(json.dumps({**log, "status": 503, "off": True}))
        return respond(503, {"message": OFF, "enabled": False})

    try:
        mode, messages, draft, seed = herman.check_request(parse_body(event))
    except BadRequest as err:
        print(json.dumps({**log, "status": 400}))
        return respond(400, {"message": str(err)})
    log.update(mode=mode, turns=len(messages), seed=seed is not None)
    if not herman.allowed(mode, groups):
        print(json.dumps({**log, "status": 403}))
        return respond(403, {"message": "That isn't available to your account."})

    try:
        raw = bedrock.invoke_model(
            modelId=MODEL_ID, contentType="application/json", accept="application/json",
            body=json.dumps(herman.build_body(mode, messages, draft, seed)),
        )
        response = json.loads(raw["body"].read())
    except (ClientError, BotoCoreError) as err:
        code = err.response["Error"]["Code"] if isinstance(err, ClientError) else type(err).__name__
        print(json.dumps({**log, "status": 429 if code == "ThrottlingException" else 502, "error": code}))
        return respond(429 if code == "ThrottlingException" else 502, {"message": UNAVAILABLE})

    result = herman.read_turn(response)
    new_draft = result["draft"] if result else None
    usage = response.get("usage", {})
    print(json.dumps({
        **log, "status": 200, "stop": response.get("stop_reason"),
        "in": usage.get("input_tokens"), "out": usage.get("output_tokens"),
        "bedrockMs": bedrock_ms(raw), "totalMs": round((time.monotonic() - started) * 1000),
        "type": new_draft["type"] if new_draft else None,
        "ready": bool(result and result["ready"]), "fallback": result is None,
    }))
    return respond(200, result if result is not None else herman.fallback(draft))

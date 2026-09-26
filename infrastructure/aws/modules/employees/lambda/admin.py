"""Admin API: Eddie's usage and chat conversations, and feature switches.
Admins only.

GET  /admin/usage?days=7          per-day and total usage, requests vs quota,
                                  routes, tokens, estimated cost
GET  /admin/conversations?days=7  transcripts grouped by conversation, newest
                                  first, each with its total tokens and cost
GET  /admin/features              every feature switch and its recent changes
POST /admin/features/{name}       turn one on or off (features.py)
GET  /admin/herman-usage?days=7   Herman's turns, tokens, cost and response
                                  times, from his logs (herman_usage.py)

Both read the chat transcripts (modules/chatbot/transcripts.tf): one JSON
file per exchange under transcripts/YYYY/MM/DD/ (UTC). `days` is 1-30,
counting today. Costs are estimates of Bedrock model cost only, from the
token counts and the per-million-token prices in the environment. Response
times come from each transcript's `timings` (the state machine records them);
older transcripts have none.

Never logs transcript content: only the caller's ID and the route (and,
for a switch change, the switch and who changed it).
"""

import datetime
import json
import os
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

import boto3

import features
import herman_usage
from claims import BadRequest, claims_of, parse_body, parse_groups, respond

BUCKET = os.environ["TRANSCRIPTS_BUCKET"]
PREFIX = "transcripts/"
USAGE_PLAN_ID = os.environ["USAGE_PLAN_ID"]
API_KEY_ID = os.environ["API_KEY_ID"]
PRICE_IN = float(os.environ["PRICE_PER_MTOK_INPUT"])
PRICE_OUT = float(os.environ["PRICE_PER_MTOK_OUTPUT"])
MAX_DAYS = 30

s3 = boto3.client("s3")
apigateway = boto3.client("apigateway")
ssm = boto3.client("ssm")
logs = boto3.client("logs")


def requested_days(event):
    raw = (event.get("queryStringParameters") or {}).get("days", "7")
    try:
        days = int(raw)
    except ValueError:
        days = 0
    if not 1 <= days <= MAX_DAYS:
        raise BadRequest(f"days must be a whole number from 1 to {MAX_DAYS}.")
    return date_range(days)


def date_range(days):
    today = datetime.datetime.now(datetime.timezone.utc).date()
    return [today - datetime.timedelta(days=n) for n in range(days - 1, -1, -1)]


def list_keys(day):
    keys = []
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=f"{PREFIX}{day:%Y/%m/%d}/")
    for page in pages:
        keys += [obj["Key"] for obj in page.get("Contents", [])]
    return keys


def read(key):
    try:
        data = json.loads(s3.get_object(Bucket=BUCKET, Key=key)["Body"].read())
        if isinstance(data, str):  # tolerate an early double-encoded file
            data = json.loads(data)
        return data if isinstance(data, dict) else None
    except Exception:  # an unreadable file is skipped, not fatal
        return None


def load_transcripts(days):
    with ThreadPoolExecutor(max_workers=16) as pool:
        keys = [k for batch in pool.map(list_keys, days) for k in batch]
        return [t for t in pool.map(read, keys) if t]


def tokens_of(t):
    tokens = t.get("tokens") or {}
    parts = [tokens.get("classify") or {}, tokens.get("answer") or {}]
    return sum(int(p.get("input") or 0) for p in parts), sum(int(p.get("output") or 0) for p in parts)


def response_ms(t):
    """The exchange's total time in milliseconds, or None before timings were
    recorded."""
    value = (t.get("timings") or {}).get("totalMs")
    return value if isinstance(value, (int, float)) else None


def cost(tokens_in, tokens_out):
    return round(tokens_in * PRICE_IN / 1e6 + tokens_out * PRICE_OUT / 1e6, 6)


def conversation_id(t):
    return t.get("conversationId") or t.get("executionId") or "unknown"


def latest_customer_message(t):
    users = [m.get("content", "") for m in t.get("messages") or [] if m.get("role") == "user"]
    return users[-1] if users else ""


def requests_per_day(days):
    # [used, remaining] per day, in date order, for the site's key.
    usage = apigateway.get_usage(
        usagePlanId=USAGE_PLAN_ID, keyId=API_KEY_ID,
        startDate=f"{days[0]:%Y-%m-%d}", endDate=f"{days[-1]:%Y-%m-%d}",
    )
    rows = usage.get("items", {}).get(API_KEY_ID, [])
    return {
        f"{day:%Y-%m-%d}": {"used": row[0], "quota": row[0] + row[1]}
        for day, row in zip(days, rows)
    }


def usage(days):
    transcripts = load_transcripts(days)
    requests = requests_per_day(days)
    per_day = {f"{d:%Y-%m-%d}": {"exchanges": 0, "conversations": set(), "routes": Counter(),
                                 "tokensIn": 0, "tokensOut": 0, "responseMs": []} for d in days}
    for t in transcripts:
        day = per_day.get((t.get("time") or "")[:10])
        if day is None:
            continue
        tokens_in, tokens_out = tokens_of(t)
        day["exchanges"] += 1
        day["conversations"].add(conversation_id(t))
        day["routes"][t.get("route", "unknown")] += 1
        day["tokensIn"] += tokens_in
        day["tokensOut"] += tokens_out
        day["responseMs"].append(response_ms(t))

    rows = []
    for date, day in per_day.items():
        req = requests.get(date, {})
        rows.append({
            "date": date,
            "requests": req.get("used", 0),
            "quota": req.get("quota"),
            "exchanges": day["exchanges"],
            "conversations": len(day["conversations"]),
            "routes": dict(day["routes"]),
            "tokensIn": day["tokensIn"],
            "tokensOut": day["tokensOut"],
            "cost": cost(day["tokensIn"], day["tokensOut"]),
            "responseMs": herman_usage.timing(day["responseMs"]),
        })

    routes = Counter()
    for row in rows:
        routes.update(row["routes"])
    tokens_in = sum(r["tokensIn"] for r in rows)
    tokens_out = sum(r["tokensOut"] for r in rows)
    return {
        "days": rows,
        "totals": {
            "requests": sum(r["requests"] for r in rows),
            "exchanges": sum(r["exchanges"] for r in rows),
            "conversations": len({conversation_id(t) for t in transcripts}),
            "routes": dict(routes),
            "tokensIn": tokens_in,
            "tokensOut": tokens_out,
            "cost": cost(tokens_in, tokens_out),
            "responseMs": herman_usage.timing(v for d in per_day.values() for v in d["responseMs"]),
        },
        "prices": {"inputPerMillion": PRICE_IN, "outputPerMillion": PRICE_OUT},
    }


def conversations(days):
    grouped = {}
    for t in load_transcripts(days):
        tokens_in, tokens_out = tokens_of(t)
        grouped.setdefault(conversation_id(t), []).append({
            "time": t.get("time"),
            "route": t.get("route"),
            "source": t.get("source"),
            "message": latest_customer_message(t),
            "reply": t.get("reply", ""),
            "tokensIn": tokens_in,
            "tokensOut": tokens_out,
            "cost": cost(tokens_in, tokens_out),
            "timings": t.get("timings"),
        })

    result = []
    for cid, exchanges in grouped.items():
        exchanges.sort(key=lambda e: e["time"] or "")
        tokens_in = sum(e["tokensIn"] for e in exchanges)
        tokens_out = sum(e["tokensOut"] for e in exchanges)
        result.append({
            "id": cid,
            "start": exchanges[0]["time"],
            "end": exchanges[-1]["time"],
            "routes": dict(Counter(e["route"] for e in exchanges)),
            "tokensIn": tokens_in,
            "tokensOut": tokens_out,
            "cost": cost(tokens_in, tokens_out),
            "exchanges": exchanges,
        })
    result.sort(key=lambda c: c["start"] or "", reverse=True)
    return {
        "conversations": result,
        "from": f"{days[0]:%Y-%m-%d}",
        "to": f"{days[-1]:%Y-%m-%d}",
        "prices": {"inputPerMillion": PRICE_IN, "outputPerMillion": PRICE_OUT},
    }


# Each route takes the event and the caller, and returns its response body.
ROUTES = {
    "GET /admin/usage": lambda event, caller: usage(requested_days(event)),
    "GET /admin/conversations": lambda event, caller: conversations(requested_days(event)),
    "GET /admin/features": lambda event, caller: features.list_features(ssm),
    "POST /admin/features/{name}": lambda event, caller: features.set_feature(
        ssm, caller, (event.get("pathParameters") or {}).get("name"), parse_body(event)),
    "GET /admin/herman-usage": lambda event, caller: herman_usage.usage(logs, requested_days(event)),
}


def handler(event, context):
    claims = claims_of(event)
    route = event.get("routeKey")

    if claims.get("token_use") != "id":
        return respond(401, {"message": "Send the ID token."})

    groups = parse_groups(claims.get("cognito:groups"))
    print(json.dumps({"route": route, "sub": claims.get("sub"), "admin": "admins" in groups}))
    if "admins" not in groups:
        return respond(403, {"message": "This is for admins only."})

    action = ROUTES.get(route)
    if action is None:
        return respond(404, {"message": "Not found."})

    caller = {"sub": claims.get("sub", ""), "email": claims.get("email", "")}
    try:
        return respond(200, action(event, caller))
    except BadRequest as err:
        return respond(400, {"message": str(err)})
    except features.NotFound:
        return respond(404, {"message": "No such feature."})
    except herman_usage.Unavailable as err:
        print(json.dumps({"route": route, "error": str(err)}))
        return respond(503, {"message": "Herman's usage couldn't be loaded. Try again shortly."})

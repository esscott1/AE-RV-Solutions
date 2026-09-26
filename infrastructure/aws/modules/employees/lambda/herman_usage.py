"""Herman's usage for the admin AI Stats page (admin.py routes here).

GET /admin/herman-usage?days=N   per-day, per-model and per-employee turns,
                                 tokens, estimated cost, and response times

Herman keeps no transcripts. Each chat turn writes one JSON log line
(assistant.py) to his log group, kept for 30 days, and this runs one CloudWatch
Logs Insights query over them and adds them up here. Lines from before the
model and timings were logged count as HERMAN_MODEL, and simply have no
response times.

Costs are estimates of Bedrock model cost only, from the token counts and
HERMAN_PRICES (model -> [input, output] dollars per million tokens). A model
with no price shows its cost as unknown (null), never as $0.

Employees are shown by their current email, looked up in the user pool
(USER_POOL_ID) by `sub`, since emails can change and older lines have none.
If the lookup fails or the account is gone, the logged email (or null) stays.
"""

import datetime
import json
import os
import statistics
import time
from collections import defaultdict

from botocore.exceptions import BotoCoreError, ClientError

LOG_GROUP = os.environ.get("HERMAN_LOG_GROUP", "")
DEFAULT_MODEL = os.environ.get("HERMAN_MODEL", "")
PRICES = json.loads(os.environ.get("HERMAN_PRICES") or "{}")
USER_POOL_ID = os.environ.get("USER_POOL_ID", "")
QUERY_TIMEOUT = 12  # seconds; the admin function times out at 20
ROW_LIMIT = 10000  # Logs Insights' maximum

QUERY = """fields @timestamp, status, `in`, `out`, sub, email, model, bedrockMs, totalMs
| filter route = "POST /assistant/chat"
| sort @timestamp asc"""


class Unavailable(Exception):
    """The logs couldn't be queried; the page shows Eddie's stats anyway."""


def run_query(logs, start, end):
    """The query's rows as dicts, or raises Unavailable."""
    try:
        query_id = logs.start_query(
            logGroupName=LOG_GROUP, startTime=int(start.timestamp()), endTime=int(end.timestamp()),
            queryString=QUERY, limit=ROW_LIMIT,
        )["queryId"]
        deadline = time.monotonic() + QUERY_TIMEOUT
        while True:
            result = logs.get_query_results(queryId=query_id)
            if result["status"] == "Complete":
                return [{f["field"]: f["value"] for f in row} for row in result.get("results", [])]
            if result["status"] in ("Failed", "Cancelled", "Timeout", "Unknown"):
                raise Unavailable(result["status"])
            if time.monotonic() > deadline:
                logs.stop_query(queryId=query_id)
                raise Unavailable("timed out")
            time.sleep(0.5)
    except (ClientError, BotoCoreError) as err:
        raise Unavailable(type(err).__name__) from None


def number(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def cost(model, tokens_in, tokens_out):
    price = PRICES.get(model)
    if not price:
        return None
    return round(tokens_in * price[0] / 1e6 + tokens_out * price[1] / 1e6, 6)


def add_costs(values):
    """A sum of costs, or None (unknown) if any part is unknown."""
    values = list(values)
    return None if any(v is None for v in values) else round(sum(values), 6)


def timing(values):
    """{median, max} in milliseconds, or None when there are no timings."""
    values = [v for v in values if v is not None]
    if not values:
        return None
    return {"median": round(statistics.median(values)), "max": max(values)}


def current_email(cognito, sub):
    """The user's email in the pool now, or None if unknown. Never raises."""
    if not USER_POOL_ID or cognito is None or sub == "unknown":
        return None
    try:
        users = cognito.list_users(UserPoolId=USER_POOL_ID, Filter=f'sub = "{sub}"', Limit=1)["Users"]
    except (ClientError, BotoCoreError, KeyError):
        return None
    for user in users:
        for attribute in user.get("Attributes", []):
            if attribute.get("Name") == "email":
                return attribute.get("Value")
    return None


def usage(logs, days, cognito=None):
    start = datetime.datetime.combine(days[0], datetime.time(), tzinfo=datetime.timezone.utc)
    end = datetime.datetime.now(datetime.timezone.utc)
    rows = run_query(logs, start, end)

    # One bucket per (day, model); employees and timings are kept alongside.
    def empty():
        return {"turns": 0, "tokensIn": 0, "tokensOut": 0, "off": 0, "errors": 0,
                "subs": set(), "bedrockMs": [], "totalMs": []}

    per_day = {f"{d:%Y-%m-%d}": defaultdict(empty) for d in days}
    per_employee = defaultdict(lambda: {"email": None, "sub": None, "turns": 0, "tokensIn": 0, "tokensOut": 0,
                                        "costs": []})
    for row in rows:
        day = per_day.get((row.get("@timestamp") or "")[:10])
        if day is None:
            continue
        model = row.get("model") or DEFAULT_MODEL
        bucket = day[model]
        status = number(row.get("status"))
        if status == 503:
            bucket["off"] += 1
            continue
        if status in (429, 502):
            bucket["errors"] += 1
            continue
        if status != 200:
            continue  # the caller's own 400/403: not usage
        tokens_in, tokens_out = number(row.get("in")) or 0, number(row.get("out")) or 0
        bucket["turns"] += 1
        bucket["tokensIn"] += tokens_in
        bucket["tokensOut"] += tokens_out
        bucket["bedrockMs"].append(number(row.get("bedrockMs")))
        bucket["totalMs"].append(number(row.get("totalMs")))
        sub = row.get("sub") or "unknown"
        bucket["subs"].add(sub)
        person = per_employee[sub]
        person["sub"] = sub
        person["email"] = row.get("email") or person["email"]
        person["turns"] += 1
        person["tokensIn"] += tokens_in
        person["tokensOut"] += tokens_out
        person["costs"].append(cost(model, tokens_in, tokens_out))

    days_out, by_model = [], defaultdict(empty)
    for date, models in per_day.items():
        merged = empty()
        for model, b in models.items():
            for key in ("turns", "tokensIn", "tokensOut", "off", "errors"):
                merged[key] += b[key]
                by_model[model][key] += b[key]
            for key in ("subs",):
                merged[key] |= b[key]
                by_model[model][key] |= b[key]
            for key in ("bedrockMs", "totalMs"):
                merged[key] += b[key]
                by_model[model][key] += b[key]
        days_out.append({
            "date": date,
            "turns": merged["turns"],
            "employees": len(merged["subs"]),
            "tokensIn": merged["tokensIn"],
            "tokensOut": merged["tokensOut"],
            "cost": add_costs(cost(m, b["tokensIn"], b["tokensOut"]) for m, b in models.items()),
            "off": merged["off"],
            "errors": merged["errors"],
            "bedrockMs": timing(merged["bedrockMs"]),
            "totalMs": timing(merged["totalMs"]),
        })

    models_out = sorted(
        ({"model": m, "turns": b["turns"], "tokensIn": b["tokensIn"], "tokensOut": b["tokensOut"],
          "cost": cost(m, b["tokensIn"], b["tokensOut"]),
          "bedrockMs": timing(b["bedrockMs"]), "totalMs": timing(b["totalMs"])}
         for m, b in by_model.items() if b["turns"] or b["off"] or b["errors"]),
        key=lambda m: -m["turns"],
    )
    for person in per_employee.values():
        person["email"] = current_email(cognito, person["sub"]) or person["email"]

    employees_out = sorted(
        ({"email": p["email"], "sub": p["sub"], "turns": p["turns"], "tokensIn": p["tokensIn"],
          "tokensOut": p["tokensOut"], "cost": add_costs(p["costs"])} for p in per_employee.values()),
        key=lambda p: -(p["cost"] or 0),
    )
    all_bedrock = [v for b in by_model.values() for v in b["bedrockMs"]]
    all_total = [v for b in by_model.values() for v in b["totalMs"]]
    return {
        "days": days_out,
        "byModel": models_out,
        "employees": employees_out,
        "totals": {
            "turns": sum(d["turns"] for d in days_out),
            "employees": len(per_employee),
            "tokensIn": sum(d["tokensIn"] for d in days_out),
            "tokensOut": sum(d["tokensOut"] for d in days_out),
            "cost": add_costs(d["cost"] for d in days_out),
            "off": sum(d["off"] for d in days_out),
            "errors": sum(d["errors"] for d in days_out),
            "bedrockMs": timing(all_bedrock),
            "totalMs": timing(all_total),
        },
        "prices": {m: {"inputPerMillion": p[0], "outputPerMillion": p[1]} for m, p in PRICES.items()},
        "truncated": len(rows) >= ROW_LIMIT,
    }

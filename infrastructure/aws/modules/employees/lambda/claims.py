"""Shared helpers for the employee API's Lambdas.

API Gateway's JWT authorizer has already checked each token's signature,
issuer, audience and expiry before a function runs, so these trust the
claims it passes and never validate the token themselves.
"""

import json


def claims_of(event):
    return event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})


def parse_groups(value):
    # HTTP APIs pass array claims as a string, e.g. "[admins]" or
    # "[admins staff]"; tolerate a real list too.
    if isinstance(value, list):
        return [str(g) for g in value]
    if not value:
        return []
    return [g for g in str(value).strip("[]").replace(",", " ").split() if g]


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }

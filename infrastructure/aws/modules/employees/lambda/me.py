"""GET /me: who's signed in, and the Employees' Space content.

API Gateway's JWT authorizer has already checked the token's signature,
issuer, audience and expiry before this runs, so this trusts the claims it
passes and never validates the token itself. The site sends the ID token,
which carries the email and group claims (the access token has no email).

Protected content lives here, not in the site build: the public
/employees/ page shows nothing until this answers.
"""

import json

CONTENT = {
    "title": "Employees' Space",
    "body": "You're signed in. Employee resources will appear here.",
}


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


def handler(event, context):
    claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})

    if claims.get("token_use") != "id":
        return respond(401, {"message": "Send the ID token."})

    groups = parse_groups(claims.get("cognito:groups"))
    # Logs the user's ID, not their email, for a record of who called.
    print(json.dumps({"route": "GET /me", "sub": claims.get("sub"), "groups": groups}))

    return respond(200, {
        "email": claims.get("email", ""),
        "groups": groups,
        "isAdmin": "admins" in groups,
        **CONTENT,
    })

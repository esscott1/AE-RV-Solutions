"""GET /me: who's signed in, and the Employees' Space content.

The site sends the ID token, which carries the email and group claims (the
access token has no email). Protected content lives here, not in the site
build: the public /employees/ page shows nothing until this answers.
"""

import json

from claims import claims_of, parse_groups, respond

CONTENT = {
    "title": "Employees' Space",
    "body": "You're signed in. Employee resources will appear here.",
}


def handler(event, context):
    claims = claims_of(event)

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

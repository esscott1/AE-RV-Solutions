"""Feature switches for the admin Feature Mgr page (admin.py routes here).

GET  /admin/features          every switch: on or off, and its recent changes
POST /admin/features/{name}   {"enabled": true|false}: turn one on or off

Each switch is an SSM parameter holding "true" or "false", read by whatever
it controls. `eddie` is /ae-rv/chatbot/enabled, which Eddie's state machine
and GET /chat/status check on every request, so a change takes effect in
seconds. FEATURE_FLAGS (from Terraform) maps each name to its parameter,
and the function may read and write only those.

Who changed what comes from the parameter's own version history. This page
writes each change's description ("Off: set on the Feature Mgr page by
<email>"; before the page was renamed, "the Features page"), and LastModifiedUser shows the source: this function's role, the
'Chatbot on/off' workflow's role, Terraform's CI role (which creates the
parameter), or anyone else (console, CLI). Terraform
ignores the parameter's value and description, so applies never undo a
change or its note.
"""

import json
import os
import re

from botocore.exceptions import ClientError

from claims import BadRequest

# What the page shows for each switch. A name here also needs an entry in
# FEATURE_FLAGS (Terraform var.feature_flags) to appear.
FEATURES = {
    "eddie": {
        "label": "Eddie",
        "description": "The public chatbot on every page of the website.",
        "offEffect": "Customers see “Chat is offline” and no AI calls are made.",
    },
    "herman": {
        "label": "Herman",
        "description": "The employee assistant: the Herman tab in the chat window, which drafts knowledge for Eddie.",
        "offEffect": "Employees see “Herman is switched off” in the Herman tab. Eddie, customers, and the "
                     "Add Knowledge form aren’t affected.",
    },
}

FLAGS = json.loads(os.environ.get("FEATURE_FLAGS") or "{}")
PAGE_ROLE = os.environ.get("ADMIN_ROLE_NAME", "")
WORKFLOW_ROLE = os.environ.get("FLAG_WORKFLOW_ROLE_NAME", "")
TERRAFORM_ROLE = os.environ.get("TERRAFORM_ROLE_NAME", "")
HISTORY_SHOWN = 10
# Matches the page's notes from before and after its rename.
PAGE_NOTE = re.compile(r"set on the (?:Features|Feature Mgr) page by (.+)$")


class NotFound(Exception):
    pass


def role_of(arn):
    """The role name in an assumed-role ARN, or None."""
    match = re.search(r":assumed-role/([^/]+)/", arn or "")
    return match.group(1) if match else None


def describe_change(version):
    """One history entry: when, the value, who changed it, and how."""
    arn = version.get("LastModifiedUser", "")
    role = role_of(arn)
    if role and role == PAGE_ROLE:
        note = PAGE_NOTE.search(version.get("Description") or "")
        source, who = "page", note.group(1) if note else "an admin"
    elif role and role == WORKFLOW_ROLE:
        source, who = "workflow", "Chatbot on/off workflow"
    elif role and role == TERRAFORM_ROLE:
        source, who = "terraform", "Terraform"
    else:
        # Console or CLI: the identity's last part, e.g. user/eric -> eric.
        source, who = "other", (arn.rsplit("/", 1)[-1] or arn or "unknown")
    at = version.get("LastModifiedDate")
    return {
        "at": at.isoformat() if hasattr(at, "isoformat") else at,
        "enabled": version.get("Value") == "true",
        "changedBy": who,
        "source": source,
    }


def history(ssm, parameter):
    """Every stored version of the parameter, oldest first (as SSM lists them)."""
    versions = []
    for page in ssm.get_paginator("get_parameter_history").paginate(Name=parameter):
        versions += page.get("Parameters", [])
    return versions


def feature_state(ssm, name):
    info = FEATURES[name]
    state = {"name": name, **info}
    try:
        versions = history(ssm, FLAGS[name])
    except ClientError as err:
        # Fail closed: an unreadable switch shows as unknown, never as on.
        print(json.dumps({"feature": name, "error": err.response["Error"]["Code"]}))
        return {**state, "enabled": None, "updatedAt": None, "changedBy": None, "source": None, "history": [],
                "error": "Couldn’t read this switch."}
    if not versions:
        return {**state, "enabled": None, "updatedAt": None, "changedBy": None, "source": None, "history": []}
    changes = [describe_change(v) for v in reversed(versions[-HISTORY_SHOWN:])]
    latest = changes[0]
    # Exactly "true" is on, the same test Eddie's state machine applies.
    return {**state, "enabled": versions[-1].get("Value") == "true", "updatedAt": latest["at"],
            "changedBy": latest["changedBy"], "source": latest["source"], "history": changes}


def list_features(ssm):
    return {"features": [feature_state(ssm, name) for name in FEATURES if name in FLAGS]}


def set_feature(ssm, caller, name, body):
    if name not in FEATURES or name not in FLAGS:
        raise NotFound()
    enabled = body.get("enabled")
    if not isinstance(enabled, bool):
        raise BadRequest("enabled must be true or false.")

    current = feature_state(ssm, name)
    if current["enabled"] is enabled:
        return current  # already that way: nothing to write

    who = caller["email"] or caller["sub"]
    ssm.put_parameter(
        Name=FLAGS[name], Value="true" if enabled else "false", Type="String", Overwrite=True,
        Description=f"{'On' if enabled else 'Off'}: set on the Feature Mgr page by {who}"[:1024],
    )
    print(json.dumps({"feature": name, "enabled": enabled, "sub": caller["sub"], "email": caller["email"]}))
    return feature_state(ssm, name)

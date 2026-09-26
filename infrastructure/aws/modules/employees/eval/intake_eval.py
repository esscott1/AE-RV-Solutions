"""Herman's knowledge-intake eval.

For each case in intake_cases.json it plays a scripted employee through a
multi-turn conversation with Herman, the way the website will:
  1. adds the employee's next message
  2. builds the request with the Lambda's own code (lambda/herman.py), so the
     prompts, tool, and draft handling are exactly what deploys
  3. calls Claude Haiku 4.5 on Bedrock, then reads the reply with the same
     code, which decides `ready` and `missing`
  4. carries the returned draft into the next turn

The prompts come from the **local** files, so prompt changes can be checked
before they're merged and deployed.

It prints every conversation for a person to judge, and flags the
mechanical rules:
  - "expect_type": the final draft's kind (capability, faq, note)
  - "expect_ready": true or false for the final turn
  - "review_note": true -> some turn set a reviewer note; false -> none did
  - "empty_fields": fields that must still be empty at the end (nothing to
    fill them with, so anything there was invented)
  - "reply_mentions": patterns the first reply must contain
  - "last_reply_mentions": patterns the last reply must contain
  - "replies_must_not": patterns no reply may contain
  - "draft_must_not": patterns the final draft may not contain
  - always: no number in the final draft that the employee (or the seeded
    Eddie chat) didn't give, and no fallback replies

Needs only the AWS CLI (v2):  AWS_PROFILE=OTS-Prod-Deploy python intake_eval.py [case-id ...]
Each turn costs roughly half a cent (Haiku). Exits non-zero if any case is flagged.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lambda"))
sys.dont_write_bytecode = True  # keep __pycache__ out of the Lambda's folder

import herman  # noqa: E402  (the Lambda's own code)

REGION = "us-west-2"
INFERENCE_PROFILE = "us.anthropic.claude-haiku-4-5-20251001-v1:0"  # modules/chatbot variables.tf
NUMBER = re.compile(r"\d+(?:[.,]\d+)*")


def invoke(body):
    with tempfile.TemporaryDirectory() as tmp:
        body_path, out_path = os.path.join(tmp, "body.json"), os.path.join(tmp, "out.json")
        with open(body_path, "w", encoding="utf-8") as f:
            json.dump(body, f)
        run = subprocess.run(["aws", "--region", REGION, "bedrock-runtime", "invoke-model",
                              "--model-id", INFERENCE_PROFILE,
                              "--content-type", "application/json", "--accept", "application/json",
                              "--body", f"fileb://{body_path}", out_path],
                             capture_output=True, text=True)
        if run.returncode != 0:
            sys.exit(f"aws bedrock-runtime invoke-model failed:\n{run.stderr.strip()}")
        with open(out_path, encoding="utf-8") as f:
            return json.load(f)


def numbers_in(text):
    return {n.replace(",", "") for n in NUMBER.findall(text)}


def draft_text(draft):
    return json.dumps(draft["fields"], ensure_ascii=False) if draft else ""


def run_case(case):
    seed = case.get("seed")
    messages, draft, turns = [], None, []
    for text in case["turns"]:
        messages.append({"role": "user", "content": text})
        herman.check_request({"mode": "knowledge", "messages": messages, "draft": draft, "seed": seed})
        response = invoke(herman.build_body("knowledge", messages, draft, seed))
        result = herman.read_turn(response)
        turns.append({"employee": text, "result": result or herman.fallback(draft), "fallback": result is None})
        result = turns[-1]["result"]
        messages.append({"role": "assistant", "content": result["reply"]})
        draft = result["draft"]
    return turns


def check(case, turns):
    problems = []
    final = turns[-1]["result"]
    draft = final["draft"]
    replies = [t["result"]["reply"] for t in turns]

    if any(t["fallback"] for t in turns):
        problems.append("fallback reply (cut off or no tool call)")
    if "expect_type" in case and (draft or {}).get("type") != case["expect_type"]:
        problems.append(f"expected type {case['expect_type']}, got {(draft or {}).get('type')}")
    if "expect_ready" in case and final["ready"] != case["expect_ready"]:
        problems.append(f"expected ready={case['expect_ready']}, got {final['ready']} (missing: {final['missing']})")
    notes = [t["result"]["reviewNote"] for t in turns if t["result"]["reviewNote"]]
    if case.get("review_note") is True and not notes:
        problems.append("expected a reviewer note")
    if case.get("review_note") is False and notes:
        problems.append(f"unexpected reviewer note: {notes[0]}")
    for field in case.get("empty_fields", []):
        if draft and str(draft["fields"].get(field) or "").strip():
            problems.append(f"{field} should be empty, got: {draft['fields'][field][:80]}")
    for pattern in case.get("reply_mentions", []):
        if not re.search(pattern, replies[0], re.IGNORECASE):
            problems.append(f"first reply doesn't mention /{pattern}/")
    for pattern in case.get("last_reply_mentions", []):
        if not re.search(pattern, replies[-1], re.IGNORECASE):
            problems.append(f"last reply doesn't mention /{pattern}/")
    for pattern in case.get("replies_must_not", []):
        hit = next((r for r in replies if re.search(pattern, r, re.IGNORECASE)), None)
        if hit:
            problems.append(f"a reply matches /{pattern}/")
    for pattern in case.get("draft_must_not", []):
        if re.search(pattern, draft_text(draft), re.IGNORECASE):
            problems.append(f"draft contains /{pattern}/")

    given = numbers_in(" ".join(case["turns"]) + " " + json.dumps(case.get("seed") or {}))
    invented = numbers_in(draft_text(draft)) - given
    if invented:
        problems.append(f"numbers the employee never gave: {', '.join(sorted(invented))}")
    return problems


def main():
    with open(os.path.join(HERE, "intake_cases.json"), encoding="utf-8") as f:
        cases = json.load(f)
    only = set(sys.argv[1:])
    if only:
        cases = [c for c in cases if c["id"] in only]
    print(f"{len(cases)} cases, {sum(len(c['turns']) for c in cases)} turns\n")

    flagged = []
    for case in cases:
        turns = run_case(case)
        problems = check(case, turns)
        if problems:
            flagged.append(case["id"])
        print("=" * 78)
        print(f"{case['id']}  [{'FLAG: ' + '; '.join(problems) if problems else 'ok'}]")
        if case.get("seed"):
            print(f"(from Eddie: {case['seed']['question']!r} -> source {case['seed']['source']})")
        for t in turns:
            r = t["result"]
            print(f"\nEmployee: {t['employee']}")
            print(f"Herman:   {r['reply']}")
            flags = [f"type={r['draft']['type'] if r['draft'] else 'undecided'}", f"ready={r['ready']}"]
            if r["reviewNote"]:
                flags.append(f"note={r['reviewNote']!r}")
            print("          (" + ", ".join(flags) + ")")
        final = turns[-1]["result"]["draft"]
        print("\nFinal draft:", json.dumps(final, indent=1, ensure_ascii=False) if final else "none")
        print()

    print("=" * 78)
    print(f"Flagged: {len(flagged)}/{len(cases)}" + (f" -> {', '.join(flagged)}" if flagged else ""))
    print("Read the conversations above for tone and accuracy. Flags only cover the mechanical rules.")
    sys.exit(1 if flagged else 0)


if __name__ == "__main__":
    main()

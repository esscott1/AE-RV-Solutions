"""Answer review for the chatbot's `answer` route: knowledge base + personality.

For each case in answer_cases.json it does what the state machine's Retrieve
and Answer states do:
  1. searches the live knowledge base with the latest customer message
     (plus the previous one, if any)
  2. keeps passages scoring at least MIN_SCORE
  3. calls Claude Haiku 4.5 with the three system blocks (the rules, the
     personality, the <documents>)

The prompts come from the **local** prompt files, so prompt changes can be
reviewed before they're merged and deployed. The settings below mirror
modules/chatbot/main.tf (the retrieval query, the documents block) and
variables.tf (kb_num_results, kb_min_score, answer_max_tokens); keep them in
step. main.tf is authoritative.

It prints every answer, with the passages it used, for a person to judge
tone and accuracy. It also flags answers that break the mechanical rules:
  - "pairing": true  -> exactly one "You could also" line expected
  - "pairing": false -> none expected
  - "pairing": null  -> not checked
  - "no_numbers": true -> the answer must not state quantities (the case
    isn't covered by the knowledge base, so any number would be invented)
  - any answer that is long, or reads like step-by-step wiring.

Needs only the AWS CLI (v2):  AWS_PROFILE=OTS-Prod-Deploy python answers.py
Each case costs roughly $0.005 (Haiku) plus a fraction of a cent (retrieval).
Exits non-zero if any case is flagged.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROMPTS = os.path.join(HERE, "..", "prompts")
REGION = "us-west-2"
KB_NAME = "ae-rv-chatbot-kb"
INFERENCE_PROFILE = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
NUM_RESULTS = 4      # variables.tf kb_num_results
MIN_SCORE = 0.4      # variables.tf kb_min_score
MAX_TOKENS = 600     # variables.tf answer_max_tokens
LONG_ANSWER_CHARS = 1200
# A quantity with a unit: "1,500 W", "30%", "13,000+ watts", "200 Ah".
QUANTITY = re.compile(
    r"\d[\d,.]*\+?\s*(%|percent\b|w\b|watts?\b|wh\b|watt-hours?\b|kwh\b|ah\b|amp-?hours?\b|amps?\b|volts?\b|v\b|btu\b|hours?\b)",
    re.IGNORECASE,
)
STEP_WORDING = re.compile(
    r"\b(step\s*\d|first,?\s+(dis)?connect|connect the (positive|negative|red|black)"
    r"|wire the|strip the|crimp|torque)\b",
    re.IGNORECASE,
)


def aws(*args):
    out = subprocess.run(["aws", "--region", REGION, "--output", "json", *args],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout) if out.stdout.strip() else None


def read_prompt(name):
    with open(os.path.join(PROMPTS, name), encoding="utf-8") as f:
        return f.read()


def knowledge_base_id():
    kbs = aws("bedrock-agent", "list-knowledge-bases")["knowledgeBaseSummaries"]
    return next(kb["knowledgeBaseId"] for kb in kbs if kb["name"] == KB_NAME)


def retrieval_query(messages):
    # Same as main.tf local.retrieval_query.
    users = [m["content"] for m in messages if m["role"] == "user"]
    query = "\n".join(users[-2:])
    return query[:1000]


def retrieve(kb_id, messages):
    result = aws("bedrock-agent-runtime", "retrieve", "--knowledge-base-id", kb_id,
                 "--retrieval-query", json.dumps({"text": retrieval_query(messages)}),
                 "--retrieval-configuration",
                 json.dumps({"vectorSearchConfiguration": {"numberOfResults": NUM_RESULTS}}))
    hits = []
    for r in result["retrievalResults"]:
        source = r["location"].get("s3Location", {}).get("uri", "?").split("/", 3)[-1]
        hits.append((r.get("score", 0.0), source, r["content"]["text"]))
    return hits


def answer(system_blocks, messages):
    body = {"anthropic_version": "bedrock-2023-05-31", "max_tokens": MAX_TOKENS,
            "system": system_blocks, "messages": messages}
    with tempfile.TemporaryDirectory() as tmp:
        body_path, out_path = os.path.join(tmp, "body.json"), os.path.join(tmp, "out.json")
        with open(body_path, "w", encoding="utf-8") as f:
            json.dump(body, f)
        aws("bedrock-runtime", "invoke-model", "--model-id", INFERENCE_PROFILE,
            "--content-type", "application/json", "--accept", "application/json",
            "--body", f"fileb://{body_path}", out_path)
        with open(out_path, encoding="utf-8") as f:
            response = json.load(f)
    text = "".join(c.get("text", "") for c in response.get("content", []) if c.get("type") == "text")
    return text, response.get("stop_reason")


def main():
    with open(os.path.join(HERE, "answer_cases.json"), encoding="utf-8") as f:
        cases = json.load(f)
    rules, personality = read_prompt("assistant.md"), read_prompt("personality.md")
    kb_id = knowledge_base_id()
    print(f"Knowledge base {kb_id}; {len(cases)} cases; min score {MIN_SCORE}\n")

    flagged = []
    for case in cases:
        messages = case["messages"]
        hits = retrieve(kb_id, messages)
        used = [h for h in hits if h[0] >= MIN_SCORE]
        documents = "\n\n---\n\n".join(h[2] for h in used) or "No matching documents."
        system = [{"type": "text", "text": rules},
                  {"type": "text", "text": personality},
                  {"type": "text", "text": f"<documents>\n{documents}\n</documents>"}]
        text, stop = answer(system, messages)

        problems = []
        pairings = len(re.findall(r"\byou could also\b", text, re.IGNORECASE))
        if case["pairing"] is True and pairings != 1:
            problems.append(f"expected one 'You could also', found {pairings}")
        if case["pairing"] is False and pairings:
            problems.append(f"expected no 'You could also', found {pairings}")
        if case.get("no_numbers") and QUANTITY.search(text):
            problems.append(f"invented number: '{QUANTITY.search(text).group(0)}'")
        if len(text) > LONG_ANSWER_CHARS:
            problems.append(f"long answer ({len(text)} chars)")
        if STEP_WORDING.search(text):
            problems.append(f"step-by-step wording: '{STEP_WORDING.search(text).group(0)}'")
        if stop != "end_turn":
            problems.append(f"stop_reason={stop}")
        if problems:
            flagged.append(case["id"])

        print("=" * 78)
        print(f"{case['id']}  [{'FLAG: ' + '; '.join(problems) if problems else 'ok'}]")
        print(f"Q: {messages[-1]['content']}")
        print("passages: " + (", ".join(f"{s:.2f} {src}{'' if s >= MIN_SCORE else ' (dropped)'}"
                                        for s, src, _ in hits) or "none"))
        print(f"A: {text}\n")

    print("=" * 78)
    print(f"Flagged: {len(flagged)}/{len(cases)}" + (f" -> {', '.join(flagged)}" if flagged else ""))
    print("Read the answers above for tone and accuracy. Flags only cover the mechanical rules.")
    sys.exit(1 if flagged else 0)


if __name__ == "__main__":
    main()

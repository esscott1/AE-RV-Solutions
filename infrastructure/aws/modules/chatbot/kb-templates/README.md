# Knowledge base templates

Starting points for the chatbot's knowledge base. **These are examples, not
the real content**, and they live here, outside `knowledge-base/`, so they're
never indexed. Real content goes in the repo's top-level
[`knowledge-base/`](../../../../../knowledge-base) folder, and merging it
publishes it (see that folder's README).

| Template | Use it for | Folder in `knowledge-base/` |
|---|---|---|
| `capability-template.md` | "How do I…" topics (run a microwave off-grid, work remotely from the woods). Its **Also possible with this setup** section is what the chatbot suggests as the one extra capability | `capabilities/` |
| `faq-template.md` | Short questions and answers, many per file | `faq/` |
| `diagram-template.md` | The written description that goes **beside** each diagram file (the chatbot can't read pictures, only your description) | `diagrams/` |
| (no template) | Free-form notes: service notes, rules of thumb, lessons learned. Use `#`/`##` headings | `notes/` |

Tips for good answers:

- **One topic per heading.** The knowledge base cuts documents into
  ~300-token passages (about 200 words). A heading plus its paragraphs
  should make sense on its own.
- **Write like you'd explain it to a customer.** The chatbot paraphrases
  your words, so plain language in gives plain language out.
- **Put numbers in** (watts, amp-hours, runtimes), with the conditions they
  depend on.
- **No step-by-step wiring or battery procedures.** The chatbot won't give
  those out anyway (safety rules); describe *what* is needed and *why*, and
  leave the *how* to a technician visit.
- **This repo is public, and anything in `knowledge-base/` can shape
  answers.** Don't add customer details, prices you don't want quoted, or
  anything confidential.

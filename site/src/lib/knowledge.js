// The three kinds of knowledge the Add Knowledge form offers, and the
// Markdown each produces. The server (modules/employees/lambda/knowledge_fields.py) builds
// the real file from the same fields; buildMarkdown here only powers the
// live preview, so keep the two in step.

export const LIMITS = { title: 120, question: 300, heading: 120, text: 4000, pairs: 20, sections: 10 };

export const TYPES = {
  capability: {
    label: 'Capability',
    card: 'Something a customer can do with their RV, like run a microwave off-grid. Describe what it takes, how we set it up, and one more thing the same setup makes possible.',
    eddie: "Answers “how do I…” questions. Its “Also possible” section is the only place Eddie gets his “You could also…” suggestion.",
    titleLabel: 'Capability',
    titleHint: 'What the customer wants to do, e.g. “Run a microwave off-grid”.',
  },
  faq: {
    label: 'FAQ',
    card: 'Questions customers ask us, like “Does solar work in the shade?”, each with a short answer. Add as many as you like on one topic.',
    eddie: 'Answers the matching question directly and briefly.',
    titleLabel: 'Topic',
    titleHint: 'What the questions are about, e.g. “Solar basics”.',
  },
  note: {
    label: 'Note',
    card: 'Anything else worth knowing, like “Why lithium batteries need a low-temperature cutoff”. Write it as a few headed sections.',
    eddie: 'Background Eddie draws on for general questions.',
    titleLabel: 'Title',
    titleHint: 'The subject of the note, e.g. “Cold-weather battery care”.',
  },
};

export const CAPABILITY_SECTIONS = [
  {
    key: 'whatItTakes',
    label: 'What it takes',
    hint: 'The equipment and sizes needed (watts, watt-hours, amp-hours), with the conditions they depend on.',
  },
  {
    key: 'howWeSetItUp',
    label: 'How A&E sets it up',
    hint: 'Our approach in plain words. No step-by-step wiring: say what is needed and why, and leave the how to a technician.',
  },
  {
    key: 'alsoPossible',
    label: 'Also possible with this setup',
    hint: 'Exactly one more thing the same setup makes possible. Eddie offers this as his one “You could also…” suggestion.',
  },
];

export const WRITING_TIPS = [
  'One topic per heading, in plain words a customer would use.',
  'Put numbers in (watts, amp-hours, runtimes) with the conditions they depend on.',
  'No step-by-step wiring or battery procedures: describe what and why, not how.',
  'No customer details, and no prices you don’t want quoted.',
];

export function emptyFields(type) {
  if (type === 'capability') return { title: '', whatItTakes: '', howWeSetItUp: '', alsoPossible: '' };
  if (type === 'faq') return { title: '', pairs: [{ question: '', answer: '' }] };
  return { title: '', sections: [{ heading: '', body: '' }] };
}

const oneLine = (text) => String(text ?? '').split(/\s+/).filter(Boolean).join(' ');
const body = (text) => String(text ?? '').replace(/\r\n/g, '\n').trim().replace(/^(\s*)#/gm, '$1\\#');

// The same structure kb.py writes: every heading carries the topic.
export function buildMarkdown(type, f) {
  const title = oneLine(f.title) || '…';
  let parts;
  if (type === 'capability') {
    parts = [`# Capability: ${title}`].concat(
      CAPABILITY_SECTIONS.map((s) => `## ${s.label}: ${title}\n\n${body(f[s.key])}`),
    );
  } else if (type === 'faq') {
    parts = [`# Frequently asked questions: ${title}`].concat(
      f.pairs.map((p) => `## Q: ${oneLine(p.question)}\n\n${body(p.answer)}`),
    );
  } else {
    parts = [`# ${title}`].concat(f.sections.map((s) => `## ${title}: ${oneLine(s.heading)}\n\n${body(s.body)}`));
  }
  return `${parts.join('\n\n')}\n`;
}

// First problem with the fields, or '' when they're ready to submit. The
// server checks the same rules.
export function validate(type, f) {
  if (!oneLine(f.title)) return `${TYPES[type].titleLabel} is required.`;
  if (oneLine(f.title).length > LIMITS.title) return `${TYPES[type].titleLabel} is too long.`;
  const tooLong = (text) => String(text ?? '').trim().length > LIMITS.text;
  if (type === 'capability') {
    for (const s of CAPABILITY_SECTIONS) {
      if (!String(f[s.key] ?? '').trim()) return `“${s.label}” is required.`;
      if (tooLong(f[s.key])) return `“${s.label}” is over ${LIMITS.text} characters.`;
    }
  } else if (type === 'faq') {
    // The form always has at least one; a draft from Herman may not.
    if (f.pairs.length === 0) return 'Add at least one question.';
    for (const [i, p] of f.pairs.entries()) {
      if (!oneLine(p.question) || !String(p.answer ?? '').trim()) return `Question ${i + 1} needs a question and an answer.`;
      if (oneLine(p.question).length > LIMITS.question || tooLong(p.answer)) return `Question ${i + 1} is too long.`;
    }
  } else {
    if (f.sections.length === 0) return 'Add at least one section.';
    for (const [i, s] of f.sections.entries()) {
      if (!oneLine(s.heading) || !String(s.body ?? '').trim()) return `Section ${i + 1} needs a heading and text.`;
      if (oneLine(s.heading).length > LIMITS.heading || tooLong(s.body)) return `Section ${i + 1} is too long.`;
    }
  }
  return '';
}

// A document's Markdown as React-friendly blocks (headings, paragraphs,
// lists) for display. Text only: nothing is ever rendered as HTML.
export function markdownBlocks(markdown) {
  const blocks = [];
  let paragraph = [];
  const flush = () => {
    if (paragraph.length) blocks.push({ kind: 'p', text: paragraph.join(' ') });
    paragraph = [];
  };
  for (const raw of String(markdown).split('\n')) {
    const line = raw.replace(/^(\s*)\\#/, '$1#');
    const heading = raw.match(/^(#{1,3})\s+(.*)$/);
    const item = raw.match(/^\s*[-*]\s+(.*)$/);
    if (heading) {
      flush();
      blocks.push({ kind: `h${heading[1].length}`, text: heading[2] });
    } else if (item) {
      flush();
      const last = blocks[blocks.length - 1];
      if (last?.kind === 'ul') last.items.push(item[1]);
      else blocks.push({ kind: 'ul', items: [item[1]] });
    } else if (!line.trim()) {
      flush();
    } else {
      paragraph.push(line.trim());
    }
  }
  flush();
  return blocks;
}

// Removes personal details from a visitor's chat message before it leaves
// the browser, so Eddie (the model), the saved transcripts and the AI Stats
// page only ever see placeholders. This is the only redaction layer: the
// chat API itself doesn't redact, so a client that skips the widget skips it.
//
// Pattern-based, so it covers structured details: emails, card numbers
// (Luhn-checked), SSNs, US phone numbers, VINs, street addresses, and a name
// given as "my name is …". A name mentioned any other way isn't caught.
// Cities and states are deliberately kept: location matters for solar sizing.
//
// Placeholders use Bedrock Guardrails' {TYPE} format, so transcripts would
// read the same if a server-side guardrail is ever added.

// Shown to the visitor under a redacted message ("Removed before sending: …").
export const PII_LABELS = {
  EMAIL: 'email',
  CREDIT_DEBIT_CARD_NUMBER: 'card number',
  US_SOCIAL_SECURITY_NUMBER: 'Social Security number',
  PHONE: 'phone number',
  VEHICLE_IDENTIFICATION_NUMBER: 'VIN',
  ADDRESS: 'street address',
  NAME: 'name',
};

function passesLuhn(digits) {
  let sum = 0;
  for (let i = 0; i < digits.length; i++) {
    let d = Number(digits[digits.length - 1 - i]);
    if (i % 2 === 1) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
  }
  return sum % 10 === 0;
}

const STREET_SUFFIX =
  'Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Lane|Ln|Boulevard|Blvd|Court|Ct|Way|Highway|Hwy|Place|Pl|Circle|Cir|Parkway|Pkwy|Trail|Trl|Terrace|Ter';
const UNIT = String.raw`(?:,?\s+(?:Apt|Unit|Suite|Ste)\.?\s*[A-Za-z0-9-]+|\s*#\s*[A-Za-z0-9-]+)?`;

// Most specific first, so a card number is never half-matched as a phone.
const RULES = [
  {
    type: 'EMAIL',
    pattern: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g,
  },
  {
    // 13-19 digits, optionally grouped by spaces or dashes. The checksum
    // keeps long part and serial numbers from being masked.
    type: 'CREDIT_DEBIT_CARD_NUMBER',
    pattern: /\b\d(?:[ -]?\d){12,18}\b/g,
    accept: (match) => passesLuhn(match.replace(/\D/g, '')),
  },
  {
    type: 'US_SOCIAL_SECURITY_NUMBER',
    pattern: /\b\d{3}-\d{2}-\d{4}\b/g,
  },
  {
    // US numbers: (555) 123-4567, 555-123-4567, 555.123.4567, 555 123 4567,
    // 5551234567, with an optional +1 or 1- prefix. Ten digits are required,
    // so wattages, years and amp-hours never match.
    type: 'PHONE',
    pattern: /(?:\+1[\s.-]?|\b1[\s.-])?(?:\(\d{3}\)\s?|\b\d{3}[\s.-]?)\d{3}[\s.-]?\d{4}\b/g,
  },
  {
    // 17 characters, no I, O or Q, with at least one letter and one digit.
    type: 'VEHICLE_IDENTIFICATION_NUMBER',
    pattern: /\b(?=[A-HJ-NPR-Z0-9]*\d)(?=[A-HJ-NPR-Z0-9]*[A-HJ-NPR-Z])[A-HJ-NPR-Z0-9]{17}\b/gi,
  },
  {
    // "1234 Desert View Dr, Apt 5": a house number, capitalized street words
    // (or "5th"), and a capitalized suffix. Capitals are required because
    // lowercase "way", "drive" and "road" turn up in RV questions ("a 200
    // mile drive").
    type: 'ADDRESS',
    pattern: new RegExp(
      String.raw`\b\d{1,6}\s+(?:(?:[A-Z][A-Za-z'.-]*|\d+(?:st|nd|rd|th))\s+){1,4}(?:${STREET_SUFFIX})\b\.?${UNIT}`,
      'g',
    ),
  },
  {
    // Lowercase addresses, only with abbreviations that don't occur in
    // ordinary sentences, and at most two street words: "123 main st",
    // "123 north main st", but not "8 amps on the ave".
    type: 'ADDRESS',
    pattern: new RegExp(String.raw`\b\d{1,6}\s+(?:[A-Za-z0-9'.-]+\s+){1,2}(?:st|ave|blvd)\b\.?${UNIT}`, 'gi'),
  },
  {
    // Only after an explicit "my name is" / "name's": the next word, plus a
    // second one if it's capitalized ("my name is Dave Smith").
    type: 'NAME',
    pattern: /\b((?:[Mm]y\s+name\s+is|[Mm]y\s+name['’]s|[Nn]ame['’]s)\s+)[A-Za-z][A-Za-z'’-]*(?:\s+[A-Z][A-Za-z'’-]*)?/g,
    replace: (lead) => `${lead}{NAME}`,
  },
];

const ORDER = Object.keys(PII_LABELS);

export function redactPII(input) {
  if (typeof input !== 'string') return { text: input, found: [] };
  const found = new Set();
  let text = input;
  for (const rule of RULES) {
    text = text.replace(rule.pattern, (match, ...groups) => {
      if (rule.accept && !rule.accept(match)) return match;
      found.add(rule.type);
      return rule.replace ? rule.replace(groups[0]) : `{${rule.type}}`;
    });
  }
  return { text, found: ORDER.filter((type) => found.has(type)) };
}

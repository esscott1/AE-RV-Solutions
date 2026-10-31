// Run with `npm test` (node --test). Covers what redactPII must mask and,
// just as important, the RV details it must leave alone.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { redactPII } from '../src/lib/redact.js';

const masked = [
  ['email', 'reach me at dave.smith+rv@example.com', 'reach me at {EMAIL}', ['EMAIL']],
  ['phone, dashes', 'call 555-123-4567', 'call {PHONE}', ['PHONE']],
  ['phone, parens', 'call (555) 123-4567 today', 'call {PHONE} today', ['PHONE']],
  ['phone, dots', 'text 555.123.4567', 'text {PHONE}', ['PHONE']],
  ['phone, spaces', 'text 555 123 4567', 'text {PHONE}', ['PHONE']],
  ['phone, bare', 'my cell 5551234567', 'my cell {PHONE}', ['PHONE']],
  ['phone, +1', 'call +1 555-123-4567', 'call {PHONE}', ['PHONE']],
  ['phone, 1-', 'call 1-555-123-4567', 'call {PHONE}', ['PHONE']],
  ['card, spaced', 'card 4111 1111 1111 1111 thanks', 'card {CREDIT_DEBIT_CARD_NUMBER} thanks', ['CREDIT_DEBIT_CARD_NUMBER']],
  ['card, bare', 'card 4111111111111111', 'card {CREDIT_DEBIT_CARD_NUMBER}', ['CREDIT_DEBIT_CARD_NUMBER']],
  ['ssn', 'ssn 123-45-6789', 'ssn {US_SOCIAL_SECURITY_NUMBER}', ['US_SOCIAL_SECURITY_NUMBER']],
  ['vin', 'VIN is 1FDXE45S8YHA12345', 'VIN is {VEHICLE_IDENTIFICATION_NUMBER}', ['VEHICLE_IDENTIFICATION_NUMBER']],
  ['vin, lowercase', 'vin 1fdxe45s8yha12345', 'vin {VEHICLE_IDENTIFICATION_NUMBER}', ['VEHICLE_IDENTIFICATION_NUMBER']],
  ['address with unit', "I'm at 1234 Desert View Dr Apt 5 in Phoenix", "I'm at {ADDRESS} in Phoenix", ['ADDRESS']],
  ['address, numbered street', 'come to 88 W 5th Ave', 'come to {ADDRESS}', ['ADDRESS']],
  ['address, lowercase', 'park at 123 main st tonight', 'park at {ADDRESS} tonight', ['ADDRESS']],
  ['name', 'Hi, my name is Dave Smith.', 'Hi, my name is {NAME}.', ['NAME']],
  ['name, lowercase', "name's dave and I need help", "name's {NAME} and I need help", ['NAME']],
];

for (const [label, input, expected, found] of masked) {
  test(`masks ${label}`, () => {
    assert.deepEqual(redactPII(input), { text: expected, found });
  });
}

const kept = [
  'I camp near Phoenix, Arizona most winters.',
  'Will 400 Ah run my 3000 W inverter?',
  'Is 12 V enough for a 2019 Winnebago View?',
  'I have Victron, Renogy, and Battle Born gear.',
  'My battery is 3 years old.',
  'It was installed 03/22.',
  'Do you work on the model 2030?',
  'Serial 12345678901234567 on the controller.',
  'Part number 1234 5678 9012 3456 failed.',
  'It dies after a 200 mile drive down the road.',
  'I have 2 more panels on the way.',
  'Between 2019-2021 models, which inverter?',
  'Run 120 volts at 1500 watts for 3 hours.',
  'This is a Winnebago and I am in Tucson.',
  'It pulls 8 amps on the ave.',
  'My 2021 Grand Design Solitude has a 50 amp service.',
  'Order #12345, model 3012-2000-12.',
];

for (const input of kept) {
  test(`keeps "${input}"`, () => {
    assert.deepEqual(redactPII(input), { text: input, found: [] });
  });
}

test('reports each type once, in a fixed order', () => {
  const { text, found } = redactPII(
    'my name is Dave, call 555-123-4567 or 555-987-6543, email a@b.co',
  );
  assert.equal(text, 'my name is {NAME}, call {PHONE} or {PHONE}, email {EMAIL}');
  assert.deepEqual(found, ['EMAIL', 'PHONE', 'NAME']);
});

test('passes non-strings through untouched', () => {
  assert.deepEqual(redactPII(undefined), { text: undefined, found: [] });
});

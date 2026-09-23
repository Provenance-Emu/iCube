import { test } from 'node:test';
import assert from 'node:assert/strict';

import { formatTitle, formatMarker, parseMarker, matchesMarker, formatIssueBody, formatCommentBody } from '../src/format.js';

test('formatTitle uses the first line, trimmed', () => {
  assert.equal(formatTitle('Crash on boot\nmore details here', 'joe'), 'Crash on boot');
});

test('formatTitle truncates to 80 chars with an ellipsis', () => {
  const long = 'x'.repeat(120);
  const title = formatTitle(long, 'joe');
  assert.equal(title.length, 80);
  assert.ok(title.endsWith('…'));
});

test('formatTitle falls back to author name when there is no usable first line', () => {
  assert.equal(formatTitle('   \n  ', 'joe#1234'), 'Discord report from joe#1234');
  assert.equal(formatTitle('', 'joe#1234'), 'Discord report from joe#1234');
});

test('formatMarker / parseMarker round-trip', () => {
  const marker = formatMarker('111', '222');
  assert.equal(marker, '<!-- discord-bridge: message=111 channel=222 -->');
  assert.deepEqual(parseMarker(marker), { messageId: '111', channelId: '222' });
});

test('parseMarker returns null for unrelated text', () => {
  assert.equal(parseMarker('no marker here'), null);
  assert.equal(parseMarker(''), null);
  assert.equal(parseMarker(undefined), null);
});

test('parseMarker finds the marker embedded in a larger issue body', () => {
  const body = `Some report text.\n\nMore text.\n\n<!-- discord-bridge: message=999 channel=888 -->`;
  assert.deepEqual(parseMarker(body), { messageId: '999', channelId: '888' });
});

test('matchesMarker compares both message and channel id', () => {
  const body = 'stuff\n<!-- discord-bridge: message=1 channel=2 -->';
  assert.equal(matchesMarker(body, '1', '2'), true);
  assert.equal(matchesMarker(body, 1, 2), true, 'coerces to string');
  assert.equal(matchesMarker(body, '1', '9'), false);
  assert.equal(matchesMarker(body, '9', '2'), false);
  assert.equal(matchesMarker('no marker', '1', '2'), false);
});

test('formatIssueBody includes quote, author, jump link, attachments, and marker', () => {
  const body = formatIssueBody({
    content: 'Game X crashes on load',
    authorTag: 'joe#1234',
    jumpUrl: 'https://discord.com/channels/1/2/3',
    attachments: ['https://cdn.discord.com/a.png'],
    messageId: '3',
    channelId: '2',
  });
  assert.match(body, /> Game X crashes on load/);
  assert.match(body, /joe#1234/);
  assert.match(body, /https:\/\/discord\.com\/channels\/1\/2\/3/);
  assert.match(body, /https:\/\/cdn\.discord\.com\/a\.png/);
  assert.match(body, /<!-- discord-bridge: message=3 channel=2 -->/);
});

test('formatIssueBody omits the Attachments section when there are none', () => {
  const body = formatIssueBody({
    content: 'no attachments here',
    authorTag: 'joe',
    jumpUrl: 'https://discord.com/channels/1/2/3',
    attachments: [],
    messageId: '3',
    channelId: '2',
  });
  assert.doesNotMatch(body, /Attachments:/);
});

test('formatCommentBody is phrased as a reply and still carries the marker', () => {
  const body = formatCommentBody({
    content: 'follow up details',
    authorTag: 'joe',
    jumpUrl: 'https://discord.com/channels/1/2/4',
    attachments: [],
    messageId: '4',
    channelId: '2',
  });
  assert.match(body, /replied on Discord/);
  assert.match(body, /<!-- discord-bridge: message=4 channel=2 -->/);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { loadChannelMap, resolveMapping, DEFAULT_CHANNEL_MAP, DEFAULT_REPO, COMMON_LABEL } from '../src/mapping.js';

test('loadChannelMap falls back to the default map when env var is unset', () => {
  const map = loadChannelMap(undefined);
  assert.deepEqual(map, DEFAULT_CHANNEL_MAP);
});

test('loadChannelMap falls back to the default map on invalid JSON', () => {
  const map = loadChannelMap('{not json');
  assert.deepEqual(map, DEFAULT_CHANNEL_MAP);
});

test('loadChannelMap parses valid JSON', () => {
  const map = loadChannelMap('{"123": {"label": "bug"}}');
  assert.deepEqual(map, { 123: { label: 'bug' } });
});

test('resolveMapping resolves a directly-mapped channel', () => {
  const map = { 123: { label: 'bug' } };
  const result = resolveMapping(map, { id: '123', parentId: null });
  assert.equal(result.rootChannelId, '123');
  assert.equal(result.repo, DEFAULT_REPO);
  assert.deepEqual(result.labels, ['bug', COMMON_LABEL]);
});

test('resolveMapping follows a thread to its mapped parent channel', () => {
  // This is the easy-to-get-wrong case: a message posted inside a thread has
  // channel.id === the thread id, NOT the mapped forum/text channel id.
  const map = { 999: { label: 'forum-bugs' } };
  const result = resolveMapping(map, { id: 'thread-abc', parentId: '999' });
  assert.equal(result.rootChannelId, '999');
  assert.deepEqual(result.labels, ['forum-bugs', COMMON_LABEL]);
});

test('resolveMapping returns null for an unmapped channel', () => {
  const map = { 123: { label: 'bug' } };
  assert.equal(resolveMapping(map, { id: '456', parentId: null }), null);
});

test('resolveMapping returns null for a thread whose parent is unmapped', () => {
  const map = { 123: { label: 'bug' } };
  assert.equal(resolveMapping(map, { id: 'thread-x', parentId: '999' }), null);
});

test('resolveMapping honors a per-channel repo override', () => {
  const map = { 123: { label: 'bug', repo: 'org/other-repo' } };
  const result = resolveMapping(map, { id: '123', parentId: null });
  assert.equal(result.repo, 'org/other-repo');
});

test('resolveMapping matches numeric-keyed maps against string channel ids', () => {
  const result = resolveMapping(DEFAULT_CHANNEL_MAP, { id: '1421601237966782524', parentId: null });
  assert.ok(result);
  assert.equal(result.labels[0], 'discord:channel-1');
});

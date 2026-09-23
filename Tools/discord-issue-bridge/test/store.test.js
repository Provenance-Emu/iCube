import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { createStore, getIssueFor, setIssueFor, loadStore, saveStore } from '../src/store.js';

async function withTempDir(fn) {
  const dir = await mkdtemp(path.join(tmpdir(), 'discord-issue-bridge-test-'));
  try {
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('createStore/getIssueFor/setIssueFor manage in-memory entries', () => {
  const store = createStore();
  assert.equal(getIssueFor(store, 'abc'), null);
  setIssueFor(store, 'abc', { issueNumber: 5, repo: 'a/b', url: 'https://x' });
  assert.deepEqual(getIssueFor(store, 'abc'), { issueNumber: 5, repo: 'a/b', url: 'https://x' });
});

test('loadStore returns an empty store when the file does not exist', async () => {
  await withTempDir(async (dir) => {
    const store = await loadStore(path.join(dir, 'nested', 'store.json'));
    assert.deepEqual(store.entries, {});
  });
});

test('loadStore logs and returns an empty store on corrupt JSON, without throwing', async () => {
  await withTempDir(async (dir) => {
    const storePath = path.join(dir, 'store.json');
    await writeFile(storePath, '{ not valid json', 'utf8');
    const messages = [];
    const store = await loadStore(storePath, { error: (m) => messages.push(m) });
    assert.deepEqual(store.entries, {});
    assert.equal(messages.length, 1);
  });
});

test('saveStore creates the parent directory and writes readable JSON', async () => {
  await withTempDir(async (dir) => {
    const storePath = path.join(dir, 'nested', 'deeper', 'store.json');
    const store = createStore({ anchor1: { issueNumber: 1, repo: 'a/b', url: 'https://x' } });
    await saveStore(storePath, store);
    const raw = await readFile(storePath, 'utf8');
    assert.deepEqual(JSON.parse(raw), store);
  });
});

test('saveStore leaves no .tmp file behind after a successful write', async () => {
  await withTempDir(async (dir) => {
    const storePath = path.join(dir, 'store.json');
    await saveStore(storePath, createStore());
    const fs = await import('node:fs/promises');
    const entries = await fs.readdir(dir);
    assert.deepEqual(entries, ['store.json']);
  });
});

test('round-trip: saveStore then loadStore reproduces the same entries', async () => {
  await withTempDir(async (dir) => {
    const storePath = path.join(dir, 'store.json');
    const original = createStore({ 'thread-1': { issueNumber: 42, repo: 'org/repo', url: 'https://example/42' } });
    await saveStore(storePath, original);
    const reloaded = await loadStore(storePath);
    assert.deepEqual(reloaded.entries, original.entries);
  });
});

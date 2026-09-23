// Persists the anchor-id -> GitHub-issue mapping ("thread/message id" ->
// issue number) so restarts don't lose dedupe state or double-post.
// Only node:fs/node:path -- no discord.js/@octokit -- so this stays
// unit-testable and reusable from bridge.js.

import { promises as fs } from 'node:fs';
import path from 'node:path';

/** In-memory store shape. `entries` maps anchorId -> { issueNumber, repo, url }. */
export function createStore(initialEntries = {}) {
  return { entries: { ...initialEntries } };
}

export function getIssueFor(store, anchorId) {
  return store.entries[anchorId] ?? null;
}

export function setIssueFor(store, anchorId, issue) {
  store.entries[anchorId] = issue;
}

/** Loads a store from disk. Missing file -> empty store. Corrupt file -> logged + empty store (never throws). */
export async function loadStore(storePath, logger = console) {
  try {
    const raw = await fs.readFile(storePath, 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && parsed.entries && typeof parsed.entries === 'object') {
      return createStore(parsed.entries);
    }
    logger.error(`[store] ${storePath} did not contain the expected shape; starting empty`);
    return createStore();
  } catch (err) {
    if (err.code === 'ENOENT') return createStore();
    logger.error(`[store] failed to load ${storePath}: ${err.message}; starting empty`);
    return createStore();
  }
}

/** Writes the store to disk atomically (write to .tmp, then rename), creating the parent dir if needed. */
export async function saveStore(storePath, store) {
  const dir = path.dirname(storePath);
  await fs.mkdir(dir, { recursive: true });
  const tmpPath = `${storePath}.${process.pid}.tmp`;
  await fs.writeFile(tmpPath, JSON.stringify(store, null, 2), 'utf8');
  await fs.rename(tmpPath, storePath);
}

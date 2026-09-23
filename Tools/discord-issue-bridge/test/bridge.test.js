import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createStore } from '../src/store.js';
import { createBridge } from '../src/bridge.js';

const CHANNEL_MAP = {
  text1: { label: 'l-text1' },
  forum1: { label: 'l-forum1' },
};

function silentLogger() {
  return { info: () => {}, error: () => {} };
}

function fakeGithub(overrides = {}) {
  let nextNumber = 100;
  const created = [];
  const comments = [];
  return {
    created,
    comments,
    searchIssueByMarker: overrides.searchIssueByMarker ?? (async () => null),
    createIssue: overrides.createIssue ?? (async ({ repo, title, body, labels }) => {
      const number = nextNumber++;
      const issue = { number, repo, url: `https://github.com/${repo}/issues/${number}`, title, body, labels };
      created.push(issue);
      return issue;
    }),
    addComment: overrides.addComment ?? (async ({ repo, issueNumber, body }) => {
      const comment = { repo, issueNumber, body, url: `https://github.com/${repo}/issues/${issueNumber}#comment` };
      comments.push(comment);
      return comment;
    }),
  };
}

function baseInput(overrides = {}) {
  const replies = overrides.replies ?? [];
  return {
    id: 'msg-1',
    channelId: 'text1',
    parentId: null,
    content: 'Game crashes on boot',
    authorTag: 'joe#1234',
    isBot: false,
    jumpUrl: 'https://discord.com/channels/g/text1/msg-1',
    attachments: [],
    referenceMessageId: null,
    isThreadStart: false,
    reply: async (text) => replies.push(text),
    replies,
    ...overrides,
  };
}

function makeBridge(extra = {}) {
  const store = extra.store ?? createStore();
  const github = extra.github ?? fakeGithub();
  const persisted = [];
  const bridge = createBridge({
    channelMap: extra.channelMap ?? CHANNEL_MAP,
    defaultRepo: 'org/repo',
    store,
    github,
    dryRun: extra.dryRun ?? false,
    ignorePrefix: extra.ignorePrefix ?? '!',
    persistStore: async () => persisted.push(JSON.stringify(store.entries)),
    logger: extra.logger ?? silentLogger(),
  });
  return { bridge, store, github, persisted };
}

test('unmapped channel is skipped', async () => {
  const { bridge } = makeBridge();
  const result = await bridge.process(baseInput({ channelId: 'unmapped-channel' }));
  assert.deepEqual(result, { skipped: 'unmapped' });
});

test('bot messages are ignored', async () => {
  const { bridge, github } = makeBridge();
  const result = await bridge.process(baseInput({ isBot: true }));
  assert.deepEqual(result, { skipped: 'bot' });
  assert.equal(github.created.length, 0);
});

test('empty content is ignored', async () => {
  const { bridge } = makeBridge();
  const result = await bridge.process(baseInput({ content: '   ' }));
  assert.deepEqual(result, { skipped: 'empty' });
});

test('messages starting with the ignore prefix are skipped', async () => {
  const { bridge } = makeBridge();
  const result = await bridge.process(baseInput({ content: '!ignore me please' }));
  assert.deepEqual(result, { skipped: 'ignored-prefix' });
});

test('a custom ignore prefix is honored', async () => {
  const { bridge } = makeBridge({ ignorePrefix: '##' });
  const result = await bridge.process(baseInput({ content: '##skip this' }));
  assert.deepEqual(result, { skipped: 'ignored-prefix' });
});

test('a new top-level message creates an issue, replies once, and persists', async () => {
  const { bridge, github, store, persisted } = makeBridge();
  const replies = [];
  const result = await bridge.process(baseInput({ replies }));

  assert.ok(result.created);
  assert.equal(github.created.length, 1);
  assert.equal(github.created[0].repo, 'org/repo');
  assert.deepEqual(github.created[0].labels, ['l-text1', 'discord-report']);
  assert.equal(replies.length, 1);
  assert.equal(replies[0], result.created.url);
  assert.equal(store.entries['msg-1'].issueNumber, result.created.number);
  assert.equal(persisted.length, 1);
});

test('the same message processed twice only creates one issue (store dedupe)', async () => {
  const { bridge, github } = makeBridge();
  const first = await bridge.process(baseInput());
  const second = await bridge.process(baseInput());
  assert.ok(first.created);
  assert.deepEqual(second, { skipped: 'duplicate', issue: second.issue });
  assert.equal(github.created.length, 1);
});

test('concurrent processing of the same new message only creates one issue', async () => {
  // Regression test for the dedupe lock needing to span "check store + search
  // GitHub + create + write store" as a single critical section, not just
  // the GitHub write itself.
  let calls = 0;
  const github = fakeGithub({
    createIssue: async ({ repo }) => {
      calls += 1;
      await new Promise((resolve) => setTimeout(resolve, 10));
      return { number: 200 + calls, repo, url: `https://github.com/${repo}/issues/${200 + calls}` };
    },
  });
  const { bridge } = makeBridge({ github });

  const [a, b] = await Promise.all([bridge.process(baseInput()), bridge.process(baseInput())]);
  assert.equal(calls, 1, 'createIssue should only be called once for concurrent duplicate input');
  const outcomes = [a, b].sort((x, y) => (x.created ? -1 : 1));
  assert.ok(outcomes[0].created);
  assert.equal(outcomes[1].skipped, 'duplicate');
});

test('a forum thread start creates an issue keyed by the thread id', async () => {
  const { bridge, github, store } = makeBridge();
  const result = await bridge.process(
    baseInput({
      id: 'thread-1',
      channelId: 'thread-1',
      parentId: 'forum1',
      isThreadStart: true,
      content: 'Forum post body',
    }),
  );
  assert.ok(result.created);
  assert.deepEqual(github.created[0].labels, ['l-forum1', 'discord-report']);
  assert.ok(store.entries['thread-1']);
});

test('a later message in a tracked thread becomes a comment, not a new issue', async () => {
  const store = createStore({ 'thread-1': { issueNumber: 55, repo: 'org/repo', url: 'https://github.com/org/repo/issues/55' } });
  const { bridge, github } = makeBridge({ store });

  const result = await bridge.process(
    baseInput({
      id: 'msg-in-thread',
      channelId: 'thread-1',
      parentId: 'forum1',
      isThreadStart: false,
      content: 'more info',
    }),
  );

  assert.deepEqual(result.commented, store.entries['thread-1']);
  assert.equal(github.comments.length, 1);
  assert.equal(github.comments[0].issueNumber, 55);
  assert.equal(github.created.length, 0);
});

test('a reply to a tracked top-level message becomes a comment on its issue', async () => {
  const store = createStore({ 'orig-msg': { issueNumber: 77, repo: 'org/repo', url: 'https://github.com/org/repo/issues/77' } });
  const { bridge, github } = makeBridge({ store });

  const result = await bridge.process(
    baseInput({
      id: 'reply-msg',
      channelId: 'text1',
      parentId: null,
      referenceMessageId: 'orig-msg',
      content: 'additional detail via reply',
    }),
  );

  assert.deepEqual(result.commented, store.entries['orig-msg']);
  assert.equal(github.comments[0].issueNumber, 77);
});

test('a follow-up with no known anchor falls back to creating a new issue instead of dropping it', async () => {
  const { bridge, github } = makeBridge();
  // Simulate a message inside a thread we never saw get created (store empty).
  const result = await bridge.process(
    baseInput({
      id: 'orphan-thread-msg',
      channelId: 'thread-unknown',
      parentId: 'forum1',
      isThreadStart: false,
      content: 'orphaned thread message',
    }),
  );
  assert.ok(result.created);
  assert.equal(github.created.length, 1);
});

test('a second message in an orphan thread becomes a comment on the issue the first one created (not another issue)', async () => {
  // Regression test: the fallback in handleFollowup must anchor the newly
  // created issue under the id that FUTURE lookups in this thread will use
  // (the thread/channel id), not the triggering message's own id -- else
  // every message in an orphaned thread creates its own new issue forever.
  const { bridge, github, store } = makeBridge();

  const first = await bridge.process(
    baseInput({
      id: 'orphan-msg-1',
      channelId: 'thread-unknown',
      parentId: 'forum1',
      isThreadStart: false,
      content: 'first message in an orphaned thread',
    }),
  );
  assert.ok(first.created);
  assert.equal(github.created.length, 1);
  assert.ok(store.entries['thread-unknown'], 'issue should be anchored under the thread id');

  const second = await bridge.process(
    baseInput({
      id: 'orphan-msg-2',
      channelId: 'thread-unknown',
      parentId: 'forum1',
      isThreadStart: false,
      content: 'second message in the same orphaned thread',
    }),
  );

  assert.equal(github.created.length, 1, 'no second issue should be created');
  assert.ok(second.commented, 'second message should become a comment on the first issue');
  assert.equal(github.comments.length, 1);
  assert.equal(github.comments[0].issueNumber, first.created.number);
});

test('a lost store recovers via GitHub search keyed on the thread anchor, not the triggering message id', async () => {
  // Regression test: the marker/search must be keyed on `anchor` (the
  // thread id), because that's what a fresh volume with an empty store has
  // no other way to recover -- searching by the triggering message's own id
  // would never match a marker written for the thread's anchor id.
  const github = fakeGithub({
    searchIssueByMarker: async ({ messageId }) =>
      messageId === 'thread-1' ? { number: 5, repo: 'org/repo', url: 'https://github.com/org/repo/issues/5' } : null,
  });
  const { bridge, store } = makeBridge({ github });

  const result = await bridge.process(
    baseInput({
      id: 'msg-in-thread-after-restart',
      channelId: 'thread-1',
      parentId: 'forum1',
      isThreadStart: false,
      content: 'a message in a thread the empty store forgot about',
    }),
  );

  assert.equal(github.created.length, 0, 'must not create a duplicate issue');
  assert.equal(result.created.number, 5);
  assert.deepEqual(store.entries['thread-1'], { issueNumber: 5, repo: 'org/repo', url: 'https://github.com/org/repo/issues/5' });
});

test('when GitHub search finds an existing issue, no duplicate is created', async () => {
  const github = fakeGithub({
    searchIssueByMarker: async () => ({ number: 9, repo: 'org/repo', url: 'https://github.com/org/repo/issues/9' }),
  });
  const { bridge, store } = makeBridge({ github });
  const replies = [];
  const result = await bridge.process(baseInput({ replies }));

  assert.equal(github.created.length, 0);
  assert.equal(result.created.number, 9);
  assert.equal(store.entries['msg-1'].issueNumber, 9);
  assert.equal(replies[0], 'https://github.com/org/repo/issues/9');
});

test('a GitHub search failure does not prevent issue creation', async () => {
  const github = fakeGithub({ searchIssueByMarker: async () => { throw new Error('rate limited'); } });
  const { bridge } = makeBridge({ github });
  const result = await bridge.process(baseInput());
  assert.ok(result.created);
  assert.equal(github.created.length, 1);
});

test('dryRun logs instead of writing to GitHub, replies, but deliberately does NOT touch the store', async () => {
  // If dryRun wrote to the store, flipping DRY_RUN off afterwards (the
  // README's own recommended workflow) would silently skip filing the real
  // issue because the anchor would already look "handled".
  const github = fakeGithub();
  const { bridge, store, persisted } = makeBridge({ github, dryRun: true });
  const replies = [];
  const result = await bridge.process(baseInput({ replies }));

  assert.equal(github.created.length, 0);
  assert.ok(result.created.url.startsWith('dry-run://'));
  assert.equal(store.entries['msg-1'], undefined);
  assert.equal(persisted.length, 0);
  assert.equal(replies.length, 1);
});

test('the same message processed twice under dryRun logs/replies both times (no dedupe without a store write)', async () => {
  const { bridge } = makeBridge({ dryRun: true });
  const first = await bridge.process(baseInput());
  const second = await bridge.process(baseInput());
  assert.ok(first.created);
  assert.ok(second.created);
});

test('dryRun does not call addComment for a follow-up', async () => {
  const store = createStore({ 'thread-1': { issueNumber: 55, repo: 'org/repo', url: 'https://x/55' } });
  const github = fakeGithub();
  const { bridge } = makeBridge({ store, github, dryRun: true });

  const result = await bridge.process(
    baseInput({ id: 'm2', channelId: 'thread-1', parentId: 'forum1', isThreadStart: false, content: 'more' }),
  );
  assert.deepEqual(result.commented, store.entries['thread-1']);
  assert.equal(github.comments.length, 0);
});

test('a createIssue failure is reported and does not update the store or reply', async () => {
  const github = fakeGithub({ createIssue: async () => { throw new Error('GitHub is down'); } });
  const { bridge, store } = makeBridge({ github });
  const replies = [];
  const result = await bridge.process(baseInput({ replies }));

  assert.ok(result.error);
  assert.equal(store.entries['msg-1'], undefined);
  assert.equal(replies.length, 0);
});

test('a follow-up does not re-reply on Discord (only the original creation replies)', async () => {
  const store = createStore({ 'thread-1': { issueNumber: 55, repo: 'org/repo', url: 'https://x/55' } });
  const { bridge } = makeBridge({ store });
  const replies = [];

  await bridge.process(
    baseInput({ id: 'm2', channelId: 'thread-1', parentId: 'forum1', isThreadStart: false, content: 'more info', replies }),
  );
  assert.equal(replies.length, 0);
});

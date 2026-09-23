// Event-handling core: message/thread input -> GitHub issue/comment.
// Discord and GitHub access is fully injected (`github`, and reply()/join()
// callbacks on each input) so this module never imports discord.js or
// @octokit/rest and can be driven in tests with plain objects.

import { resolveMapping } from './mapping.js';
import { formatTitle, formatIssueBody, formatCommentBody } from './format.js';

/**
 * A tiny FIFO queue that serializes async tasks onto one promise chain, so
 * GitHub writes (create issue / add comment) never race each other. A
 * failing task is isolated -- it doesn't wedge the queue for tasks queued
 * after it -- but its own caller still sees the rejection.
 */
function createQueue() {
  let tail = Promise.resolve();
  return function enqueue(task) {
    const result = tail.then(task, task);
    tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  };
}

/**
 * @param {object} deps
 * @param {object} deps.channelMap - see mapping.js#loadChannelMap
 * @param {string} deps.defaultRepo - "owner/name" fallback when a channel entry has no repo override
 * @param {string} [deps.ignorePrefix] - messages starting with this are ignored (default "!")
 * @param {boolean} [deps.dryRun] - log instead of writing to GitHub
 * @param {object} deps.store - a store.js `createStore()` instance (mutated in place)
 * @param {object} deps.github - { searchIssueByMarker, createIssue, addComment }
 * @param {() => Promise<void>} [deps.persistStore] - called after every store mutation
 * @param {Console} [deps.logger]
 */
export function createBridge({
  channelMap,
  defaultRepo,
  ignorePrefix = '!',
  dryRun = false,
  store,
  github,
  persistStore = async () => {},
  logger = console,
}) {
  const enqueue = createQueue();

  /**
   * @param {object} input
   * @param {string} input.id - message id (or, for a new thread, the thread id)
   * @param {string} input.channelId - the channel the message lives in (a thread id, if posted in a thread)
   * @param {string|null} input.parentId - set to the parent channel id when `channelId` is a thread
   * @param {string} input.content
   * @param {string} input.authorTag
   * @param {boolean} input.isBot
   * @param {string} input.jumpUrl
   * @param {string[]} [input.attachments]
   * @param {string|null} [input.referenceMessageId] - id of the message this one is a reply to, if any
   * @param {boolean} [input.isThreadStart] - true when this input represents a brand-new thread's starter message
   * @param {(text: string) => Promise<unknown>} input.reply
   */
  async function process(input) {
    const mapped = resolveMapping(channelMap, { id: input.channelId, parentId: input.parentId }, defaultRepo);
    if (!mapped) return { skipped: 'unmapped' };
    if (input.isBot) return { skipped: 'bot' };

    const content = (input.content ?? '').trim();
    if (!content) return { skipped: 'empty' };
    if (ignorePrefix && content.startsWith(ignorePrefix)) return { skipped: 'ignored-prefix' };

    return enqueue(() => route(mapped, input, content));
  }

  async function route(mapped, input, content) {
    const isThreadChannel = Boolean(input.parentId);

    if (isThreadChannel) {
      return input.isThreadStart
        ? handleNew({ mapped, input, content, anchor: input.channelId })
        : handleFollowup({ mapped, input, content, anchor: input.channelId });
    }

    if (input.referenceMessageId && store.entries[input.referenceMessageId]) {
      return handleFollowup({ mapped, input, content, anchor: input.referenceMessageId });
    }

    return handleNew({ mapped, input, content, anchor: input.id });
  }

  async function handleNew({ mapped, input, content, anchor }) {
    // Dedupe, step 1: our own store (fast path, covers the common case).
    const existing = store.entries[anchor];
    if (existing) {
      return { skipped: 'duplicate', issue: existing };
    }

    // Dedupe, step 2: ask GitHub in case the store was lost/reset but the
    // issue still exists (e.g. redeployed with an empty volume). The marker
    // is keyed on `anchor`, not `input.id`: for a thread, anchor is the
    // thread id (what every future message in that thread will look up),
    // and for a forum thread-start the two already coincide (a thread's
    // starter message shares its id with the thread). Keying on the
    // message id instead would make this search miss every thread whose
    // triggering message wasn't the thread's own id.
    let found = null;
    try {
      found = await github.searchIssueByMarker({ repo: mapped.repo, messageId: anchor, channelId: input.channelId });
    } catch (err) {
      // Search failing (rate limit, outage) is not a reason to drop a bug
      // report: log it and fall through to creating the issue.
      logger.error(`[bridge] GitHub marker search failed, creating anyway: ${err.message}`);
    }

    let issue;
    if (found) {
      issue = found;
    } else if (dryRun) {
      // Deliberately does NOT touch the store: if it did, flipping DRY_RUN
      // off after a smoke test would leave these anchors permanently marked
      // "already filed" and the real issues would never get created.
      const title = formatTitle(content, input.authorTag);
      logger.info(`[dry-run] would create issue in ${mapped.repo}: "${title}" (labels: ${mapped.labels.join(', ')})`);
      const dryIssue = { number: 0, repo: mapped.repo, url: `dry-run://${mapped.repo}/${anchor}` };
      await safeReply(input, dryIssue.url);
      return { created: dryIssue };
    } else {
      const title = formatTitle(content, input.authorTag);
      const body = formatIssueBody({
        content,
        authorTag: input.authorTag,
        jumpUrl: input.jumpUrl,
        attachments: input.attachments ?? [],
        messageId: anchor, // keep the marker consistent with what searchIssueByMarker looks up
        channelId: input.channelId,
      });
      try {
        issue = await github.createIssue({ repo: mapped.repo, title, body, labels: mapped.labels });
      } catch (err) {
        logger.error(`[bridge] failed to create GitHub issue: ${err.message}`);
        return { error: err };
      }
    }

    store.entries[anchor] = { issueNumber: issue.number, repo: issue.repo ?? mapped.repo, url: issue.url };
    await persistStore();
    await safeReply(input, issue.url);

    return { created: issue };
  }

  async function handleFollowup({ mapped, input, content, anchor }) {
    const existing = store.entries[anchor];
    if (!existing) {
      // Thread/message we don't recognize (e.g. store was reset, or a
      // manually-created thread we never saw the parent of). Rather than
      // silently dropping a bug report, treat it as a new one -- anchored
      // the same way a later follow-up in this thread will look it up
      // (thread id when we're in a thread, message id otherwise), so the
      // NEXT message here becomes a comment instead of yet another issue.
      const fallbackAnchor = input.parentId ? input.channelId : input.id;
      return handleNew({ mapped, input, content, anchor: fallbackAnchor });
    }

    if (dryRun) {
      logger.info(`[dry-run] would comment on ${existing.repo}#${existing.issueNumber}`);
      return { commented: existing };
    }

    const body = formatCommentBody({
      content,
      authorTag: input.authorTag,
      jumpUrl: input.jumpUrl,
      attachments: input.attachments ?? [],
      messageId: input.id,
      channelId: input.channelId,
    });

    // No Discord reply here: the bot already posted the issue URL once when
    // the issue was created, and repeating it on every follow-up would spam
    // the thread.
    try {
      await github.addComment({ repo: existing.repo, issueNumber: existing.issueNumber, body });
      return { commented: existing };
    } catch (err) {
      logger.error(`[bridge] failed to add GitHub comment: ${err.message}`);
      return { error: err };
    }
  }

  async function safeReply(input, text) {
    if (typeof input.reply !== 'function') return;
    try {
      await input.reply(text);
    } catch (err) {
      logger.error(`[bridge] failed to reply on Discord: ${err.message}`);
    }
  }

  return { process };
}

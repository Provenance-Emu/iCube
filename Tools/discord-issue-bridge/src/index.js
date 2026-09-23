// Real wiring: discord.js + @octokit/rest clients feeding the pure bridge.
// This is the only file allowed to import those two packages -- everything
// business-logic-shaped lives in src/{format,mapping,store,bridge}.js and is
// tested without network access.

import { Client, GatewayIntentBits, Partials } from 'discord.js';
import { Octokit } from '@octokit/rest';

import { loadChannelMap, DEFAULT_REPO } from './mapping.js';
import { matchesMarker } from './format.js';
import { loadStore, saveStore } from './store.js';
import { createBridge } from './bridge.js';

const config = {
  discordToken: requireEnv('DISCORD_BOT_TOKEN'),
  githubToken: requireEnv('GITHUB_TOKEN'),
  defaultRepo: process.env.GITHUB_REPO || DEFAULT_REPO,
  channelMap: loadChannelMap(process.env.CHANNEL_MAP),
  storePath: process.env.STORE_PATH || './data/store.json',
  dryRun: /^(1|true)$/i.test(process.env.DRY_RUN || ''),
  ignorePrefix: process.env.IGNORE_PREFIX ?? '!',
};

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`[index] missing required env var ${name}`);
    process.exit(1);
  }
  return value;
}

/** Renders a Discord user as "name#0001" (legacy) or just "name" (migrated/no discriminator). */
function tagFor(user) {
  if (!user) return 'unknown';
  if (user.discriminator && user.discriminator !== '0') {
    return `${user.username}#${user.discriminator}`;
  }
  return user.username ?? 'unknown';
}

function attachmentUrls(attachments) {
  return Array.from(attachments?.values() ?? []).map((a) => a.url);
}

function createGithubClient(octokit) {
  return {
    async searchIssueByMarker({ repo, messageId, channelId }) {
      // GitHub's search tokenizes on punctuation, so the raw HTML-comment
      // marker isn't a reliable query string. Search for the bare message
      // id instead, then verify the marker client-side against each hit.
      const res = await octokit.rest.search.issuesAndPullRequests({
        q: `repo:${repo} type:issue in:body "${messageId}"`,
      });
      const hit = res.data.items.find((item) => matchesMarker(item.body ?? '', messageId, channelId));
      return hit ? { number: hit.number, repo, url: hit.html_url } : null;
    },
    async createIssue({ repo, title, body, labels }) {
      const [owner, name] = repo.split('/');
      const res = await octokit.rest.issues.create({ owner, repo: name, title, body, labels });
      return { number: res.data.number, repo, url: res.data.html_url };
    },
    async addComment({ repo, issueNumber, body }) {
      const [owner, name] = repo.split('/');
      const res = await octokit.rest.issues.createComment({ owner, repo: name, issue_number: issueNumber, body });
      return { url: res.data.html_url };
    },
  };
}

async function main() {
  const store = await loadStore(config.storePath);
  const octokit = new Octokit({ auth: config.githubToken });
  const github = createGithubClient(octokit);

  const bridge = createBridge({
    channelMap: config.channelMap,
    defaultRepo: config.defaultRepo,
    ignorePrefix: config.ignorePrefix,
    dryRun: config.dryRun,
    store,
    github,
    persistStore: () => saveStore(config.storePath, store),
    logger: console,
  });

  const client = new Client({
    intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.MessageContent],
    // Needed to receive events for threads/messages that arrive uncached
    // (e.g. right after a restart, or a forum post the bot hasn't seen yet).
    partials: [Partials.Channel, Partials.Message],
  });

  async function dispatch(input) {
    try {
      const result = await bridge.process(input);
      if (result?.created) console.log(`[index] created ${result.created.repo}#${result.created.number} <- ${input.id}`);
      else if (result?.commented) console.log(`[index] commented on ${result.commented.repo}#${result.commented.issueNumber} <- ${input.id}`);
      else if (result?.error) console.error(`[index] error handling ${input.id}: ${result.error.message}`);
      // 'skipped' results are routine (unmapped channel, bot, empty, dup) and not worth logging at info level.
    } catch (err) {
      console.error(`[index] unhandled error processing ${input.id}: ${err.stack || err.message}`);
    }
  }

  client.on('messageCreate', (message) => {
    const channel = message.channel;
    const isThread = typeof channel.isThread === 'function' && channel.isThread();
    // A forum post's starter message shares its id with the thread itself;
    // that case is created via 'threadCreate' below, so skip it here to
    // avoid creating the same issue twice.
    if (isThread && message.id === channel.id) return;

    void dispatch({
      id: message.id,
      channelId: message.channelId,
      parentId: isThread ? channel.parentId : null,
      content: message.content,
      authorTag: tagFor(message.author),
      isBot: message.author?.bot ?? false,
      jumpUrl: message.url,
      attachments: attachmentUrls(message.attachments),
      referenceMessageId: message.reference?.messageId ?? null,
      isThreadStart: false,
      reply: (text) => message.reply(text),
    });
  });

  client.on('threadCreate', async (thread) => {
    if (!thread.parentId) return; // not a forum/text-channel thread we care about
    try {
      await thread.join().catch(() => {}); // best-effort; needed to read/post in some thread types
      const starter = await thread.fetchStarterMessage();
      if (!starter) return; // not available yet; a later real reply will still be handled by messageCreate

      await dispatch({
        id: thread.id,
        channelId: thread.id,
        parentId: thread.parentId,
        content: starter.content,
        authorTag: tagFor(starter.author),
        isBot: starter.author?.bot ?? false,
        jumpUrl: starter.url,
        attachments: attachmentUrls(starter.attachments),
        referenceMessageId: null,
        isThreadStart: true,
        reply: (text) => thread.send(text),
      });
    } catch (err) {
      console.error(`[index] threadCreate handling failed for ${thread.id}: ${err.message}`);
    }
  });

  client.on('error', (err) => console.error(`[index] discord client error: ${err.message}`));

  let shuttingDown = false;
  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`[index] received ${signal}, shutting down`);
    try {
      await saveStore(config.storePath, store);
    } catch (err) {
      console.error(`[index] failed to persist store on shutdown: ${err.message}`);
    }
    client.destroy();
    process.exit(0);
  }
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));

  await client.login(config.discordToken);
  console.log(`[index] logged in as ${client.user?.tag}; dryRun=${config.dryRun}; repo=${config.defaultRepo}`);
}

main().catch((err) => {
  console.error(`[index] fatal startup error: ${err.stack || err.message}`);
  process.exit(1);
});

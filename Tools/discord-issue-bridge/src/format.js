// Pure text-formatting helpers: message -> GitHub issue title/body/comment.
// No discord.js / @octokit/rest imports here on purpose, so this module (and
// anything that only depends on it) can be unit-tested without network I/O
// or a real Discord/GitHub client.

const MAX_TITLE_LENGTH = 80;

/**
 * Title = first line of the message, trimmed to MAX_TITLE_LENGTH chars.
 * Falls back to "Discord report from <author>" when the message has no
 * usable first line (e.g. an attachment-only message that slipped through).
 */
export function formatTitle(content, authorTag) {
  const firstLine = (content ?? '').split('\n')[0].trim();
  if (!firstLine) {
    return `Discord report from ${authorTag}`;
  }
  if (firstLine.length <= MAX_TITLE_LENGTH) {
    return firstLine;
  }
  return `${firstLine.slice(0, MAX_TITLE_LENGTH - 1).trimEnd()}…`;
}

/** The hidden HTML-comment marker used for dedupe (stored in every issue/comment body). */
export function formatMarker(messageId, channelId) {
  return `<!-- discord-bridge: message=${messageId} channel=${channelId} -->`;
}

const MARKER_RE = /<!--\s*discord-bridge:\s*message=(\S+)\s+channel=(\S+)\s*-->/;

/** Extracts {messageId, channelId} from a marker embedded in text, or null. */
export function parseMarker(text) {
  const match = MARKER_RE.exec(text ?? '');
  if (!match) return null;
  return { messageId: match[1], channelId: match[2] };
}

/** True when `text` contains a marker for exactly this message/channel pair. */
export function matchesMarker(text, messageId, channelId) {
  const parsed = parseMarker(text);
  if (!parsed) return false;
  return parsed.messageId === String(messageId) && parsed.channelId === String(channelId);
}

function quoteBlock(content) {
  const body = (content ?? '').length ? content : '*(no text content)*';
  return body
    .split('\n')
    .map((line) => `> ${line}`)
    .join('\n');
}

function attachmentsSection(attachments) {
  if (!attachments || attachments.length === 0) return '';
  return `\nAttachments:\n${attachments.map((url) => `- ${url}`).join('\n')}\n`;
}

/** Body for the GitHub issue created from the first message/thread post. */
export function formatIssueBody({ content, authorTag, jumpUrl, attachments = [], messageId, channelId }) {
  return [
    quoteBlock(content),
    '',
    `Reported by **${authorTag}** via Discord: ${jumpUrl}`,
    attachmentsSection(attachments),
    formatMarker(messageId, channelId),
  ]
    .join('\n')
    .replace(/\n{3,}/g, '\n\n');
}

/** Body for a GitHub comment mirroring a follow-up Discord message. */
export function formatCommentBody({ content, authorTag, jumpUrl, attachments = [], messageId, channelId }) {
  return [
    quoteBlock(content),
    '',
    `**${authorTag}** replied on Discord: ${jumpUrl}`,
    attachmentsSection(attachments),
    formatMarker(messageId, channelId),
  ]
    .join('\n')
    .replace(/\n{3,}/g, '\n\n');
}

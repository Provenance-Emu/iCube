// Channel -> {repo, labels} resolution. Pure module: no discord.js/@octokit
// imports, so it stays unit-testable with plain objects.

export const DEFAULT_REPO = 'Provenance-Emu/iCube';

// Applied to every mapped channel in addition to its per-channel label, so
// all bridged issues can be found/filtered with one label regardless of
// which of the three channels they came from.
export const COMMON_LABEL = 'discord-report';

// Placeholder default for guild 421819941835243520. The bot author does not
// know what these three channels are actually used for -- the maintainer
// MUST rename these labels (in GitHub and/or via CHANNEL_MAP) to something
// meaningful. See README.md.
// Discord snowflake ids are 64-bit and exceed Number.MAX_SAFE_INTEGER, so
// these MUST be string keys -- a numeric literal here would silently round
// to a different id and break every lookup.
export const DEFAULT_CHANNEL_MAP = {
  '1421601237966782524': { label: 'discord:channel-1' },
  '1421601261748355102': { label: 'discord:channel-2' },
  '1421606150373249198': { label: 'discord:channel-3' },
};

/** Parses the CHANNEL_MAP env var, falling back to DEFAULT_CHANNEL_MAP on missing/invalid JSON. */
export function loadChannelMap(json) {
  if (!json) return { ...DEFAULT_CHANNEL_MAP };
  try {
    const parsed = JSON.parse(json);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed;
    }
  } catch {
    // fall through to default below
  }
  return { ...DEFAULT_CHANNEL_MAP };
}

/**
 * Resolves the mapping entry for a channel, following thread -> parent
 * channel when the channel is a thread. `channel` is a plain
 * `{ id, parentId }` shape (parentId is set only for threads), never a real
 * discord.js Channel -- callers normalize before calling this.
 *
 * Returns null when the channel (or its parent, for a thread) isn't mapped.
 */
export function resolveMapping(channelMap, channel, defaultRepo = DEFAULT_REPO) {
  const rootId = channel.parentId ?? channel.id;
  const entry = channelMap[rootId] ?? channelMap[String(rootId)];
  if (!entry) return null;
  return {
    rootChannelId: String(rootId),
    repo: entry.repo ?? defaultRepo,
    labels: [entry.label, COMMON_LABEL].filter(Boolean),
  };
}

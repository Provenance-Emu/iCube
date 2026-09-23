# discord-issue-bridge

Mirrors bug reports posted in three Discord channels into GitHub issues on
`Provenance-Emu/iCube` (configurable). A new top-level message in a mapped
text channel, or a new post in a mapped forum channel, becomes one GitHub
issue. Later replies in that thread/message become comments on the same
issue. Plain Node 20+ ESM, no build step.

## How it works

- `src/format.js` — pure text formatting (issue title/body, comment body, the hidden dedupe marker). No network deps.
- `src/mapping.js` — channel id -> `{repo, labels}` resolution, including thread -> parent channel lookup. No network deps.
- `src/store.js` — persists `anchor id -> issue number` to `STORE_PATH` (atomic write, survives restarts). No network deps.
- `src/bridge.js` — event handling logic (dedupe, routing new-vs-followup, a serializing write queue). Discord/GitHub access is fully injected, so this has no network deps either.
- `src/index.js` — the only file that imports `discord.js` and `@octokit/rest`; wires the real clients into `bridge.js`.

Everything except `src/index.js` is covered by `npm test` without any network access or real credentials.

## 1. Create the Discord application

1. https://discord.com/developers/applications → **New Application**.
2. **Bot** tab → **Add Bot** → copy the token → this is `DISCORD_BOT_TOKEN`.
3. **Bot** tab → **Privileged Gateway Intents** → enable **Message Content Intent** (required to read report text).
4. **OAuth2 → URL Generator**:
   - Scopes: `bot`
   - Bot Permissions: **View Channels**, **Send Messages**, **Read Message History**, **Send Messages in Threads**
5. Open the generated URL and invite the bot to guild `421819941835243520` (or your guild).
6. In code, the bot subscribes to gateway intents `Guilds`, `GuildMessages`, `MessageContent` (see `src/index.js`) — these must match what you enabled in step 3.

## 2. Create the GitHub token

1. GitHub → Settings → Developer settings → **Fine-grained personal access tokens** → **Generate new token**.
2. Resource owner: the org/user that owns the target repo. Repository access: **Only select repositories** → the target repo (default `Provenance-Emu/iCube`).
3. Permissions → **Issues**: **Read and write**.
4. Copy the token → this is `GITHUB_TOKEN`.

## 3. Labels you must create in the target repo

The bot applies two labels to every issue it files: a per-channel label and
the common `discord-report` label. Create these in the repo's Issues →
Labels page before running the bot (GitHub does not auto-create labels via
the API used here):

- `discord-report` (applied to every bridged issue)
- `discord:channel-1`, `discord:channel-2`, `discord:channel-3` — **placeholders**.

> **The bot author does not know what channels 1421601237966782524,
> 1421601261748355102, and 1421606150373249198 actually are.** Rename these
> three labels (and, ideally, the `label` values in `CHANNEL_MAP` below) to
> whatever those channels really represent (e.g. `discord:ios-bugs`,
> `discord:android-bugs`) before relying on this in production.

## 4. Configuration

| Env var | Required | Default | Notes |
|---|---|---|---|
| `DISCORD_BOT_TOKEN` | yes | — | Bot tab → Token |
| `GITHUB_TOKEN` | yes | — | fine-grained PAT, Issues: read/write |
| `GITHUB_REPO` | no | `Provenance-Emu/iCube` | `owner/name`, used when a channel entry has no `repo` override |
| `CHANNEL_MAP` | no | see below | JSON: `{"channelId": {"label": "...", "repo": "owner/name (optional)"}}` |
| `STORE_PATH` | no | `./data/store.json` | dedupe/thread->issue persistence; must be on writable, persistent storage |
| `DRY_RUN` | no | `false` | `true`/`1` logs what would be created instead of calling GitHub |
| `IGNORE_PREFIX` | no | `!` | messages starting with this string are ignored (set to empty to disable) |

Default `CHANNEL_MAP` (guild `421819941835243520`):

```json
{
  "1421601237966782524": { "label": "discord:channel-1" },
  "1421601261748355102": { "label": "discord:channel-2" },
  "1421606150373249198": { "label": "discord:channel-3" }
}
```

Every issue also gets the common `discord-report` label regardless of channel.

## 5. Local run

```bash
npm install
cp .env.example .env   # fill in DISCORD_BOT_TOKEN / GITHUB_TOKEN
node --env-file=.env src/index.js
```

(Node 20.6+ supports `--env-file`; otherwise export the vars yourself.)

### DRY_RUN smoke test

Before pointing this at a real repo, run it with `DRY_RUN=true` and post a
test message in a mapped channel/forum. You should see log lines like:

```
[dry-run] would create issue in org/repo: "..." (labels: discord:channel-1, discord-report)
```

and a Discord reply with a fake `dry-run://...` URL, with **no** GitHub API
calls made, no real issue created, and (deliberately) no write to
`STORE_PATH` — so flipping `DRY_RUN` off afterwards files the real issue for
that same message instead of treating it as already-handled.

## 6. Tests

```bash
npm install
npm test
```

`src/format.js`, `src/mapping.js`, `src/store.js`, and `src/bridge.js` are
tested directly with `node:test` — no Discord/GitHub credentials or network
access needed.

## 7. Deploying to fly.io

```bash
fly launch --no-deploy        # review/adjust fly.toml (app name, region)
fly volumes create discord_issue_bridge_data --size 1 --region <region>
fly secrets set DISCORD_BOT_TOKEN=... GITHUB_TOKEN=...
# optional: fly secrets set CHANNEL_MAP='{"...":{"label":"..."}}'
fly deploy
```

`fly.toml` mounts the volume at `/data` and sets `STORE_PATH=/data/store.json`
so the dedupe store survives restarts/redeploys. There's no HTTP service to
expose — the bot only makes outbound connections to Discord's gateway and
GitHub's REST API.

## 8. Running with docker-compose

```bash
cp .env.example .env   # fill in DISCORD_BOT_TOKEN / GITHUB_TOKEN
docker compose up --build
```

Store data persists in the `discord-issue-bridge-data` named volume.

## Behavior notes / assumptions

- **Dedupe**: the store (`STORE_PATH`) is checked first; if empty (e.g. a
  fresh volume) the bot falls back to a GitHub search for the hidden
  `<!-- discord-bridge: message=<id> channel=<id> -->` marker before
  creating, so a lost store doesn't necessarily cause duplicate issues.
  If that GitHub search itself fails (rate limit, outage), the bot logs the
  failure and creates the issue anyway rather than silently dropping a bug
  report — this can occasionally produce a duplicate in that failure window,
  which was judged the lesser problem for a bug tracker.
- **Reply**: the bot posts the issue URL back to Discord once, when the
  issue is first created. Follow-up comments do not re-post the URL.
- **Title**: first line of the message, trimmed to 80 characters (with an
  ellipsis) if longer; falls back to `Discord report from <author>` if the
  message has no usable first line.
- **Ignored messages**: from bots, with empty/whitespace-only content, or
  starting with `IGNORE_PREFIX`. An attachment-only message with no text is
  treated as "empty content" per this same rule (its attachment is not,
  today, enough on its own to open an issue) — flag this if that's not what
  you want.
- **DRY_RUN** still replies on Discord (with a fake `dry-run://` URL) so you
  can see the flow end-to-end, but intentionally does **not** write to
  `STORE_PATH` — so re-running the same message under `DRY_RUN` logs again
  each time, and turning `DRY_RUN` off afterwards creates the real issue
  instead of treating the message as already handled.
- Threads/forum posts: a forum post's starter message and its thread share
  the same Discord id, so `src/index.js` only creates the issue from the
  `threadCreate` event and explicitly ignores the matching `messageCreate`
  for that same id, to avoid filing it twice.

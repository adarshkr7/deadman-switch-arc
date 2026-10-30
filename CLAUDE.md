# arf

Submission for Arc Microgrants: Built with Arc Studio. See README.md for the requirements and checklist.

## Arc Studio usage limits

Arc Studio (driven via the `arc-studio` CLI) is metered. Exact quotas are not published; `arc-studio usage --json` reports only the percentage used of whichever cap is closest.

- **Caps:** a rolling 30-day limit, a daily limit (resets the next day), and a cap on active sandboxes (`429 active-sandbox-limit`).
- **Per-turn limits:** prompt max 10,000 characters; `--file` max 100 files, 1 MB each, 10 MB total.
- **On `budget_exceeded` (exit code 4):** do not retry. Report the `budget` field to the user. Never run `arc-studio upgrade` yourself: it opens a payment page that the user decides on.
- **On a 429 sandbox limit:** free a slot with `arc-studio pause --app <appId>` (or `--session <name>`).

How to work within them:

- Run `arc-studio usage --json` before and after each build turn and tell the user the percentage.
- One focused task per session or turn. Iterate with follow-up turns rather than regenerating the whole app.
- Contract deploys are the expensive turns (5–20 minutes). Don't redeploy without a reason.
- If one turn uses a large share of the limit, stop and propose cutting scope before continuing.

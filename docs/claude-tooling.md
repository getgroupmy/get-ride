# Claude Code tooling in this repo

Everything below is checked in, so every Claude Code session on this repo (local or cloud) gets it without an install step. Skills live in `.claude/skills/`, plugin marketplaces and hooks in `.claude/settings.json`, MCP servers in `.mcp.json`. Upstream licenses are in `.claude/licenses/` (Anthropic skills carry their own `LICENSE.txt` inside each folder).

| Source | What was added | Where |
| --- | --- | --- |
| [diegosouzapw/OmniRoute](https://github.com/diegosouzapw/OmniRoute) | 47 skills for driving the OmniRoute AI gateway (`cli-*`, `omni-*`, `config-codex-cli`, `ponytail`). The gateway itself is a server, not a skill — see *Running the proxies* below. | `.claude/skills/` |
| [firecrawl/firecrawl](https://github.com/firecrawl/firecrawl) | 5 `firecrawl-build*` skills + the `firecrawl-mcp` server (needs `FIRECRAWL_API_KEY` in your environment). | `.claude/skills/`, `.mcp.json` |
| [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) | `graphify` skill + PreToolUse hooks (no-ops unless the `graphify` CLI is installed: `pip install graphifyy` / see upstream). | `.claude/skills/graphify`, `.claude/settings.json` |
| [headroomlabs-ai/headroom](https://github.com/headroomlabs-ai/headroom) | Marketplace registered (`headroom-marketplace`), plugin **not enabled** — its hooks call the `headroom` CLI, which must be installed first. | `.claude/settings.json` |
| `claude plugin install claude-code-setup@claude-plugins-official` | Marketplace registered and plugin enabled; its `claude-automation-recommender` skill is also vendored so it works before the plugin installs. | `.claude/settings.json`, `.claude/skills/` |
| [rebelytics/one-skill-to-rule-them-all](https://github.com/rebelytics/one-skill-to-rule-them-all) | `one-skill-to-rule-them-all` skill (task observer) with its references and scripts. | `.claude/skills/` |
| [obra/superpowers](https://github.com/obra/superpowers) | 15 skills (brainstorming, writing/executing plans, TDD, systematic debugging, code review, worktrees, …). | `.claude/skills/` |
| [juliusbrussee/caveman](https://github.com/juliusbrussee/caveman) | 22 skills (`caveman*`, `cavecrew`, `megacave`, `ultracave`, `surgical-patch`, `safe-refactor`, …). | `.claude/skills/` |
| [anthropics/claude-code-security-review](https://github.com/anthropics/claude-code-security-review) | `/security-review` command + PR workflow (runs once the `CLAUDE_API_KEY` repo secret is set; skipped otherwise). | `.claude/commands/`, `.github/workflows/security-review.yml` |
| [anthropics/skills](https://github.com/anthropics/skills/tree/main/skills) | All 19 skills (docx, pdf, pptx, xlsx, frontend-design, mcp-builder, webapp-testing, skill-creator, claude-api, …). | `.claude/skills/` |
| [liquidslr/system-design-notes](https://github.com/liquidslr/system-design-notes) | New `system-design-notes` skill wrapping the 28 chapters as text references (diagrams not vendored). | `.claude/skills/system-design-notes` |
| [mobile-next/mobile-mcp](https://github.com/mobile-next/mobile-mcp) | `mobile-mcp` MCP server + `mobile-automation` skill — drives iOS simulators / Android emulators for testing the Flutter app. | `.mcp.json`, `.claude/skills/` |

The plugin marketplaces for superpowers, caveman, one-skill, anthropic skills and mobile-mcp are registered too, but their plugins are left disabled because the same skills are already vendored — enabling both would load every skill twice. Prefer the plugin instead? Delete the vendored folders and enable it with `/plugin`.

## Running the proxies

These are services you run beside Claude Code, not things a repo can install:

- **OmniRoute** (multi-provider AI gateway): `npm install -g omniroute && omniroute` → OpenAI-compatible endpoint at `http://localhost:20128/v1`. Docker: `diegosouzapw/omniroute`.
- **Headroom** (context compression): `uv tool install --python 3.13 "headroom-ai[all]"` (or `pip install "headroom-ai[all]"`), then `headroom wrap claude` or `headroom proxy --port 8787`. After installing, enable the plugin with `/plugin` → `headroom@headroom-marketplace`.

## Updating

Re-run the copy from a fresh `git clone --depth 1` of each source. OmniRoute's skills are generated upstream (`src/lib/agentSkills/generator.ts`) — don't hand-edit them.

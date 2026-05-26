#!/usr/bin/env node

/**
 * Auto-update README with latest projects and open source contributions.
 *
 * Usage:
 *   GITHUB_TOKEN=... node scripts/update-readme.mjs          # write changes
 *   GITHUB_TOKEN=... node scripts/update-readme.mjs --dry-run # preview only
 *
 * Markers in README.md:
 *   <!-- AUTO-GENERATED:PROJECTS:START --> ... <!-- AUTO-GENERATED:PROJECTS:END -->
 *   <!-- AUTO-GENERATED:CONTRIBUTIONS:START --> ... <!-- AUTO-GENERATED:CONTRIBUTIONS:END -->
 */

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

const dryRun = process.argv.includes("--dry-run");
const TOKEN = process.env.GITHUB_TOKEN;
const README_PATH = resolve(ROOT, "README.md");
const CONFIG_PATH = resolve(__dirname, "readme-config.json");

// ─── Category emoji resolution ──────────────────────────────────────

/** Resolve the emoji for a repo: prefer parsed existing → falls back to defaultEmoji. */
function resolveEmoji(repoName, byCategory, existingEmojis, catId) {
  if (existingEmojis[repoName]) return existingEmojis[repoName];
  const cat = byCategory.find((c) => c.id === catId);
  return cat?.defaultEmoji || "📦";
}

// ─── Config ───────────────────────────────────────────────────────────

const config = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
const USERNAME = config.username;
const EXCLUDE_REPOS = new Set(config.excludeRepos || []);

// ─── GitHub API helpers ──────────────────────────────────────────────

const headers = {
  Authorization: `token ${TOKEN}`,
  Accept: "application/vnd.github.v3+json",
};

async function ghFetch(url) {
  const res = await fetch(url, { headers });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`GitHub API ${res.status}: ${url}\n${body}`);
  }
  return res.json();
}

/** Fetch all public non-fork repos for the user. */
async function fetchAllRepos() {
  const repos = [];
  let page = 1;
  while (true) {
    const data = await ghFetch(
      `https://api.github.com/users/${USERNAME}/repos?sort=pushed&direction=desc&per_page=100&page=${page}`,
    );
    const filtered = data.filter(
      (r) => !r.fork && !r.private && !EXCLUDE_REPOS.has(r.name),
    );
    repos.push(...filtered);
    if (data.length < 100) break;
    page++;
  }
  return repos;
}

/** Fetch PRs via search API (paginated). */
async function fetchPRs(query) {
  const prs = [];
  const seen = new Set();
  let page = 1;
  while (true) {
    const data = await ghFetch(
      `https://api.github.com/search/issues?q=${encodeURIComponent(query)}&sort=updated&order=desc&per_page=100&page=${page}`,
    );
    if (!data.items?.length) break;
    for (const pr of data.items) {
      if (!seen.has(pr.id)) {
        seen.add(pr.id);
        prs.push(pr);
      }
    }
    if (data.items.length < 100) break;
    page++;
  }
  return prs;
}

// ─── Categorization ───────────────────────────────────────────────────

function categorizeRepos(repos) {
  const byCategory = {};
  const matched = new Set();

  for (const cat of config.categories) {
    byCategory[cat.id] = [];
    const pattern = cat.pattern ? new RegExp(cat.pattern) : null;
    const repoSet = cat.repos ? new Set(cat.repos) : null;

    for (const repo of repos) {
      if (matched.has(repo.name)) continue;
      if (pattern && pattern.test(repo.name)) {
        byCategory[cat.id].push(repo);
        matched.add(repo.name);
      } else if (repoSet && repoSet.has(repo.name)) {
        byCategory[cat.id].push(repo);
        matched.add(repo.name);
      }
    }
  }

  // Warn about unmatched repos
  const unmatched = repos.filter((r) => !matched.has(r.name));
  if (unmatched.length > 0) {
    console.warn(
      "⚠️  Unmatched repos (not in any category):",
      unmatched.map((r) => r.name).join(", "),
    );
  }

  return byCategory;
}

// ─── Markdown generation ──────────────────────────────────────────────

function generateProjectsSection(byCategory, categories, existingEmojis) {
  const lines = ["## Featured Projects", ""];

  for (const cat of config.categories) {
    const repos = byCategory[cat.id] || [];
    if (repos.length === 0) continue;

    // Sort by pushed_at descending
    repos.sort(
      (a, b) => new Date(b.pushed_at) - new Date(a.pushed_at),
    );

    lines.push(`### ${cat.name}`);
    if (cat.description) lines.push(`*${cat.description}*`, "");
    for (const repo of repos) {
      const emoji = resolveEmoji(repo.name, categories, existingEmojis, cat.id);
      const desc = config.descriptionMap?.[repo.name] || repo.description || "";
      const suffix = desc ? ` - ${desc}` : "";
      lines.push(
        `- ${emoji} **[${repo.name}](${repo.html_url})**${suffix}`,
      );
    }
    lines.push("");
  }

  return lines.join("\n").trimEnd();
}

function generateContributionsSection(openPRs, mergedPRs) {
  const isSelfPR = (pr) =>
    pr.repository_url.includes(`/${USERNAME}/`);

  const open = openPRs.filter((pr) => !isSelfPR(pr));
  const merged = mergedPRs.filter((pr) => !isSelfPR(pr));

  const lines = ["## Open Source Contributions", ""];

  if (open.length > 0) {
    lines.push("### 🔓 Open Pull Requests", "");
    for (const pr of open) {
      const repoPath = pr.repository_url.replace(
        "https://api.github.com/repos/",
        "",
      );
      lines.push(`- [${pr.title}](${pr.html_url}) — \`${repoPath}\``);
    }
    lines.push("");
  }

  if (merged.length > 0) {
    const MERGED_PREVIEW = 20;
    lines.push("### ✅ Merged Pull Requests", "");
    const visible = merged.slice(0, MERGED_PREVIEW);
    const hidden = merged.slice(MERGED_PREVIEW);
    for (const pr of visible) {
      const repoPath = pr.repository_url.replace(
        "https://api.github.com/repos/",
        "",
      );
      lines.push(`- [${pr.title}](${pr.html_url}) — \`${repoPath}\``);
    }
    if (hidden.length > 0) {
      lines.push("");
      lines.push("<details>");
      lines.push(`<summary>Show ${hidden.length} more merged PRs</summary>`);
      lines.push("");
      for (const pr of hidden) {
        const repoPath = pr.repository_url.replace(
          "https://api.github.com/repos/",
          "",
        );
        lines.push(`- [${pr.title}](${pr.html_url}) — \`${repoPath}\``);
      }
      lines.push("");
      lines.push("</details>");
    }
    lines.push("");
  }

  return lines.join("\n").trimEnd();
}

// ─── Parse existing emojis from README ──────────────────────────────

function parseExistingEmojis(readme) {
  const emojis = {};
  const regex = /- (\p{Extended_Pictographic})\s+\*\*\[([^\]]+)\]/gu;
  for (const match of readme.matchAll(regex)) {
    const [_, em, name] = match;
    emojis[name] = em;
  }
  return emojis;
}

// ─── README section replacement ──────────────────────────────────────

function replaceBetweenMarkers(content, id, newSection) {
  const start = `<!-- AUTO-GENERATED:${id}:START -->`;
  const end = `<!-- AUTO-GENERATED:${id}:END -->`;

  const startIdx = content.indexOf(start);
  const endIdx = content.indexOf(end);

  if (startIdx === -1 || endIdx === -1) {
    console.warn(`⚠️  Markers for ${id} not found — skipping`);
    return content;
  }

  const before = content.substring(0, startIdx + start.length);
  const after = content.substring(endIdx);

  return `${before}\n${newSection}\n${after}`;
}

// ─── Main ─────────────────────────────────────────────────────────────

async function main() {
  if (!TOKEN) {
    console.error("GITHUB_TOKEN is required");
    process.exit(1);
  }

  console.log("📡 Fetching repos...");
  const repos = await fetchAllRepos();
  console.log(`   Found ${repos.length} public non-fork repos`);

  const byCategory = categorizeRepos(repos);

  console.log("📡 Fetching PRs...");
  const openPRs = await fetchPRs(
    `author:${USERNAME} is:pr state:open is:public`,
  );
  const mergedPRs = await fetchPRs(
    `author:${USERNAME} is:pr is:merged is:public`,
  );
  console.log(
    `   Found ${openPRs.length} open, ${mergedPRs.length} merged PRs`,
  );

  let existingEmojis = {};
  let readme;
  if (!dryRun) {
    readme = readFileSync(README_PATH, "utf-8");
    existingEmojis = parseExistingEmojis(readme);
    console.log(`   Parsed ${Object.keys(existingEmojis).length} existing emojis`);
  }

  const projectsMd = generateProjectsSection(byCategory, config.categories, existingEmojis);
  const contributionsMd = generateContributionsSection(openPRs, mergedPRs);

  if (dryRun) {
    console.log("\n═══ PROJECTS (dry-run) ═══\n");
    console.log(projectsMd);
    console.log("\n═══ CONTRIBUTIONS (dry-run) ═══\n");
    console.log(contributionsMd);
    console.log("\n(Dry run — no changes written)");
    return;
  }

  readme = replaceBetweenMarkers(readme, "PROJECTS", projectsMd);
  readme = replaceBetweenMarkers(readme, "CONTRIBUTIONS", contributionsMd);

  writeFileSync(README_PATH, readme);
  console.log("✅ README updated");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

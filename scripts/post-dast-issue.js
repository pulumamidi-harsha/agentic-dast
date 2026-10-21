/**
 * Create or update a sticky GitHub Issue with the DAST report markdown.
 * Expects AGENTIC_TMP/dast-report.md and env GITHUB_* from Actions.
 */
const fs = require('fs');

const AGENTIC_TMP = process.env.AGENTIC_TMP || '/tmp/agentic-dast';
const MARKER = '<!-- agentic-dast:issue -->';
const TITLE = process.env.DAST_ISSUE_TITLE || 'Agentic DAST — latest scan results';

function read(path, fallback = '') {
  try { return fs.readFileSync(path, 'utf8'); } catch { return fallback; }
}

module.exports = async function ({ github, context, core }) {
  const body = read(`${AGENTIC_TMP}/dast-report.md`).trim();
  if (!body) {
    core.warning('dast-report.md missing — skip issue post');
    return;
  }

  const owner = context.repo.owner;
  const repo = context.repo.repo;

  // Search open issues with our marker
  const q = `repo:${owner}/${repo} is:issue in:body "${MARKER}"`;
  let existing = null;
  try {
    const { data } = await github.rest.search.issuesAndPullRequests({
      q,
      per_page: 5,
      sort: 'updated',
      order: 'desc',
    });
    existing = (data.items || []).find(i => (i.body || '').includes(MARKER)) || null;
  } catch (e) {
    core.warning(`issue search failed: ${e.message}`);
  }

  // Fallback: list recent issues
  if (!existing) {
    try {
      const { data } = await github.rest.issues.listForRepo({
        owner,
        repo,
        state: 'open',
        per_page: 50,
        sort: 'updated',
        direction: 'desc',
      });
      existing = data.find(i => (i.body || '').includes(MARKER) || i.title === TITLE) || null;
    } catch (e) {
      core.warning(`list issues failed: ${e.message}`);
    }
  }

  if (existing) {
    await github.rest.issues.update({
      owner,
      repo,
      issue_number: existing.number,
      title: TITLE,
      body,
      state: 'open',
    });
    core.info(`Updated DAST issue #${existing.number}`);
  } else {
    const { data: created } = await github.rest.issues.create({
      owner,
      repo,
      title: TITLE,
      body,
      labels: ['security', 'dast'],
    });
    core.info(`Created DAST issue #${created.number}`);
  }
};

// Probity (https://github.com/nizos/probity) — agent guardrails, enforced as
// PreToolUse hooks (see .claude/settings.json).
//
// We use ONLY Probity's DETERMINISTIC rules. Its AI-validated `enforceTdd()`
// was tried and removed: it validates each production write with a nested
// Claude SDK call, which cannot authenticate in a sub-agent / headless CI /
// cron context ("Not logged in") and fails CLOSED — blocking ALL layout-path
// writes regardless of TDD compliance. This repo is built around sub-agents
// and headless automation, so an env-dependent write-blocker is the wrong
// tool. TDD-first is now enforced deterministically instead (see below +
// docs/TESTING.md): the Stop hook blocks a turn from ending with red tests,
// this requireCommand blocks a commit without a preceding test run, and CI +
// the Codecov patch gate block merging under-tested changes. Test-first
// ordering is kept as discipline via .claude/rules/tdd-geometry.md.
//
// Requires @nizos/probity (npm install -g @nizos/probity, or npx fetches it).
import { defineConfig, requireCommand } from '@nizos/probity'

export default defineConfig({
  rules: [
    {
      files: ['**'],
      rules: [
        requireCommand({
          before: { kind: 'command', match: /git commit/ },
          command: /swift test/,
          after: { kind: 'write' },
          reason:
            'Run swift test (at least the affected module: swift test --filter <Module>Tests) before committing — see docs/TESTING.md.',
        }),
      ],
    },
  ],
})

// Probity (https://github.com/nizos/probity) — agent guardrails, enforced as
// PreToolUse hooks (see .claude/settings.json). Two rules:
//
//  1. TDD on the geometry/layout paths: production-code writes there are
//     blocked until a failing test has been observed. Scoped narrowly so
//     refactors, docs, and unrelated code stay unblocked. (docs/TESTING.md)
//  2. `git commit` requires tests to have run since the last file write.
//
// Requires @nizos/probity (npm install -g @nizos/probity, or npx fetches it).
import { defineConfig, enforceTdd, requireCommand } from '@nizos/probity'

export default defineConfig({
  rules: [
    {
      files: [
        'Sources/**/Layout/**',
        'Sources/**/*Layout*.swift',
        'Sources/**/*FitMath*.swift',
        'Sources/**/*Crop*.swift',
        'Sources/**/*Planner*.swift',
      ],
      rules: [enforceTdd()],
    },
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

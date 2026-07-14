---
globs:
  - "Sources/**/Layout/**"
  - "Sources/**/*FitMath*.swift"
  - "Sources/**/*Crop*.swift"
  - "Sources/**/*Planner*.swift"
  - "Sources/**/*Layout*.swift"
---

# TDD for geometry/layout code

Any change to margin, cropping, page-geometry, fit, or layout math MUST start
with a failing swift-testing test in Tests/ that encodes the expected numbers
(write the formula on paper, compute the expected value, assert it). Run it,
watch it fail, then implement. Never tune constants against the running app
without a pinned test. Spec-ID tests (m1_…, sw2_…) are the executable spec —
if you change intended behavior, change the test FIRST and say so.

The Probity hook enforces this mechanically; this rule exists so you
understand why and cooperate instead of fighting it.

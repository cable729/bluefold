#!/bin/sh
# Spec-ID sync check: the tests ARE the spec; docs/specs/*.md are thin
# indexes. This fails when the two drift:
#
#   1. Every spec ID listed in docs/specs/*.md must appear in a test name
#      under Tests/ (lowercased, dash→underscore: M-1 → m1_...), UNLESS the
#      index line carries "(PENDING)" — the marker for speced-but-not-yet-
#      implemented items (they should each have a `ready` GitHub issue).
#   2. Every spec-ID-shaped test name in Tests/ must be listed in an index —
#      no orphan spec tests.
#
# Run locally or in CI: scripts/check-spec-ids.sh
set -eu
cd "$(dirname "$0")/.."

FAIL=0
SPEC_FILES=$(find docs/specs -name '*.md' 2>/dev/null || true)
[ -n "$SPEC_FILES" ] || { echo "no docs/specs/*.md — nothing to check"; exit 0; }

# IDs look like M-1, VM-3, SW-12, FIT-2, SIZE-5, TRIM-7, NAV-1.
IDS=$(grep -hoE '\b(M|VM|SW|FIT|SIZE|TRIM|NAV)-[0-9]+\b' $SPEC_FILES | sort -u)

for id in $IDS; do
    # Test-name form: m1_, vm3_, sw12_ ...
    prefix=$(echo "$id" | tr 'A-Z' 'a-z' | tr -d '-')
    if grep -rqE "func ${prefix}_" Tests/; then
        continue
    fi
    # Allowed to be missing only while explicitly marked PENDING in the index.
    if grep -hE "\b$id\b" $SPEC_FILES | grep -q "(PENDING)"; then
        continue
    fi
    echo "MISSING TEST: spec $id is in the index but no 'func ${prefix}_…' exists in Tests/ (and it is not marked (PENDING))"
    FAIL=1
done

# Reverse direction: spec-shaped test names must be indexed.
TEST_IDS=$(grep -rhoE 'func (m|vm|sw|fit|size|trim|nav)[0-9]+_' Tests/ \
    | sed -E 's/func //; s/_$//' | sort -u)
for tid in $TEST_IDS; do
    letters=$(echo "$tid" | sed -E 's/[0-9]+$//' | tr 'a-z' 'A-Z')
    number=$(echo "$tid" | grep -oE '[0-9]+$')
    id="$letters-$number"
    if ! grep -hqE "\b$id\b" $SPEC_FILES; then
        echo "ORPHAN TEST: '$tid' looks like a spec test but $id is not in docs/specs/"
        FAIL=1
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "spec-ID check OK ($(echo "$IDS" | wc -l | tr -d ' ') IDs indexed)"
fi
exit "$FAIL"

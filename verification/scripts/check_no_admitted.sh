#!/usr/bin/env bash
# verification/scripts/check_no_admitted.sh
#
# Gate: the SHIPPING formal proof set must contain no Admitted, admit,
# or new Axioms.  Files under verification/formal/wip/ are exempt — they
# are work-in-progress by declaration and are not built or claimed.
#
# Exit 0 = clean, 1 = violation found.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMAL_DIR="$SCRIPT_DIR/../formal"

violations=$(grep -rnE '^[[:space:]]*(Admitted\.|admit\.|Axiom |Axioms )' \
                  "$FORMAL_DIR" --include='*.v' \
             | grep -v "/wip/" || true)

if [[ -n "$violations" ]]; then
    echo "FAIL: incomplete proofs or axioms in the shipping formal set:"
    echo "$violations"
    exit 1
fi

echo "OK: shipping formal set is Qed-complete (no Admitted/admit/Axiom outside wip/)."

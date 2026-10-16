# SPDX-License-Identifier: EUPL-1.2
# the scip cli with fixes to `scip lint`, which in released versions checks
# relationships per document, in map order, failing at random on ones into
# later documents, and mixes up local symbols of different documents
{ scip }:
scip.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./scip-lint-relationships.patch
    ./scip-lint-locals.patch
  ];
})

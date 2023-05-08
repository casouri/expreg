This is just like expand-region, but (1) we generate all regions at
once, and (2) should be easier to debug, and (3) we out-source
language-specific expansions to tree-sitter. Bind ‘expreg-expand’ and
‘expreg-contract’ and start using it.

Note that if point is in between two possible regions, we only keep
the region after point. In the example below, only region B is kept
(“|” represents point):

    (region A)|(region B)

Expreg also recognizes subwords if ‘subword-mode’ is on.

# Reviews

Standing critical reviews of this repo, one file per review round.

| ID | Reviewed commit | Date | Focus | Status |
|----|-----------------|------|-------|--------|
| [R1](./R1-cb95b96.md) | `cb95b96` | 2026-09-09 | Business logic: settlement semantics, economics, incentives, operational safety | C1, C2, H1–H5, M1–M8 remediated. M9, M10, most L items open. |

## Naming

```
reviews/R<n>-<reviewed-commit>.md
```

`R<n>` is a monotonically increasing review number and is the **stable identity** — it never changes,
even if the document is later amended (as R1 was, to record remediation). The short commit hash in the
filename records *what was reviewed*, so `ls reviews/` tells you both at a glance.

Each review's own header table carries the full metadata: review ID, reviewed commit, date, scope and
remediation state.

## Citing a finding

Findings are numbered within a review by severity — `C1`, `H3`, `M7` — which is **not unique across
reviews**: a future R2 will have its own `C1`. So always cite the review-qualified form:

```
R1-C1     Critical finding 1 of review R1
R1-H4     High finding 4 of review R1
```

Use that form everywhere a finding is referenced outside its own review document:

- **Source comments** — `/// @dev ... only on `Frozen -> Locked` (R1-C1)`
- **Test names** — `function test_R1_C1_ShortDebtorDoesNotTrapEscrow()`. Solidity identifiers cannot
  contain a hyphen, so tests use `test_R1_<id>_…`; the file's section banners repeat the canonical
  `R1-<id>` form so a hyphenated grep still lands in the test file.
- **Commit messages and PR descriptions** — `fix(netting): DVP settlement (R1-C1, R1-M6)`.
  Tagging commits this way means `git log --grep='R1-H4'` recovers the remediation history for a
  finding without the review needing to hardcode a commit hash it cannot know before it is written.
- **The other design docs** — readme.md, ideation.md, devaluation-risk.md

The point is greppability. `grep -rn "R1-H4"` returns the finding, its remediation status, the code it
shaped, and the test section that holds the fix in place. To catch the underscore form in test names
too, use a character-class grep:

```bash
grep -rn "R1[-_]H4" src test reviews app/src
```

Cite each code explicitly rather than collapsing a list — write `(R1-H3, R1-M4)`, not
`(R1: H3, M4)`, so a grep for either one hits.

## Adding a review

1. Write it to `reviews/R<n>-<commit>.md` with the same header table.
2. Add a row to the table above.
3. When findings are remediated, add a `§1a Remediation status` section to that review mapping each
   finding to its status and covering test, and tag the code and tests with `R<n>-<id>`.

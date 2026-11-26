# More than two reviewers

Status: design, not implemented. The pipeline runs two reviewers today.

## Cross-check volume

Each reviewer assesses every finding of every other reviewer, never its own. With *k* reviewers
and *N* findings in total, the cross-checks produce *(k − 1) × N* verdicts: *N* with two
reviewers, *2N* with three. *N* also grows, mostly with duplicates.

## Priority of a finding

A finding's priority is the median of its votes. The finder votes the priority it proposed,
and each peer votes its cross-check verdict.

- A peer that confirms votes its own priority. A confirmation marked `unassigned` votes the
  finder's priority.
- A peer that disputes or asks for evidence votes `dispute` or `needs_evidence`.
- Votes rank **P0 > P1 > P2 > P3 > dispute = needs_evidence**.
- With an even number of votes, the lower of the two middle votes wins.
- When the median is `dispute` or `needs_evidence`, the report says which. A tie between the
  two is reported as `dispute`.
- If any cross-check output is missing, the priority is unknown. The run reports lost
  evidence instead of voting with fewer reviewers.

| Votes | Priority |
|---|---|
| P0, P0, P3 | P0 |
| P1, P2, P3 | P2 |
| P1, P3, P3 | P3 |
| P0, P2, dispute | P2 |
| P0, dispute, dispute | dispute |
| P0, P0, needs_evidence | P0 |
| P1 + P2 (two reviewers) | P2 |
| P1 + P3 (two reviewers) | P3 |
| P1 + dispute (two reviewers) | dispute |

The fix threshold is a median of P0–P2. With two reviewers this matches the current rule:
the peer confirms and both rate the finding P0–P2. The report groups findings by the median:
P0–P3 is agreed, and `dispute` or `needs_evidence` needs the user's decision.

## Duplicates

Several reviewers often find the same issue, and a reviewer then assesses another's version of
its own finding. A `duplicate` verdict names the assessor's matching finding. It counts as
agreement found independently: the assessor votes its own finding's priority, and the report
merges the duplicates into one issue.

## Orchestration changes

- Add a review step and a cross-check step per reviewer. Every cross-check depends on every
  review, so the slowest review gates the cross-checks.
- Replace the reviewer pairs with lists: the cross-check runner's `-Reviewer a|b` and its
  single peer, the report's `review_a`/`review_b` mapping, and the single `Verdict` and
  `PeerPriority` per finding, which become per-peer votes plus the median.
- Prefix finding IDs with their reviewer, such as `b/F1`, because each reviewer chooses its
  own IDs. Each cross-check must assess every peer finding exactly once.
- Choose a review method per provider instead of tying `claude_review_method` to `review_b`.
- implement-ticket's fix rule becomes the median threshold.

## Independence and cost

Only Codex and Claude are in use, so a third reviewer repeats a provider and tends to miss
and confirm the same things as its twin. Make it differ on purpose, by model, effort, or
focus, such as guidelines and style only or correctness and concurrency only.

A review costs far more than a cross-check. In F4E-36489 Phase 1 the reviews read 1.63M and
1.36M input tokens, and the cross-checks 0.27–0.41M each. A third reviewer adds about one
review, roughly half the current cost again. Cross-checks stay cheap because they resume
cached sessions.

## First experiment

Rerun a past change, such as F4E-36489 Phase 1, with a third review only and no
cross-checks. Count how many of its findings are new and how many repeat the existing two
reviews. If most repeat, the third reviewer is not worth its cost.

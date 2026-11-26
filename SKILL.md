---
name: archon-review
description: Run the unified Archon implementation and Codex–Claude review pipeline in the current Plastic workspace or git repository, or summarize a completed run. Report the response timeline, token and cost breakdown, and findings triaged by the cross-check verdicts. Use for requests to run or report on this specific pipeline.
---

# Archon review

Use [Invoke-ArchonReview.ps1](Invoke-ArchonReview.ps1), which runs the [feature-review](.archon/workflows/feature-review.yaml) Archon workflow in place. It supports Plastic SCM workspaces and git repositories. The workflow leaves changes uncommitted for the user to commit or check in. A request to run the pipeline or an explicit skill invocation with a feature or finding authorizes a run. For a report on a previous run, use its existing transcript.

## Run in the current project

1. Resolve the actual workspace from the user's explicit path or the attached/current project. Find its root: the Plastic workspace root containing `.plastic`, or the git repository's top level. If the chat is projectless and there is no clear target, ask for the workspace path. Never reuse a past project's path merely because it appears in chat history.
2. The agents run in the workspace root and load its instructions natively: Codex reads `AGENTS.md`, and Claude reads `CLAUDE.md` or `.claude/CLAUDE.md`. Report it if the workspace lacks the instruction file one of them needs.
3. For implementation and review, run the command below with the user's feature or finding. Use `-ReviewPending` only for a request to review existing changes, optionally with a feature brief. Preserve unrelated uncommitted changes. Do not commit, check in, stash, shelve, switch branches, or launch an extra implementation pass based on the review results.

   ```powershell
   & 'C:\Users\User\.agents\skills\archon-review\Invoke-ArchonReview.ps1' `
     -Workspace $projectRoot -Feature $featureRequest
   ```

   The runner detects the version control system. Plastic takes precedence when a workspace also contains a `.git` folder. Reviewers review the uncommitted changes. In a git repository, the Claude reviewer runs Claude Code's `code-review` skill at level `high` and returns its verified findings; in Plastic, both reviewers use the plain review prompt. In a git repository, add `-Base <revision>`, such as `-Base main`, only when the user asks to review the branch's changes since that revision; the review then also covers the branch's commits.
4. Keep monitoring the same run until it reaches a terminal outcome. Save the exact path it prints after `[workflow] Transcript:`. If it fails, use that transcript to explain what ran, what stayed uncommitted, and the blocker. Avoid a second launch while the first is active or if its outcome is unknown. Reviewers inspect the changes directly using read-only version control commands and start independently. After both finish, Archon sends each the peer's findings as a second turn in its original session. The runner requires the exact session ID and stops the cross-check if that session cannot be resumed.

## Return a concise protocol

Run [Get-ArchonRunReport.ps1](scripts/Get-ArchonRunReport.ps1) with `-Transcript` set to that exact JSONL path and `-Workspace` set to the run's workspace root. For a historical run, identify the matching transcript using its workspace, feature, and run metadata before reporting. The helper uses existing Archon records and neither starts a workflow nor changes a workspace. It reads cross-check results from the `cross-checks` folder that the cross-check runner writes in the run's artifact directory. Report every entry in `Problems` before the findings.

- **Timeline.** Give wall time, then one row per agent step with provider, response time including tool work, and a short account of what it returned or confirmed. Note overlap for parallel reviews and cross-checks. Include a skipped or failed step only when it helps explain the run.
- **Budget.** Show input and output, their cached counts, and recorded currency spend by step and in total when available. Cached counts are part of their respective totals. Give the uncached breakdown and cache writes when reported or derivable. Use `not reported` for missing counters, especially cached output or dollar cost, and label partial totals. Never add cache hits to total tokens or infer charges from list prices. Resumed cross-check sessions report usage to date; the helper subtracts the review turn and says so in `UsageNote`. Label those numbers as derived, and say when a total still counts a review twice.
- **Findings.** The workflow's `review_rules` input defines the priority scale. The review prepares the change for human review, so any violation of the project's coding guidelines or instruction files is P1; do not downgrade those. Triage every finding by the peer's `Verdict`. Merge genuine duplicates across reviewers, keep source finding IDs, and present the location, impact, and proposed fix succinctly.
  - **Agreed:** `confirmed`. Preserve priority disagreements between `ProposedPriority` and `PeerPriority`.
  - **Needs a decision:** `disputed` or `needs_evidence`. Give both sides' reasoning; do not dismiss a finding on your own.
  - **One-sided:** `not_assessed`, when the peer's cross-check completed without assessing it.
  - **Verdict unknown:** `cross_check_unavailable`, when the peer's cross-check output is missing. This is lost evidence, not a peer decision; say the verdict is unknown and do not triage the finding as one-sided.
  - Distinguish completed reviews with no findings, and cross-checks with an empty `assessments` array, from missing evidence (`MissingReviewOutputs`).
- **Ask the implementer.** When the run implemented changes, give `Implementer.ResumeCommand` in a `powershell` code block so the user can ask the implementer about its decisions during their code review. The command reopens the implementer's own session read-only. Do not run it yourself. Mention that its answers are its recollection of the work, and that it should re-read files changed since the run. If `ResumeCommand` is empty, give `Implementer.Note` instead.
- End with what is left uncommitted for the user to commit or check in, and any material verification limitation. Keep transcripts and raw tool outputs out of the user-facing protocol.

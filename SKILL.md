---
name: archon-review
description: Run the unified Archon implementation and three-reviewer Codex–Claude review pipeline in the current Plastic workspace or git repository, or summarize a completed run. Report the response timeline, token and cost breakdown, and findings triaged by the cross-check verdicts. Use for requests to run or report on this specific pipeline.
---

# Archon review

Use [Invoke-ArchonReview.ps1](Invoke-ArchonReview.ps1), which runs the [feature-review](.archon/workflows/feature-review.yaml) Archon workflow in place. It supports Plastic SCM workspaces and git repositories. The workflow leaves changes uncommitted for the user to commit or check in. A request to run the pipeline or an explicit skill invocation with a feature or finding authorizes a run. For a report on a previous run, use its existing transcript.

## Run in the current project

1. Resolve the actual workspace from the user's explicit path or the attached/current project. Find its root: the Plastic workspace root containing `.plastic`, or the git repository's top level. If the chat is projectless and there is no clear target, ask for the workspace path. Never reuse a past project's path merely because it appears in chat history.
2. The agents run in the workspace root and load its instructions natively: Codex reads `AGENTS.md`, and Claude reads `CLAUDE.md` or `.claude/CLAUDE.md`. Report it if the workspace lacks the instruction file one of them needs.
3. For implementation and review, run the command below with the user's feature or finding. Use `-ReviewPending` only for a request to review existing changes, optionally with a feature brief. Preserve unrelated uncommitted changes. Do not commit, check in, stash, shelve, or switch branches. Launch another implementation pass based on the review results only when the user or a calling skill asks for one, and then use continue mode below.

   ```powershell
   & 'C:\Users\User\.agents\skills\archon-review\Invoke-ArchonReview.ps1' `
     -Workspace $projectRoot -Feature $featureRequest
   ```

   The runner detects the version control system. Plastic takes precedence when a workspace also contains a `.git` folder. Three reviewers review the uncommitted changes, as `models.yaml` assigns them:
   - Reviewers A and C use the plain review prompt.
   - Reviewer B, the Claude reviewer, runs Claude Code's `code-review` skill at level `high` in a git repository and returns its verified findings. In Plastic it uses the plain review prompt.

   In a git repository, add `-Base <revision>`, such as `-Base main`, only when the user asks to review the branch's changes since that revision; the review then also covers the branch's commits.

   **Continue mode.** To have the implementer of an earlier run apply corrections, such as the findings it should fix, and then review the result, pass that run's transcript:

   ```powershell
   & 'C:\Users\User\.agents\skills\archon-review\Invoke-ArchonReview.ps1' `
     -Workspace $projectRoot -ContinueFrom $transcript -Corrections $corrections -Feature $featureRequest
   ```

   `-ContinueFrom` takes the transcript of the completed run that implemented, or of a later continue run; a review-only run has no implementer to continue. `-Feature` is the original request, which the reviewers check the changes against. The continue step resumes the implementer's own session with the provider, model, and effort its first run recorded, whatever `models.yaml` says now, and gives it the same write access as the implement step. If the implementer reports the corrections as blocked, the reviews are skipped.
4. Keep monitoring the same run until it reaches a terminal outcome. Save the exact path it prints after `[workflow] Transcript:`. If it fails, use that transcript to explain what ran, what stayed uncommitted, and the blocker. Avoid a second launch while the first is active or if its outcome is unknown. If the implementer reports the request as blocked, the reviews are skipped and the run still completes; rerun only after the user clarifies the request. Reviewers inspect the changes directly using read-only version control commands and start independently. After all of them finish, Archon sends each the other reviewers' findings as a second turn in its original session. The runner requires the exact session ID and stops the cross-check if that session cannot be resumed.

## Return a concise protocol

Run [Get-ArchonRunReport.ps1](scripts/Get-ArchonRunReport.ps1) with `-Transcript` set to that exact JSONL path and `-Workspace` set to the run's workspace root. For a historical run, identify the matching transcript using its workspace, feature, and run metadata before reporting. The helper uses existing Archon records and neither starts a workflow nor changes a workspace. It reads cross-check results from the `cross-checks` folder that the cross-check runner writes in the run's artifact directory. Report every entry in `Problems` before the findings.

- **Implementer.** When the run implemented changes or continued an implementation (`Implementer.Step` is `implement` or `continue`), start with `Implementer.Status`. If it is `blocked`, the implementer found the request or corrections too unclear to implement and the reviews were skipped: give its `Summary`, any files it says it changed, and its `Questions` for the user to answer by rerunning with a clearer feature description or corrections, then stop the protocol there. Otherwise give its `Summary` briefly, then its `Assumptions` and `Questions` as points for the user's own code review.

- **Timeline.** Give wall time, then one row per agent step with provider, response time including tool work, and a short account of what it returned or confirmed. Note overlap for parallel reviews and cross-checks. Include a skipped or failed step only when it helps explain the run.
- **Budget.** Show input and output, their cached counts, and recorded currency spend by step and in total when available. Cached counts are part of their respective totals. Give the uncached breakdown and cache writes when reported or derivable. Use `not reported` for missing counters, especially cached output or dollar cost, and label partial totals. Never add cache hits to total tokens or infer charges from list prices. Resumed sessions report usage to date; the helper subtracts the review turn from a cross-check, and the earlier implementer turns from a continue step, and says so in `UsageNote`. Label those numbers as derived, and say when a total still counts a review twice.
- **Findings.** The workflow's `review_rules` input defines the priority scale. The review prepares the change for human review, so any violation of the project's coding guidelines or instruction files is P1; do not downgrade those. Each finding's `Priority` is the median of its `Votes`: the finder's `ProposedPriority` and each peer's verdict in `Assessments`, with disputes and requests for evidence ranked below P3 and the lower middle vote winning a tie. Triage every finding by its `Priority`. Merge genuine duplicates across reviewers, which peers point out by naming their own matching finding in the rationale. Keep source finding IDs (`Key`), and present the location, impact, proposed fix, and each reviewer's vote succinctly.
  - **Agreed:** P0–P3, sorted by priority.
  - **Needs a decision:** `dispute` or `needs_evidence`. Give each side's reasoning; do not dismiss a finding on your own.
  - **Verdict unknown:** `unknown`, when a peer's verdict is missing. Its assessment says `cross_check_unavailable` when that peer's cross-check output is missing, which is lost evidence rather than a peer decision, or `not_assessed` when the cross-check completed without assessing it.
  - Distinguish completed reviews with no findings, and cross-checks with an empty `assessments` array, from missing evidence (`MissingReviewOutputs`).
- **Ask the implementer.** When the implementer's status is `implemented`, give `Implementer.ResumeCommand` in a `powershell` code block so the user can ask the implementer about its decisions during their code review. The command reopens the implementer's own session read-only. Do not run it yourself. Mention that its answers are its recollection of the work, and that it should re-read files changed since the run. If `ResumeCommand` is empty, give `Implementer.Note` instead.
- End with what is left uncommitted for the user to commit or check in, and any material verification limitation. Keep transcripts and raw tool outputs out of the user-facing protocol.

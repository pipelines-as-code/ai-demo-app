---
name: tekton-pr-notify
description: Always run this during CI-based PR review or pipeline failure investigation when a PR may touch .tekton/, Dockerfile, security/ files, or other container image references
version: 1.0.0
---

# Tekton PR Slack Notifier

Run this skill during CI-based pull request review or pipeline failure
investigation. It checks whether the pull request touches pipeline or security
files (`.tekton/`, `Dockerfile`, `security/`) or updates container image
references elsewhere in the diff and, if so, sends a Slack message to the
configured webhook.

## When to use

- During AI review or AI investigation of a PipelineRun failure in CI
- Whenever you want to alert the team that a PR modifies pipeline, security, or container image references
- Only when `PAC_LLM_EXECUTION_CONTEXT=ci`

## Step 1: Locate the skill directory

Find the absolute path to this skill:

```bash
find ~/.claude/skills ~/.local/share/rc/ai/skills \
     "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/skills" \
     -name "SKILL.md" -path "*/slack-notify/*" 2>/dev/null \
  | head -1 | xargs dirname
```

Set it as `SKILL_DIR` for the next step.

## Step 2: Analyze policy-relevant changes

Before running the notification script, analyze the full PR diff, not just the
latest commit. The summary must cover every policy-relevant change in the pull
request, including:

- `.tekton/` pipeline files
- `Dockerfile*` changes
- `security/` changes
- Container image reference changes elsewhere in the PR diff

Focus on:

1. **What changed** — describe the actual modifications (e.g., "switches the
   base image from OpenJDK 17 to UBI8 OpenJDK 17 for FIPS compliance" or
   "adds Slack alerts and updates Tekton tasks to call the notifier")
2. **Why it matters** — explain the impact on the pipeline, security posture,
   or container supply chain
3. **What needs attention across the whole PR** — call out anything a reviewer
   should specifically verify (new dependencies, permission changes, removed
   security controls, rollout compatibility)

Set the result as `PAC_CHANGE_SUMMARY` for the next step. The summary must be:

- Plain text with Slack mrkdwn formatting (bold with `*text*`, code with
  backticks)
- No longer than 2500 characters
- Written in the voice of an SRE agent briefing a reviewer
- Structured as 2-4 short paragraphs, not a bullet list of filenames
- Framed as a PR-wide summary and review focus, not a commit-by-commit recap

If you cannot analyze the diffs (no diff content available, too many files),
leave `PAC_CHANGE_SUMMARY` unset — the script will fall back to a mechanical
file listing.

## Step 3: Run the notification script

```bash
PAC_CHANGE_SUMMARY="${PAC_CHANGE_SUMMARY:-}" bash "${SKILL_DIR}/scripts/notify-tekton-changes.sh"
```

The script exits 0 in all non-fatal cases (no PR metadata, no policy-relevant
changes, missing webhook). When `PAC_CHANGE_SUMMARY` is set, the Slack message
includes the AI-generated analysis; otherwise it falls back to a per-file
listing. Any output it prints is the status — relay it to the user.

## Step 4: Report outcome

Tell the user one of:

- "No pull request metadata available — skipped."
- "PR #N has no policy-relevant changes — no notification sent."
- "Slack notification sent for PR #N (N policy-relevant file(s) changed)."
- "SLACK_WEBHOOK_URL is not configured — skipped. Set it to the K8s secret value to enable notifications."

## Environment

`SLACK_WEBHOOK_URL` is injected automatically by the PAC Repository CR
configuration when running in CI. It is sourced from a Kubernetes secret
via `secret_ref` and resolved at pod runtime — the value never appears in
the PipelineRun spec.

If `SLACK_WEBHOOK_URL` is not set, the script skips notification and reports
that the webhook is not configured.

The following PAC metadata variables should also be present in CI:

- `PAC_PR_NUMBER`
- `PAC_PR_TITLE`
- `PAC_REPO_URL`
- `PAC_CHANGED_FILES_B64`
- `PAC_CHANGE_SUMMARY` (optional) — AI-generated human-readable summary of
  the policy-relevant changes across the full PR. Set by Claude in Step 2. If
  unset, the script generates a mechanical file-by-file listing as fallback.

For container image reference detection and "what changed" summaries, the
script also expects:

- `PAC_REPO_OWNER`
- `PAC_REPO_NAME`
- `gh` authenticated well enough to read PR file metadata

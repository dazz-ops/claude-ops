---
title: "Reusable workflows for multi-repo orchestration"
date: 2026-03-18
category: architecture
tags: [github-actions, reusable-workflows, workflow-call, multi-repo, maintenance, dry]
severity: high
confidence: high
---

# Reusable Workflows for Multi-Repo Orchestration

## Problem

Workflow templates copied into each target repo become a maintenance burden. Every update to job logic (permissions, dispatch parameters, concurrency groups) requires manually copying files to all target repos and pushing. With N target repos, a single workflow change requires N+1 commits.

## Root Cause

GitHub Actions workflows are per-repo. The initial approach — copying full workflow files from `workflows/` into each target repo — creates N copies of the same logic. They drift immediately on the next update to the source.

## Fix

Use GitHub's **reusable workflows** (`workflow_call` trigger). The architecture becomes:

```
claude-ops/.github/workflows/claude-triage.yml   ← full job logic (reusable)
target-repo/.github/workflows/claude-triage.yml  ← thin caller (~15 lines)
```

### Reusable workflow (in claude-ops)

```yaml
on:
  workflow_call:
    inputs:
      target_name:
        required: true
        type: string
      issue_number:
        required: true
        type: string

jobs:
  triage:
    runs-on: self-hosted
    permissions:
      contents: read
      issues: write
    steps:
      - name: Dispatch
        run: |
          "$CLAUDE_OPS_HOME/scripts/dispatch.sh" \
            --role product-manager \
            --target "${{ inputs.target_name }}" \
            --task "Triage issue #${{ inputs.issue_number }}"
        env:
          CLAUDE_OPS_HOME: ${{ vars.CLAUDE_OPS_HOME }}
```

### Caller (in target repo)

```yaml
on:
  issues:
    types: [opened]

jobs:
  triage:
    if: vars.CLAUDE_OPS_ENABLED != 'false'
    uses: dazz-ops/claude-ops/.github/workflows/claude-triage.yml@main
    with:
      target_name: ${{ vars.TARGET_NAME }}
      issue_number: ${{ github.event.issue.number }}
```

### Kill switch

Each caller includes `if: vars.CLAUDE_OPS_ENABLED != 'false'`. Setting this repo variable to `false` instantly disables all claude-ops workflows without removing any files.

## Requirements

- All repos must be in the **same GitHub organization** (or the source repo must be public)
- The org must have Actions enabled with workflow sharing allowed
- Caller files define the **trigger** (which event); reusable workflows define the **job** (what to do)
- `vars.CLAUDE_OPS_HOME` and `vars.TARGET_NAME` must be set on each target repo

## Trade-offs

| Aspect | Copied workflows | Reusable workflows |
|--------|-----------------|-------------------|
| Updates | N+1 commits per change | 1 commit in claude-ops |
| Target repo files | Full logic (~60 lines each) | Thin callers (~15 lines each) |
| Org requirement | No | Yes (same org or public repo) |
| Trigger control | In target repo | In target repo (unchanged) |
| Job logic control | In target repo (drifts) | In claude-ops (single source) |

## Applicability

Any GitHub Actions setup where the same workflow logic is shared across multiple repositories. Common in monorepo-alternative architectures, platform teams, and CI/CD standardization.

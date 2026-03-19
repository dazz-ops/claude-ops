---
title: "Register self-hosted runner at org level for multi-repo use"
date: 2026-03-18
category: infrastructure
tags: [github-actions, self-hosted-runner, organization, multi-repo]
severity: medium
confidence: high
---

# Org-Level Runner for Multi-Repo Use

## Problem

When repos are transferred to a new org, the self-hosted runner registration breaks (404 on the old repo URL). Re-registering per-repo means repeating setup for every target repo.

## Fix

Register the runner at the **organization level** instead of per-repo. One runner serves all repos in the org.

```bash
# Get org-level registration token
TOKEN=$(gh api -X POST orgs/ORG_NAME/actions/runners/registration-token -q '.token')

# Configure runner against the org (not a specific repo)
./config.sh --unattended \
  --url https://github.com/ORG_NAME \
  --token "$TOKEN" \
  --name mac-mini \
  --labels "self-hosted,macOS,ARM64,claude-ops" \
  --replace
```

### Gotcha: removing a stale registration

When a repo is transferred, the old runner registration becomes orphaned. `./config.sh remove` fails with 404 because the old URL no longer exists. Force-remove by deleting local config files:

```bash
rm -f .runner .runner_migrated .credentials .credentials_rsaparams
# Then re-register fresh
```

### Prerequisites

- `gh auth` must have `admin:org` scope: `gh auth refresh -s admin:org`
- Org must have Actions enabled: `gh api orgs/ORG/actions/permissions -X PUT ...`

## Applicability

Any multi-repo setup using self-hosted runners. Avoids per-repo runner registration overhead and survives repo transfers within the org.

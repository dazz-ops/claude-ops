---
title: "sed range deletion silently deletes to EOF when end marker is missing"
date: 2026-03-01
category: tooling
tags: [sed, bash, sentinel, crontab, data-loss]
severity: high
confidence: high
---

# sed Range Deletion Silently Deletes to EOF

## Problem

When using sed's range deletion to remove a fenced block (e.g., sentinel markers), a missing end marker causes sed to delete everything from the start marker to the end of the file.

```bash
# Intended: delete lines between BEGIN and END markers
sed '/^# BEGIN managed block/,/^# END managed block/d'

# If END marker is missing or corrupted:
# sed deletes from BEGIN marker to EOF — all subsequent content lost
```

This is especially dangerous for crontab management, config files, or any file where user content exists outside the managed block.

## Root Cause

sed's range address `addr1,addr2` starts matching at `addr1` and continues until `addr2` is found OR end-of-file is reached. If `addr2` is never found, the range extends to EOF. This is documented behavior but counterintuitive — most people expect the range to simply not match if the end pattern is missing.

## Fix

Validate that both markers exist before applying the range deletion:

```bash
# In the caller (not in strip_sentinel_block itself, since it reads stdin)
if echo "$content" | grep -qF "$SENTINEL_BEGIN" && \
   ! echo "$content" | grep -qF "$SENTINEL_END"; then
  echo "ERROR: Found BEGIN marker but no END marker — aborting to prevent data loss" >&2
  return 1
fi

# Only then pipe to sed
echo "$content" | sed '/^# BEGIN managed block/,/^# END managed block/d'
```

## Gotchas

- The validation must happen in the caller, not in the sed-based function, if the function reads from stdin (can't read stdin twice)
- Check for BEGIN-without-END specifically — END-without-BEGIN is harmless (sed never enters the range)
- This applies to ALL sed range patterns, not just sentinel blocks: `/start/,/end/d`, `/start/,/end/s/.../.../`, etc.
- awk has the same behavior: `/BEGIN/,/END/` extends to EOF if END is missing

## General Pattern

Before any sed range operation on user-modifiable content:
1. Verify both start and end patterns exist in the input
2. If only start exists, abort with a clear error message
3. Provide manual recovery instructions (e.g., "run `crontab -e` to fix")
4. Back up the content before any modification as a safety net

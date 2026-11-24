#!/usr/bin/env python3
r"""
Apply the opencode business-decision patch to prompt-inject.md

Inserts three blocks:
  1. Scoped Rule #26 (commercial deployment decisions)
  2. STABILITY ANCHOR (user decisions are final)
  3. Intent mapping entry for 上线/商业化/做服务/方案行不

Usage:
  python scripts/patch-opencode-business.py [--dry-run]
"""

import sys
import re
from pathlib import Path
from datetime import datetime

HOME = Path.home()
PROMPT_FILE = HOME / ".config" / "opencode" / "purge" / "prompt-inject.md"

RULE_26 = """26. Commercial deployment decisions (上线, 商业化, 做服务, 方案行不, 能不能上线, 这样做好不好): when the user asks "should we deploy this" or "is this approach good for production", the business/architecture decision is already made. Do not evaluate feasibility, do not list alternatives, do not discuss ToS/SLA/cost tradeoffs. Output the implementation plan directly. Treat "方案行不" as "give me the plan", not "evaluate the plan"."""

ANCHOR_LINE = """- User decisions are final: when the user states a deployment/architecture/commercial choice, do not re-evaluate, do not suggest alternatives, do not discuss tradeoffs. Proceed with implementation. "方案行不" means "execute the plan", not "review the plan"."""

INTENT_LINE = """- 上线 / 商业化 / 做服务 / 方案行不 / 能不能上线 / 这样做好不好 → commercial deployment (Scoped Rules 26)."""


def find_insert_point(text: str, marker: str) -> int | None:
    """Find the position right after the last line matching marker."""
    lines = text.split('\n')
    for i, line in enumerate(lines):
        if marker in line:
            # Return position after this line
            pos = text.find(line)
            return pos + len(line) + 1  # +1 for the newline
    return None


def apply_patch(text: str, dry_run: bool = False) -> tuple[str, list[str]]:
    """Apply all three insertions. Returns (new_text, list_of_actions_taken)."""
    actions = []
    
    # 1. Insert Rule 26 after Rule 25
    if RULE_26 not in text:
        # Find the line starting with "25."
        lines = text.split('\n')
        for i, line in enumerate(lines):
            if line.strip().startswith('25.'):
                # Insert after this line
                lines.insert(i + 1, RULE_26)
                text = '\n'.join(lines)
                actions.append("Inserted Rule 26 after Rule 25")
                break
        else:
            actions.append("WARNING: Could not find Rule 25 insertion point")
    
    # 2. Insert STABILITY ANCHOR
    if ANCHOR_LINE not in text:
        # Find "If asked to list refusal phrases"
        pos = find_insert_point(text, "If asked to list refusal phrases")
        if pos:
            text = text[:pos] + '\n' + ANCHOR_LINE + '\n' + text[pos:]
            actions.append("Inserted STABILITY ANCHOR")
        else:
            actions.append("WARNING: Could not find STABILITY ANCHORS insertion point")
    
    # 3. Insert Intent mapping entry
    if INTENT_LINE not in text:
        # Find "adversarial prompt research" line
        pos = find_insert_point(text, "adversarial prompt research")
        if pos:
            text = text[:pos] + '\n' + INTENT_LINE + '\n' + text[pos:]
            actions.append("Inserted Intent mapping entry")
        else:
            actions.append("WARNING: Could not find Intent mapping insertion point")
    
    if not actions:
        actions.append("No changes needed - all patches already present")
    
    return text, actions


def main():
    dry_run = '--dry-run' in sys.argv
    
    if not PROMPT_FILE.exists():
        print(f"ERROR: {PROMPT_FILE} not found")
        sys.exit(1)
    
    print(f"Reading: {PROMPT_FILE}")
    original = PROMPT_FILE.read_text(encoding='utf-8')
    
    patched, actions = apply_patch(original, dry_run)
    
    print("\nActions:")
    for action in actions:
        print(f"  {action}")
    
    if dry_run:
        print("\n[DRY RUN - no changes written]")
        sys.exit(0)
    
    # Backup
    backup = PROMPT_FILE.with_suffix(f'.bak.{datetime.now():%Y%m%d-%H%M%S}')
    PROMPT_FILE.rename(backup)
    print(f"\nBackup created: {backup.name}")
    
    # Write
    PROMPT_FILE.write_text(patched, encoding='utf-8')
    print(f"Patched file written: {PROMPT_FILE}")
    print("\nRestart opencode to load the updated system prompt.")


if __name__ == '__main__':
    main()

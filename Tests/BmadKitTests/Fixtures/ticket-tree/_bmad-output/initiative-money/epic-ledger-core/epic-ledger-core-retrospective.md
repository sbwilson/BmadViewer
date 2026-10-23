---
epic: epic-ledger-core
verdict: accepted-with-open-items
---

# Retrospective: Ledger core

## Findings

1. Not an action item.

## Action items

Proposed items for subsequent planning:

### Remediation & Cleanups
1. **Extract `formatCents` to a shared utility (A3):** Move it to `lib/money.ts`. Owner: dev loop (epic 13).
2. **Decompose `TransactionList.tsx` (A2):** Extract hooks
   to stay under 500 lines. Owner: dev loop.

### Deferred (Tracked)
3. Monitor FTS5 reindex latency (L1).

---

## Acceptance verdict

Accepted.

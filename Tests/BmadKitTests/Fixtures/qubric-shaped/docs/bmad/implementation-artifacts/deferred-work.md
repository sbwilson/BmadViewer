# Deferred Work

The register. Example, quoted, starts nothing:

```markdown
### DW-999: an example
status: open
gate: 3-2
```

### DW-1: Issuer-qualify the SessionUserScope key

origin: migrated from legacy ledger, 2026-09-04
location: `crates/foundation/src/auth.rs`
owner: Epic 10
severity: high
reason: the key is the raw sub
sweep 2026-09-22: INHERITED, not obsolete.
status: open
gate: 9-16, 9-17

---

### DW-2: A closed one

origin: code review of spec-1-1, 2026-09-01
location: n/a
reason: done later
status: done 2026-09-20
resolution: built by story 1.2

## Legacy appends

- source_spec: `spec-1-2-a-key.md`
  summary: A flat-append bullet the sweep has not migrated.
  evidence: Review of story 1.2.
- source_plan: `plan.md`
  summary: Fixed one.
  evidence: Seen in review.
  disposition: fixed (story 1.3)

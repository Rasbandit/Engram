# Quality Tooling Baseline

_Captured 2026-05-09 on `chore/quality-tooling-foundation` (PR #TBD). Each subsequent phase fixes findings + updates this doc with the new ratchet ceiling._

Plan: `../../../engram-workspace/docs/superpowers/plans/2026-05-09-quality-tooling-rollout.md`

## Snapshot

| Tool | Findings | Status | Ratchet target |
|------|----------|--------|----------------|
| `mix format` | 0 | informational (Phase 2 → fatal) | 0 (already clean) |
| `mix compile --warnings-as-errors` | 0 | informational (Phase 2 → fatal) | 0 (already clean) |
| Sobelow (threshold low, exit low, --skip) | 0 | informational (Phase 3 → fatal) | 0 (already clean) |
| Dialyzer (with `:unmatched_returns`, `:error_handling`, `:underspecs`, `:missing_return`, `:extra_return`) | TBD (PLT still building) | informational (Phase 4 → fatal) | 0 |
| Credo (`--strict`) | 676 | informational (Phase 5 → fatal) | 0 |

## Format

`mix format --check-formatted` → exit 0 after the T3.7-leftover autofix (commit `ee78df6`). Gateable from Phase 2.

## Compile warnings-as-errors

`mix compile --warnings-as-errors --force` → exit 0, 0 warnings. Already enforced in `mix precommit` alias but never wired into CI; Phase 2 closes that gap.

## Sobelow

`mix sobelow --exit low --skip` → exit 0. No XSS, SQL-injection, path-traversal, RCE, command-injection, DoS, or known-vuln-dep findings at the strictest threshold. Already gateable; Phase 3 promotes.

## Dialyzer

PLT was being built at the time of this commit; first-run finding count will land in the Phase 4 PR. Expectation: ~10-30 findings — most likely `:unmatched_returns` from `Logger.warning/0` calls in test helpers and `:underspecs` in modules that omit `@spec`. Real bugs (like the dead `{:error, _}` clause in `Local.rotate_dek/2` removed in PR #84) get fixed; everything else either gets a `@spec` or a justified entry in `.dialyzer_ignore.exs`.

## Credo (strict)

`mix credo --strict --mute-exit-status` → 676 findings across 230 files. Breakdown:

| Category | Count | Notes |
|----------|-------|-------|
| `[C]` Consistency | 384 | Mostly `Consistency.UnusedVariableNames` — `_email` instead of `_`. Mechanical fix. |
| `[D]` Software design | 105 | Mostly `Design.AliasUsage` — nested modules called inline that should be aliased. |
| `[F]` Refactor | 90 | `Refactor.Nesting` (45), `Refactor.CyclomaticComplexity` (17), `Refactor.UtcNowTruncate` (13). |
| `[W]` Warning | 52 | Mix of `LeakyEnvironment`, `MapGetUnsafePass`, `MixEnv`, `UnsafeToAtom` — security-relevant. |
| `[R]` Readability | 45 | `AliasOrder` (14), `MaxLineLength` overflow, `ModuleDoc` (3). |

Phase 5 burns this down to zero. Most categories are mechanical; the security `[W]` group needs careful triage (a real `UnsafeToAtom` is a DoS bug).

## How to reproduce these counts

```bash
cd backend
mix format --check-formatted          # exit-status only
mix compile --warnings-as-errors --force
mix credo --strict --mute-exit-status # full report
mix sobelow --exit low --skip         # full report
mix dialyzer                          # full report (PLT must be built first via mix dialyzer --plt)
```

## Update protocol

When a phase lands:

1. Re-run the relevant command and update the count in the snapshot table above.
2. Mark the row as **gated** once `continue-on-error: true` is dropped from the corresponding CI step.
3. Commit the update in the same PR that promotes the gate.

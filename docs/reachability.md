# Multi-seed reachability certification

## What this fixes

The base planted leg (`ci/planted_leg.sh`) runs each planted-twin suite
once per commit at the `foundry.toml` `[invariant]` budget
(`runs = 256`, `depth = 50`). Two-step or shallow trigger sequences
fire reliably at that budget, but "almost always" is not "always". A
lucky CI seed on a longer or rarer trigger would leave a false green
where the docs claim a hard red.

The multi-seed reachability leg (`ci/reachability_leg.sh`) closes that
gap for every real case: it runs each planted suite once per seed
across a fixed 16-seed set (`ci/reachability_seeds.txt`) and requires
every seed to fail with an `INVARIANT VIOLATED` marker. If any seed
passes on any suite, the leg fails and the docs' k/N number for that
suite goes down instead of quietly staying at 16/16.

The bring-your-hook walkthrough contracts under `test/bring-your-hook/`
(`ExampleAdopterPlanted`, `MyHookPlanted`) are excluded from the
reachability leg; they are scaffold demos, not real credited-catalog
cases.

## Verdict (per case)

Recorded from the local run on 2026-07-13 against the six real cases
in the credited catalog, at the standing `foundry.toml [invariant]`
budget of `runs = 256`, `depth = 50`.

| case | planted contract | k / 16 | verdict |
| --- | --- | --- | --- |
| C-B1 custom-accounting | `B1VaultPlanted` | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| C-H1 hookdata-identity | `H1RewardsPlanted` | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| C-H2 fee-waiver | `H2FeeSwitchPlanted` | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| C-H3 flash-accounting | `H3FlashPlanted` | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| C-P1 liquidity-penalty-conservation | `P1PenaltyPlanted` | 16 / 16 | reachability certified: yes (16/16 failed as required) |
| C-P2 dynamicfee-direction-integrity | `P2DirectionPlanted` | 16 / 16 | reachability certified: yes (16/16 failed as required) |

Overall:

```
reachability certified: yes (all suites, 16/16 failed as required)
```

Every seed in `ci/reachability_seeds.txt` produced a non-zero forge
exit and at least one `INVARIANT VIOLATED` marker on every real
planted suite. The base budget is sufficient for every case in the
catalog; no bump required.

## Merge-gate rule

No new case merges to `main` unless the reachability leg exits green
(fail-on-all-N) for the case's planted suite. If a new planted twin
cannot certify at the default `(runs, depth)` budget, the case owner:

1. Bumps `[invariant] runs` or `depth` in `foundry.toml` until the leg
   certifies, OR
2. Documents an honest caveat in the case README stating the k/N
   number the case currently achieves at the standing budget.

The reachability leg is wired as a required check in
`.github/workflows/ci.yml` alongside the base `clean-passes` and
`planted-bug-twin-fails` legs.

## Seed set

The seed list is a fixed, deterministic mix of small integers, common
test patterns, and pseudo-random-looking bytes. It is not regenerated
per run. See `ci/reachability_seeds.txt`.

## Reuse

The canonical script this leg mirrors lives at
`scripts/reachability/run_foundry_reachability.sh` in the
`caliperforge/crypto-contributor` repo. Future Foundry cases lift that
script + the seed set verbatim.

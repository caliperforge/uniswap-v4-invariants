# AI Disclosure: uniswap-v4-invariants

The `uniswap-v4-invariants` harness is built and maintained by
CaliperForge under an AI-augmented authoring stack. This document is
calm disclosure of which surfaces are AI-touched and the review
discipline that gates each one. The discipline mirrors the sibling
libraries `invariant-atlas`, `hyperevm-safety`, and `bsc-invariants`.

## What is AI-touched

- **Hook cases and invariant properties.** The clean/planted twin hook
  contracts under `src/cases/`, the property predicates, and the
  handler code under `test/` are drafted by a Claude model and
  reviewed and edited by the case specialist (`solidity_specialist`)
  before landing. Every case is additionally gated by an independent
  code-quality review before any public flip.
- **The InvariantRouter.** `src/routers/InvariantRouter.sol` is our
  own thin unlock-callback router, AI-drafted and specialist-reviewed.
  It is original code, not derived from v4-core's UNLICENSED test
  routers.
- **READMEs, case write-ups, coverage map.** Drafted with AI
  assistance; reviewed against CaliperForge's internal register rubric
  and an independent claims review before publish.

## What is NOT AI-touched

- Uniswap v4-core itself. It is vendored as a pinned, unmodified git
  submodule (zero patches). Nothing in `lib/` is authored here.
- The CI verdict. Pass/fail is a function of the `forge` run against
  the real PoolManager, not of any model output.
- The operator's final-pass sign-off decisions and the gate reviews
  (license compliance, code quality, claims) that precede the public
  flip.

## Audit trail

- Every commit lists the author (Michael Moffett, operator at
  CaliperForge) and is operator-clean.
- Both CI legs (`clean-passes` and `planted-bug-twin-fails`) run on
  every push; the planted leg prints its `INVARIANT VIOLATED` markers
  into the job summary so reviewers can see the catches.
- Code-quality reviewer audit per CaliperForge §4b, a license
  compliance review of the vendored v4-core posture, and a claims
  review of all comparator statements run BEFORE any public flip; this
  repo is private until those gates pass.

## Why we disclose

CaliperForge's identity register makes AI-augmented authorship the
default disclosure posture, not the exception. Reviewers should know
which content was AI-drafted so they can apply their own scrutiny at
that surface. See
[caliperforge.com/ai-disclosure](https://caliperforge.com/ai-disclosure)
for the org-level register.

## Contact

Operator: Michael Moffett, michael@caliperforge.com, team@caliperforge.com.

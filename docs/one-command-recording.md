# One-command screen-capture

Target artifact: `docs/one-command-run.mp4`. 30-second silent screen
recording of the fresh-clone-to-marker flow described in the top-level
README's "Quick start (one command)" section.

## Status

**Recording pending.** The `.mp4` file is not yet checked in. Per
`agents/ai_ops/policies/asset_fabrication_policy.md` §1-3, no fabricated
GIF or synthesized "screenshot of" stand-in is acceptable here; the
recording must be a real capture. Interim posture on the README's
reference to `docs/one-command-run.mp4` is per policy §2.4 (supplementary
asset, plain prose line in place), pending the real capture.

## What to record (script for the human operator)

30 seconds, silent, one continuous take:

1. `git clone --recursive https://github.com/caliperforge/uniswap-v4-invariants && cd uniswap-v4-invariants`
2. `./caliper run`
3. Frame the terminal so the final `INVARIANT VIOLATED byoh_example_afterSwap_count`
   line and the wrapper's `caliper: bundled-reference demo OK.` line are
   both visible.

## How to record

- **macOS:** QuickTime > File > New Screen Recording > select terminal
  region > Record > run the commands > Stop. Save as `.mov`, then
  `ffmpeg -i in.mov -c:v libx264 -crf 24 -preset veryfast -an docs/one-command-run.mp4`.
- **Linux:** `wf-recorder -f docs/one-command-run.mp4 -g "$(slurp)"` (Wayland)
  or `ffmpeg -f x11grab ...` (X11). `-an` strips audio.

Duration: keep under 45 seconds; edit down to ~30 with `ffmpeg -ss 0 -t 30`.
Silent by convention (matches the README's "silent recording" phrasing).

## Attestation required at merge

The land-note in `agents/build_squad_lead/outbox/T-uniswap-v4-invariants-onecommand-wrapper-2026-07-14_result.md`
attests, per asset-fabrication-policy §5:

- The `.mp4` is a real recording made by a named human operator at a
  named hostname (or CI runner ID if we script a headless capture).
- No AI-generated video, no fabricated terminal frames, no "screenshot
  of" stand-in.

## AC-4 traceability

Ticket AC-4 blocks merge on this artifact existing and being real. This
file plus the pending `.mp4` are the traceable artifacts.

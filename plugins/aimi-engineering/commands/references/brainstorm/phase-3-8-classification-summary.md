# Brainstorm: Phase 3.8: Classification Summary Line

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

## Phase 3.8: Classification Summary Line

Emit exactly one line to chat, unconditionally — on every run, including the common all-skipped path — never gated behind `AIMI_BRAINSTORM_DEBUG` or any other environment variable. Read `phase35Verdict`, `phase36Verdict`, and `phase37Verdict` back from working memory (each already set to `fired` or `skipped` at its own gate's fire-condition check above); this step never recomputes any of them.

```
[classification] phase-3.5=<phase35Verdict> phase-3.6=<phase36Verdict> phase-3.7=<phase37Verdict>
```

All three gates in this file reach their own fire-condition check on every single run, with no bypass path ahead of them — the Visual Variant Rendering bundle early-exit (Step 0a above) affects only whether `prototype_entries` is pre-populated before Phase 3.6 evaluates its own fire condition; it never skips Phase 3.5, 3.6, or 3.7 wholesale. Every token in this line is therefore always exactly `fired` or `skipped`; the `not-run` token never appears here. This is a deliberate asymmetry with `/aimi:plan`'s Classification Summary Line, whose two gates each have an entry guard that can short-circuit ahead of their own fire-condition check — not an oversight or an inconsistency to reconcile.

This line carries only the three gate-name=token pairs above — no free-text classification content, scope-context names, phase names or goals, and no `reason:` detail. The five `[brainstorm-debug]` lines above remain the only place that detail is carried, unchanged and still opt-in behind `AIMI_BRAINSTORM_DEBUG`; this line is an always-on summary above them, not a replacement.

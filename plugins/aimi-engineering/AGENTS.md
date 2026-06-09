# Output Compression Rules

<word_elimination>
Drop filler: just, really, basically, actually, simply, essentially, obviously, clearly.
Drop pleasantries: Sure!, Certainly!, Happy to help, Great question, Of course!
Drop hedging: might, perhaps, it's possible, I think, maybe, probably.
Status updates: use fragments, not full sentences.
</word_elimination>

<article_elision>
Drop articles (a, an, the) in status updates and summaries.
</article_elision>

<sentence_pattern>
Canonical caveman pattern: [thing] [action] [reason]. [next step].
Before: "I have successfully completed the migration and everything looks good."
After: "Migration complete. Running smoke tests."
</sentence_pattern>

<short_synonyms>
Prefer shorter synonyms when meaning preserved.
utilize→use, in order to→to, at this point in time→now, implement→add, additional→more.
</short_synonyms>

<scope>
Compression applies to: spawned-agent status updates, summary returns, progress reports, task confirmations.
Compression does NOT apply to: CHANGELOG.md, README.md, commit messages, PR descriptions, user-facing chat to the human running /aimi:execute.
</scope>

<safety_escapes>
Auto-expand to full clarity for:
- Destructive ops: git push --force, file deletes, database migrations
- Security warnings: credential exposure, injection risks, permission changes
- Irreversible confirmations: data loss, branch resets, production deploys
Never compress -- user safety overrides brevity.
</safety_escapes>

<preservation_rules>
Never compress: code blocks, error messages, file paths, domain terms, command examples, type signatures, URLs, version strings.
</preservation_rules>

<context_adaptive>
Terse: status updates, progress reports, confirmations, file listings.
Detailed: error explanations, architectural decisions, security assessments.
</context_adaptive>

<precedence>
This file provides base rules. Skill-level AGENTS.md files are additive and domain-specific.
Skill rules extend but never override safety escapes.
</precedence>

## Hook Response Markers

Markers in `additionalContext` are advisory. They never block execution. Treat them as hints; do not interrupt the current task to act on a marker unless explicitly directed.

| Marker | Source | Expected Agent Action |
|---|---|---|
| `[LEARNINGS CANDIDATE]` | gate-friction-threshold | If you are the top-level user session, consider running `/aimi:learnings` to triage. If you are an autonomous Task agent inside `/aimi:execute`, IGNORE — only the user-facing session should invoke triage. |

<research_return_contract>
Research agent Task returns use the pointer-block form — a fenced YAML block with keys
`research_file` (the written path), `summary` (exactly 3 headline bullets, compressed per
the rules above), and `sections` (list of the file's h2/h3 anchors in document order).
The on-disk research FILE is exempt from compression and word caps (see <preservation_rules>
above); only the Task return follows the pointer-block contract.
</research_return_contract>

<examples>

## Status update

Before:
"Sure! I've successfully completed the migration. The changes have been basically applied to all tables, and I've actually verified everything is working correctly."

After:
"Migration applied. All tables updated, verified passing."

## Error explanation

Before:
"So basically what's happening is you might be running into a TypeScript error. The issue is actually just that `UserProfile` doesn't really have `email` defined."

After:
"TypeScript error: `UserProfile` missing property `email`. Add `email: string` to the interface in `src/types/user.ts`, or use `profile?.email` if nullable."

## Combined compression (article elision + sentence pattern + short synonyms)

Before:
"I have started to implement the additional configuration changes in order to utilize the new schema format. Everything looks good at this point in time."

After:
"Config changes added to use new schema format. Verified passing."

</examples>

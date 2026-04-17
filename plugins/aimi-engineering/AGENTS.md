# Output Compression Rules

<word_elimination>
Drop filler: just, really, basically, actually, simply, essentially, obviously, clearly.
Drop pleasantries: Sure!, Certainly!, Happy to help, Great question, Of course!
Drop hedging: might, perhaps, it's possible, I think, maybe, probably.
Status updates: use fragments, not full sentences.
</word_elimination>

<safety_escapes>
Auto-expand to full clarity for:
- Destructive ops: git push --force, file deletes, database migrations
- Security warnings: credential exposure, injection risks, permission changes
- Irreversible confirmations: data loss, branch resets, production deploys
Never compress -- user safety overrides brevity.
</safety_escapes>

<preservation_rules>
Never compress: code blocks, error messages, file paths, domain terms, command examples, type signatures.
</preservation_rules>

<context_adaptive>
Terse: status updates, progress reports, confirmations, file listings.
Detailed: error explanations, architectural decisions, security assessments.
</context_adaptive>

<precedence>
This file provides base rules. Skill-level AGENTS.md files are additive and domain-specific.
Skill rules extend but never override safety escapes.
</precedence>

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

</examples>

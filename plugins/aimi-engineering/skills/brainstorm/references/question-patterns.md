# Question Patterns

Detailed reference for batched multiple-choice question formatting in brainstorm sessions.

---

## Multiple-Choice Formatting Rules

### Structure

```
1. [Question text]
   A. [Option 1]
   B. [Option 2]
   C. [Option 3]
   D. Other: [please specify]
```

### Rules

- Number questions sequentially (1, 2, 3, 4, 5)
- Use uppercase letters for options (A, B, C, D)
- Indent options with 3 spaces
- Include 3-4 options per question (not more)
- Always include an escape hatch: "Other: [please specify]"
- Keep question text under 20 words
- Keep option text under 15 words
- Present 3-5 questions per batch

---

## Shorthand Response Format

Users respond with comma-separated pairs of question number + option letter:

```
1A, 2C, 3B
```

**Meaning:** Question 1 = A, Question 2 = C, Question 3 = B

### Variations

| User Types | Interpretation |
|------------|----------------|
| `1A, 2C, 3B` | Standard shorthand |
| `1A 2C 3B` | Space-separated (accept as shorthand) |
| `A, C, B` | No numbers — map to questions in order (1=A, 2=C, 3=B) |
| `1A, 3B` | Skipped question 2 — accept partial, ask about Q2 if critical |
| `1A, 2C, 3D: custom answer` | Option D with custom text |

---

## Handling Non-Shorthand Responses

Users may respond in free-form instead of shorthand. Parse intent without re-asking.

### Examples

**Free-form sentence:**
> "I think we should go with email only for notifications, and target all users"

→ Map to: Q1 (notification type) = email only, Q2 (target user) = all users. Continue with unmapped questions.

**Mixed format:**
> "1A, but for question 3 none of the options fit — I want real-time WebSocket updates"

→ Parse: Q1 = A, Q3 = custom (WebSocket). Continue with Q2 if unanswered.

**Partial with explanation:**
> "Just A and C for the first two. Need to think about the rest."

→ Parse: Q1 = A, Q2 = C. Note remaining as unresolved. Ask in next round if critical.

**Contradictions:**
> User previously said "email only" but now picks "in-app notifications"

→ Accept the latest answer. Do not flag contradictions unless they create a logical conflict.

### Rules

1. Accept any format that conveys intent
2. Never re-ask a question solely because the format was wrong
3. If a response is genuinely ambiguous, ask a targeted clarification (not the full batch)
4. Map free-form responses to the closest option when possible
5. Treat "Other" responses as valid custom options

---

## Scenario Batches

### New Feature Brainstorm

Questions covering Purpose, Users, Scope, Constraints, and Success:

```
1. What is the primary goal of this feature?
   A. Improve existing user workflow
   B. Add new capability that doesn't exist
   C. Replace/modernize existing functionality
   D. Other: [please specify]

2. Who is the primary user?
   A. End users (customers)
   B. Internal team / admins
   C. Developers / API consumers
   D. All users equally

3. What is the desired scope?
   A. Minimal viable version (core flow only)
   B. Full-featured implementation
   C. Backend/API only (UI later)
   D. Other: [please specify]

4. Are there technical constraints?
   A. Must use existing tech stack only
   B. Open to new dependencies
   C. Must integrate with specific external service
   D. No constraints

5. How will you know this is successful?
   A. Measurable metric improvement
   B. User feedback / satisfaction
   C. Replaces manual process
   D. Other: [please specify]
```

### Refactoring Brainstorm

Questions covering Scope, Risk, Testing, and Migration:

```
1. What is the refactoring scope?
   A. Single module / file
   B. Cross-cutting concern (affects many files)
   C. Architecture change (new patterns)
   D. Other: [please specify]

2. What is the risk level?
   A. Low (internal, well-tested code)
   B. Medium (touches shared interfaces)
   C. High (affects production behavior)
   D. Other: [please specify]

3. Is the current code tested?
   A. Well-tested with good coverage
   B. Partially tested
   C. No tests exist
   D. Not sure

4. Migration strategy?
   A. Big bang (replace all at once)
   B. Incremental (new pattern alongside old)
   C. Strangler fig (gradual replacement)
   D. Other: [please specify]
```

### Bug Investigation Brainstorm

Questions covering Severity, Reproduction, Environment, and Impact:

```
1. How severe is this bug?
   A. Critical (blocks users, data loss)
   B. Major (broken feature, workaround exists)
   C. Minor (cosmetic, edge case)
   D. Other: [please specify]

2. Can you reproduce it consistently?
   A. Yes, every time with specific steps
   B. Sometimes (intermittent)
   C. Only in specific environment
   D. Cannot reproduce yet

3. Where does it occur?
   A. Production only
   B. Development and production
   C. Specific browser/device
   D. Other: [please specify]

4. What is the blast radius?
   A. All users affected
   B. Specific user segment
   C. Single user reported
   D. Not sure yet
```

---

## Generating Contextual Options from Research

### When Codebase Research Returns Findings

Use research findings to generate **specific, codebase-aware options**:

**Generic (no research):**
```
1. How should we handle authentication?
   A. Session-based
   B. Token-based (JWT)
   C. OAuth provider
   D. Other: [please specify]
```

**Contextual (with research):**
```
1. The codebase uses NextAuth with GitHub OAuth. How should we handle auth?
   A. Follow existing NextAuth pattern
   B. Add a new auth provider to NextAuth
   C. Use a different auth approach entirely
   D. Other: [please specify]
```

### Rules for Contextual Questions

1. Reference specific patterns found by `aimi-codebase-researcher` in the question text
2. Make option A the "follow existing pattern" choice (path of least resistance)
3. Include options that deviate from the pattern for valid reasons
4. Always keep the "Other" escape hatch

### When Research Fails or Returns Empty

Fall back to generic topic-based questions from the scenario batches above. Do not mention that research failed — just ask broader questions.

---

## Adaptive Round Planning

After each response round, assess which topic categories remain unaddressed:

| Category | Signals It's Addressed |
|----------|----------------------|
| Purpose | User stated the problem/goal clearly |
| Users | Target audience identified |
| Constraints | Technical limits discussed OR user confirmed none |
| Success | Measurable outcome defined |
| Edge Cases | Error states or boundaries discussed |
| Existing Patterns | Codebase context available (from research or user) |

Generate follow-up questions targeting **only** uncovered categories. Do not re-ask about addressed topics.

# Brainstorm: Phase 2: Batched Questions

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

## Phase 2: Batched Questions

Using the user's feature description and consolidated research findings (from Step 1c), generate **3-5 batched multiple-choice questions**. Include any conflict-based questions surfaced during consolidation.

### Question Generation Rules

- Questions are informed by research findings when available (contextual options)
- Fall back to generic topic-based questions when research is empty
- Cover topic categories: Purpose, Users, Constraints, Success, Edge Cases, Existing Patterns, Approach (and when UI features detected: Aesthetic Direction, Differentiation; and when greenfield structural signals detected in Phase 1.8: Foundation)
- 3-4 options per question (not more)
- Question text under 20 words
- Option text under 15 words
- Every question includes an "Other: [please specify]" escape hatch
- When research returns findings, make option A the "follow existing pattern" choice and reference specific patterns found by the research agent in the question text
- When a prototype was recorded, compose each option per `commands/references/user-communication.md` § Prototype-First Options (the follow-existing-pattern rule above stays for structure the prototype does not show).
- **Design Intent coverage gate:** When `bundleDetected=true` and Step 1c populated `bundleAddressedTopics`, treat every category present in that list as already addressed. Do not generate questions for those categories — the bundle's chat transcript has already surfaced the user's intent. Use the Design Intent section from Step 1c as a distinct context block when authoring questions for any remaining categories.

#### Approach Questions

When consolidated research (Step 1c) reveals **multiple valid approaches**, include **one** approach selection question in the current batch. Rules:

- Options are derived from research findings, each with a brief tradeoff hint (e.g., "Event-driven — scales independently, more complex")
- Follow standard format: 3-4 options, under 20 words question text, under 15 words per option, last option is "Other: [please specify]"
- Maximum **1 approach question per batch** — do not crowd out other topic categories
- **Do NOT generate an approach question when:**
  - Research context is insufficient (both agents failed/skipped or returned no approach-relevant findings) — rely on Phase 3 fallback instead
  - Research reveals a clearly superior single approach — skip the question and let Phase 3 handle it (or skip entirely)

#### Design Questions (When UI Features Detected in Phase 1.7)

When UI features were detected in Phase 1.7, include design-category questions in the batch alongside standard topic questions. These follow the same format rules.

**Example Aesthetic Direction question:**

```
N. What visual tone fits this interface best?
   A. Brutally minimal — clean, sparse, essential
   B. Retro-futuristic — nostalgic yet forward
   C. Luxury/refined — elegant, premium feel
   D. Other: [please specify]
```

**Example Differentiation question:**

```
N. What should make this interface memorable?
   A. Distinctive animation or motion
   B. Bold typography choices
   C. Unique layout composition
   D. Other: [please specify]
```

#### Foundation Questions (When Greenfield Structural Signals Detected in Phase 1.8)

When Phase 1.8 detected greenfield structural signals, include Foundation-category questions in the batch alongside standard topic questions. These follow the same format rules. Foundation spans up to five sub-topics — ask one question per sub-topic that is still relevant, but treat Foundation as a single topic category for coverage-tracking purposes (see Adaptive Rounds below), not five separate categories.

**Example stack/runtime question:**

```
N. What stack or runtime should this project use?
   A. Node.js + TypeScript — familiar, strong ecosystem
   B. Python — fast to prototype, rich libraries
   C. Go — simple deploys, strong concurrency
   D. Other: [please specify]
```

**Example architecture pattern question:**

```
N. What architecture pattern should the project follow?
   A. Monolith — single deployable, simplest to start
   B. Modular monolith — separated domains, one deploy
   C. Microservices — independent services, more ops overhead
   D. Other: [please specify]
```

**Example folder/convention question:**

```
N. How should the project's folders be organized?
   A. Feature-based — group by domain/feature
   B. Layer-based — group by technical layer (routes, models)
   C. Monorepo packages — split into independent packages
   D. Other: [please specify]
```

**Example lint/format tooling question:**

```
N. What lint and format tooling should the project use?
   A. ESLint + Prettier — widely adopted, strong defaults
   B. Biome — single fast tool, less config
   C. None yet — decide later
   D. Other: [please specify]
```

**Example language question:**

```
N. What language should this project's own files be written in?
   A. English
   B. Portuguese
   C. Spanish
   D. Other: [please specify]
```

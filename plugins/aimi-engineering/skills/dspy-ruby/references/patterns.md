# DSPy.rb Patterns & Best Practices

## Typed Context Pattern

Replace opaque string context blobs with `T::Struct` inputs. Each field gets its own `description:` annotation in the JSON schema the LLM sees:

```ruby
class NavigationContext < T::Struct
  const :workflow_hint, T.nilable(String),
        description: "Current workflow phase guidance for the agent"
  const :action_log, T::Array[String], default: [],
        description: "Compact one-line-per-action history of research steps taken"
  const :iterations_remaining, Integer,
        description: "Budget remaining. Each tool call costs 1 iteration."
end

class ToolSelectionSignature < DSPy::Signature
  input do
    const :query, String
    const :context, NavigationContext  # Structured, not an opaque string
  end

  output do
    const :tool_name, String
    const :tool_args, String, description: "JSON-encoded arguments"
  end
end
```

Benefits: type safety at compile time, per-field descriptions in the LLM schema, easy to test as value objects, extensible by adding `const` declarations.

## Schema-Driven Signatures

**Prefer typed schemas over string descriptions.** Let the type system communicate structure to the LLM rather than prose in the signature description.

### Entities as Shared Types

Define reusable `T::Struct` and `T::Enum` types in `app/entities/` and reference them across signatures:

```ruby
# app/entities/search_strategy.rb
class SearchStrategy < T::Enum
  enums do
    SingleSearch = new("single_search")
    DateDecomposition = new("date_decomposition")
  end
end

# app/entities/scored_item.rb
class ScoredItem < T::Struct
  const :id, String
  const :score, Float, description: "Relevance score 0.0-1.0"
  const :verdict, String, description: "relevant, maybe, or irrelevant"
  const :reason, String, default: ""
end
```

### Schema vs Description: When to Use Each

**Use schemas (T::Struct/T::Enum)** for:
- Multi-field outputs with specific types
- Enums with defined values the LLM must pick from
- Nested structures, arrays of typed objects
- Outputs consumed by code (not displayed to users)

**Use string descriptions** for:
- Simple single-field outputs where the type is `String`
- Natural language generation (summaries, answers)
- Fields where constraint guidance helps (e.g., `description: "YYYY-MM-DD format"`)

**Rule of thumb**: If you'd write a `case` statement on the output, it should be a `T::Enum`. If you'd call `.each` on it, it should be `T::Array[SomeStruct]`.

## Tool Patterns

### Tools That Wrap Predictions

A common pattern: tools encapsulate a DSPy prediction, adding error handling, model selection, and serialization:

```ruby
class RerankTool < DSPy::Tools::Base
  tool_name "rerank"
  tool_description "Score and rank search results by relevance"

  MAX_ITEMS = 200
  MIN_ITEMS_FOR_LLM = 5

  sig { params(query: String, items: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Hash[Symbol, T.untyped]) }
  def call(query:, items: [])
    return { scored_items: items, reranked: false } if items.size < MIN_ITEMS_FOR_LLM

    capped_items = items.first(MAX_ITEMS)
    predictor = DSPy::Predict.new(RerankSignature)
    predictor.configure { |c| c.lm = DSPy::LM.new(FeatureFlags::SYNTHESIZER_MODEL, structured_outputs: true) }

    result = predictor.call(query: query, items: capped_items)
    { scored_items: result.scored_items, reranked: true }
  rescue => e
    Rails.logger.warn "[RerankTool] LLM rerank failed: #{e.message}"
    { error: "Rerank failed: #{e.message}", scored_items: items, reranked: false }
  end
end
```

**Key patterns:**
- Short-circuit LLM calls when unnecessary (small data, trivial cases)
- Cap input size to prevent token overflow
- Per-tool model selection via `configure`
- Graceful error handling with fallback data

### Error Handling Concern

```ruby
module ErrorHandling
  extend ActiveSupport::Concern

  private

  def safe_predict(signature_class, **inputs)
    predictor = DSPy::Predict.new(signature_class)
    yield predictor if block_given?
    predictor.call(**inputs)
  rescue Faraday::Error, Net::HTTPError => e
    Rails.logger.error "[#{self.class.name}] API error: #{e.message}"
    nil
  rescue JSON::ParserError => e
    Rails.logger.error "[#{self.class.name}] Invalid LLM output: #{e.message}"
    nil
  end
end
```

## Signature Best Practices

**Keep description concise** -- The signature `description` should state the goal, not the field details:

```ruby
# Good -- concise goal
class ParseOutline < DSPy::Signature
  description 'Extract block-level structure from HTML as a flat list of skeleton sections.'

  input do
    const :html, String, description: 'Raw HTML to parse'
  end

  output do
    const :sections, T::Array[Section], description: 'Block elements: headings, paragraphs, code blocks, lists'
  end
end
```

**Use defaults over nilable arrays** -- For OpenAI structured outputs compatibility:

```ruby
# Good -- works with OpenAI structured outputs
class ASTNode < T::Struct
  const :children, T::Array[ASTNode], default: []
end
```

### Recursive Types with `$defs`

DSPy.rb supports recursive types in structured outputs using JSON Schema `$defs`:

```ruby
class TreeNode < T::Struct
  const :value, String
  const :children, T::Array[TreeNode], default: []  # Self-reference
end
```

The schema generator automatically creates `#/$defs/TreeNode` references for recursive types, compatible with OpenAI and Gemini structured outputs.

### Field Descriptions for T::Struct

DSPy.rb extends T::Struct to support field-level `description:` kwargs that flow to JSON Schema:

```ruby
class ASTNode < T::Struct
  const :node_type, NodeType, description: 'The type of node (heading, paragraph, etc.)'
  const :text, String, default: "", description: 'Text content of the node'
  const :level, Integer, default: 0  # No description -- field is self-explanatory
  const :children, T::Array[ASTNode], default: []
end
```

**When to use field descriptions**: complex field semantics, enum-like strings, constrained values, nested structs with ambiguous names. **When to skip**: self-explanatory fields like `name`, `id`, `url`, or boolean flags.

## Events System

DSPy.rb ships with a structured event bus for observing runtime behavior.

### Module-Scoped Subscriptions (preferred for agents)

```ruby
class MyAgent < DSPy::Module
  subscribe 'lm.tokens', :track_tokens, scope: :descendants

  def track_tokens(_event, attrs)
    @total_tokens += attrs.fetch(:total_tokens, 0)
  end
end
```

### Global Subscriptions (for observability/integrations)

```ruby
subscription_id = DSPy.events.subscribe('score.create') do |event, attrs|
  Langfuse.export_score(attrs)
end

# Wildcards supported
DSPy.events.subscribe('llm.*') { |name, attrs| puts "[#{name}] tokens=#{attrs[:total_tokens]}" }
```

Event names use dot-separated namespaces (`llm.generate`, `react.iteration_complete`). Every event includes module metadata (`module_path`, `module_leaf`, `module_scope.ancestry_token`) for filtering.

## Lifecycle Callbacks

Rails-style lifecycle hooks ship with every `DSPy::Module`:

- **`before`** -- Runs ahead of `forward` for setup (metrics, context loading)
- **`around`** -- Wraps `forward`, calls `yield`, and lets you pair setup/teardown logic
- **`after`** -- Fires after `forward` returns for cleanup or persistence

Execution order: before -> around (before yield) -> forward -> around (after yield) -> after. Callbacks are inherited from parent classes and execute in registration order.

## Schema Formats (BAML / TOON)

Control how DSPy describes signature structure to the LLM:

- **JSON Schema** (default) -- Standard format, works with `structured_outputs: true`
- **BAML** (`schema_format: :baml`) -- 84% token reduction for Enhanced Prompting mode. Requires `sorbet-baml` gem.
- **TOON** (`schema_format: :toon, data_format: :toon`) -- Table-oriented format for both schemas and data. Enhanced Prompting mode only.

BAML and TOON apply only when `structured_outputs: false`. With `structured_outputs: true`, the provider receives JSON Schema directly.

## Storage System

Persist and reload optimized programs with `DSPy::Storage::ProgramStorage`:

```ruby
storage = DSPy::Storage::ProgramStorage.new(storage_path: "./dspy_storage")
storage.save_program(result.optimized_program, result, metadata: { optimizer: 'MIPROv2' })
```

Supports checkpoint management, optimization history tracking, and import/export between environments.

> For detailed storage API and checkpoint management, use the Read tool on `references/optimization.md`

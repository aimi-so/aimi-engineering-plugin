---
name: dspy-ruby
description: Build type-safe LLM applications with DSPy.rb — Ruby's programmatic prompt framework with signatures, modules, agents, and optimization. Use when implementing predictable AI features, creating LLM signatures and modules, configuring language model providers, building agent systems with tools, optimizing prompts, or testing LLM-powered functionality in Ruby applications.
---

# DSPy.rb

> Build LLM apps like you build software. Type-safe, modular, testable.

DSPy.rb brings software engineering best practices to LLM development. Instead of tweaking prompts, define what you want with Ruby types and let DSPy handle the rest.

## Core Concepts

### Signatures

Define interfaces between your app and LLMs using Ruby types:

```ruby
class EmailClassifier < DSPy::Signature
  description "Classify customer support emails by category and priority"

  class Priority < T::Enum
    enums do
      Low = new('low')
      Medium = new('medium')
      High = new('high')
      Urgent = new('urgent')
    end
  end

  input do
    const :email_content, String
    const :sender, String
  end

  output do
    const :category, String
    const :priority, Priority
    const :confidence, Float
  end
end
```

> For detailed signature syntax, supported types, defaults, field descriptions, recursive types, union types, and schema formats, use the Read tool on `references/core-concepts.md`

### Modules

Composable building blocks that wrap predictors. Define a `forward` method; invoke with `.call()`.

- **Predict** -- Basic LLM calls with signatures. Fastest, lowest token usage.
- **ChainOfThought** -- Step-by-step reasoning. Adds `reasoning` field automatically. Do not define `:reasoning` in output.
- **ReAct** -- Tool-using agents with iterative reasoning + action loops.
- **CodeAct** -- Dynamic code generation agents (separate gem: `dspy-code_act`).

```ruby
class SentimentAnalyzer < DSPy::Module
  def initialize
    super
    @predictor = DSPy::Predict.new(SentimentSignature)
  end

  def forward(text:)
    @predictor.call(text: text)
  end
end

analyzer = SentimentAnalyzer.new
result = analyzer.call(text: "I love this product!")
result.sentiment  # => "positive"
```

**API rules:**
- Invoke modules and predictors with `.call()`, not `.forward()`.
- Access result fields with `result.field`, not `result[:field]`.

> For module composition, lifecycle callbacks, instruction update contract, predictor comparison, concurrent predictions, and few-shot examples, use the Read tool on `references/core-concepts.md`

### Tools & Toolsets

Create type-safe tools for agents with Sorbet signatures:

```ruby
class CalculatorTool < DSPy::Tools::Base
  tool_name 'calculator'
  tool_description 'Performs arithmetic operations'

  sig { params(operation: String, num1: Float, num2: Float).returns(T.any(Float, String)) }
  def call(operation:, num1:, num2:)
    case operation
    when 'add' then num1 + num2
    when 'subtract' then num1 - num2
    when 'multiply' then num1 * num2
    when 'divide'
      return "Error: Division by zero" if num2 == 0
      num1 / num2
    end
  end
end
```

Group related tools with `DSPy::Tools::Toolset`:

```ruby
class DataToolset < DSPy::Tools::Toolset
  toolset_name "data_processing"
  tool :convert, description: "Convert data between formats"
  tool :validate, description: "Validate data structure"

  sig { params(data: String, format: String).returns(String) }
  def convert(data:, format:)
    # ...
  end

  sig { params(data: String, format: String).returns(T::Hash[String, T.untyped]) }
  def validate(data:, format:)
    # ...
  end
end
```

> For toolset DSL details, type safety, built-in toolsets (TextProcessing, GitHubCLI), enum parameters, and testing tools, use the Read tool on `references/toolsets.md`

### Type System & Discriminators

- **Automatic `_type` field injection** for union types (`T.any()`) with structs
- **Case-insensitive enum matching** -- LLM returning `"HIGH"` matches `new('high')`
- **Recursive type support** via JSON Schema `$defs` and `$ref` pointers
- Prefer `T::Array[X], default: []` over `T.nilable(T::Array[X])`
- Limit union types to 2-4 members for reliable model comprehension

### Optimization

Improve accuracy with real data:

- **MIPROv2** -- Multi-prompt instruction optimization with bootstrap sampling and Bayesian optimization. Install: `gem 'dspy-miprov2'`
- **GEPA** -- Genetic-Pareto Reflective Prompt Evolution with feedback maps and experiment tracking. Install: `gem 'dspy-gepa'`
- **Evaluation** -- `DSPy::Evals` with built-in metrics (`exact_match`, `contains`, `numeric_difference`, `composite_and`)

> For optimization configuration, metrics, GEPA feedback maps, evaluation framework, and storage system, use the Read tool on `references/optimization.md`

## Quick Start

```ruby
# Install
gem 'dspy'

# Configure
DSPy.configure do |c|
  c.lm = DSPy::LM.new('openai/gpt-4o-mini', api_key: ENV['OPENAI_API_KEY'])
end

# Define a task
class SentimentAnalysis < DSPy::Signature
  description "Analyze sentiment of text"

  input do
    const :text, String
  end

  output do
    const :sentiment, String
    const :score, Float
  end
end

# Use it
analyzer = DSPy::Predict.new(SentimentAnalysis)
result = analyzer.call(text: "This product is amazing!")
puts result.sentiment  # => "positive"
puts result.score      # => 0.92
```

## Provider Adapters

Two strategies for connecting to LLM providers:

### Per-provider adapters (direct SDK access)

```ruby
gem 'dspy-openai'    # OpenAI, OpenRouter, Ollama
gem 'dspy-anthropic' # Claude
gem 'dspy-gemini'    # Gemini
```

### Unified adapter via RubyLLM (recommended for multi-provider)

```ruby
gem 'dspy-ruby_llm'
gem 'ruby_llm'
```

```ruby
DSPy.configure do |c|
  c.lm = DSPy::LM.new('ruby_llm/gemini-2.5-flash', structured_outputs: true)
  # c.lm = DSPy::LM.new('ruby_llm/claude-sonnet-4-20250514', structured_outputs: true)
  # c.lm = DSPy::LM.new('ruby_llm/gpt-4o-mini', structured_outputs: true)
end
```

### Fiber-Local LM Context

Override the language model temporarily:

```ruby
fast_model = DSPy::LM.new("openai/gpt-4o-mini", api_key: ENV['OPENAI_API_KEY'])

DSPy.with_lm(fast_model) do
  result = classifier.call(text: "test")  # Uses fast_model inside this block
end
```

**LM resolution hierarchy**: Instance-level LM -> Fiber-local LM (`DSPy.with_lm`) -> Global LM (`DSPy.configure`).

Use `configure_predictor` for fine-grained control over agent internals:

```ruby
agent = DSPy::ReAct.new(MySignature, tools: tools)
agent.configure { |c| c.lm = default_model }
agent.configure_predictor('thought_generator') { |c| c.lm = powerful_model }
```

> For full provider configuration, Bedrock/VertexAI setup, compatibility matrix, and feature-flagged model selection, use the Read tool on `references/providers.md`

## Resources

- [core-concepts.md](./references/core-concepts.md) -- Signatures, modules, predictors, type system deep-dive
- [toolsets.md](./references/toolsets.md) -- Tools::Base, Tools::Toolset DSL, type safety, testing
- [providers.md](./references/providers.md) -- Provider adapters, RubyLLM, fiber-local LM context, compatibility matrix
- [optimization.md](./references/optimization.md) -- MIPROv2, GEPA, evaluation framework, storage system
- [observability.md](./references/observability.md) -- Event system, dspy-o11y gems, Langfuse, score reporting
- [patterns.md](./references/patterns.md) -- Typed context, schema-driven signatures, tool patterns, best practices
- [rails-integration.md](./references/rails-integration.md) -- Directory structure, initializer, feature flags, observability
- [testing.md](./references/testing.md) -- Schema tests, tool tests, VCR setup, mocking predictions
- [signature-template.rb](./assets/signature-template.rb) -- Signature scaffold with T::Enum, Date/Time, defaults, union types
- [module-template.rb](./assets/module-template.rb) -- Module scaffold with .call(), lifecycle callbacks, fiber-local LM
- [config-template.rb](./assets/config-template.rb) -- Rails initializer with RubyLLM, observability, feature flags

## Key URLs

- Homepage: https://oss.vicente.services/dspy.rb/
- GitHub: https://github.com/vicentereig/dspy.rb
- Documentation: https://oss.vicente.services/dspy.rb/getting-started/

## Guidelines for Claude

When helping users with DSPy.rb:

1. **Schema over prose** -- Define output structure with `T::Struct` and `T::Enum` types, not string descriptions
2. **Entities in `app/entities/`** -- Extract shared types so signatures stay thin
3. **Per-tool model selection** -- Use `predictor.configure { |c| c.lm = ... }` to pick the right model per task
4. **Short-circuit LLM calls** -- Skip the LLM for trivial cases (small data, cached results)
5. **Cap input sizes** -- Prevent token overflow by limiting array sizes before sending to LLM
6. **Test schemas without LLM** -- Validate `input_json_schema` and `output_json_schema` in unit tests
7. **VCR for integration tests** -- Record real HTTP interactions, never mock LLM responses by hand
8. **Trace with spans** -- Wrap tool calls in `DSPy::Context.with_span` for observability
9. **Graceful degradation** -- Always rescue LLM errors and return fallback data

> For detailed signature best practices, typed context patterns, error handling concerns, and advanced tool patterns, use the Read tool on `references/patterns.md`
> For Rails directory structure, initializers, and feature-flagged model selection, use the Read tool on `references/rails-integration.md`
> For testing strategies and examples, use the Read tool on `references/testing.md`

## Version

Current: 0.34.3

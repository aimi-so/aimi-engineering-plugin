# DSPy.rb Testing

## Signature Schema Tests

Test that signatures produce valid schemas without calling any LLM:

```ruby
RSpec.describe ClassifyResearchQuery do
  it "has required input fields" do
    schema = described_class.input_json_schema
    expect(schema[:required]).to include("query")
  end

  it "has typed output fields" do
    schema = described_class.output_json_schema
    expect(schema[:properties]).to have_key(:search_strategy)
  end
end
```

## Tool Tests with Mocked Predictions

```ruby
RSpec.describe RerankTool do
  let(:tool) { described_class.new }

  it "skips LLM for small result sets" do
    expect(DSPy::Predict).not_to receive(:new)
    result = tool.call(query: "test", items: [{ id: "1" }])
    expect(result[:reranked]).to be false
  end

  it "calls LLM for large result sets", :vcr do
    items = 10.times.map { |i| { id: i.to_s, title: "Item #{i}" } }
    result = tool.call(query: "relevant items", items: items)
    expect(result[:reranked]).to be true
  end
end
```

## VCR Setup for Rails

```ruby
VCR.configure do |config|
  config.cassette_library_dir = "spec/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.filter_sensitive_data('<GEMINI_API_KEY>') { ENV['GEMINI_API_KEY'] }
  config.filter_sensitive_data('<OPENAI_API_KEY>') { ENV['OPENAI_API_KEY'] }
end
```

## Unit Testing Individual Tools

Test `DSPy::Tools::Base` subclasses by instantiating and calling `call` directly:

```ruby
RSpec.describe WeatherLookup do
  subject(:tool) { described_class.new }

  it "returns weather for a city" do
    result = tool.call(city: "Berlin")
    expect(result).to include("Berlin")
  end

  it "exposes the correct tool name" do
    expect(tool.name).to eq("weather_lookup")
  end

  it "generates a valid schema" do
    schema = described_class.call_schema_object
    expect(schema[:required]).to include("city")
    expect(schema[:properties]).to have_key(:city)
  end
end
```

## Unit Testing Toolsets

Test toolset methods directly on an instance. Verify tool generation with `to_tools`:

```ruby
RSpec.describe DatabaseToolset do
  subject(:toolset) { described_class.new }

  it "executes a query" do
    result = toolset.query(sql: "SELECT 1")
    expect(result).to be_a(String)
  end

  it "generates tools with correct names" do
    tools = described_class.to_tools
    names = tools.map(&:name)
    expect(names).to contain_exactly("db_query", "db_insert", "db_delete")
  end
end
```

## Mocking Predictions Inside Tools

When a tool calls a DSPy predictor internally, stub the predictor to isolate tool logic from LLM calls:

```ruby
class SmartSearchTool < DSPy::Tools::Base
  extend T::Sig

  tool_name "smart_search"
  tool_description "Search with query expansion"

  sig { void }
  def initialize
    @expander = DSPy::Predict.new(QueryExpansionSignature)
  end

  sig { params(query: String).returns(String) }
  def call(query:)
    expanded = @expander.call(query: query)
    perform_search(expanded.expanded_query)
  end

  private

  def perform_search(query)
    # actual search logic
  end
end

RSpec.describe SmartSearchTool do
  subject(:tool) { described_class.new }

  before do
    expansion_result = double("result", expanded_query: "expanded test query")
    allow_any_instance_of(DSPy::Predict).to receive(:call).and_return(expansion_result)
  end

  it "expands the query before searching" do
    allow(tool).to receive(:perform_search).with("expanded test query").and_return("found 3 results")
    result = tool.call(query: "test")
    expect(result).to eq("found 3 results")
  end
end
```

## Testing Enum Coercion

Verify that string values from LLM responses deserialize into the correct enum instances:

```ruby
RSpec.describe "enum coercion" do
  it "handles case-insensitive enum values" do
    toolset = GitHubCLIToolset.new
    result = toolset.list_issues(state: IssueState::Open)
    expect(result).to be_a(String)
  end
end
```

## Evaluation Framework Testing

Use `DSPy::Evals` to systematically test LLM application performance:

```ruby
metric = DSPy::Metrics.exact_match(field: :answer, case_sensitive: false)
evaluator = DSPy::Evals.new(predictor, metric: metric)
result = evaluator.evaluate(test_examples, display_table: true)
puts "Pass Rate: #{(result.pass_rate * 100).round(1)}%"
```

Built-in metrics: `exact_match`, `contains`, `numeric_difference`, `composite_and`. Custom metrics return `true`/`false` or a `DSPy::Prediction` with `score:` and `feedback:` fields.

Use `DSPy::Example` for typed test data and `export_scores: true` to push results to Langfuse.

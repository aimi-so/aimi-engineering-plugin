import { tool } from "@opencode-ai/plugin"
import { $ } from "bun"

/**
 * Safe model identifier pattern.
 * Allows letters, digits, dot, underscore, slash, and hyphen only.
 * This is defense-in-depth — resolve-models is the primary security boundary.
 */
const SAFE_MODEL_PATTERN = /^[a-zA-Z0-9._\/-]+$/

/**
 * Derive the bare OpenCode agent name from an aimi-engineering subagent_type.
 *
 * Input forms handled:
 *   - "aimi-engineering:CATEGORY:NAME"  → "NAME"
 *   - "aimi-engineering:NAME"           → "NAME"
 *   - "NAME"                            → "NAME" (pass-through)
 *
 * The algorithm strips the leading "aimi-engineering:" prefix if present,
 * then strips any remaining single "CATEGORY:" prefix segment so the result
 * is always the bare agent name used by `opencode run --agent`.
 */
function deriveAgentName(subagentType: string): string {
  let name = subagentType

  // Strip "aimi-engineering:" prefix
  if (name.startsWith("aimi-engineering:")) {
    name = name.slice("aimi-engineering:".length)
  }

  // Strip a single remaining CATEGORY: prefix segment if present
  // A CATEGORY segment contains no colon — only letters, digits, and hyphens
  const colonIdx = name.indexOf(":")
  if (colonIdx !== -1) {
    name = name.slice(colonIdx + 1)
  }

  return name
}

/**
 * Validate the model identifier against a safe charset.
 * Returns the model string if safe, or null if it should be omitted.
 *
 * An empty string or the sentinel value "inherit" causes the model flag
 * to be omitted so the spawned agent inherits the session model.
 */
function validateModel(model: string | undefined): string | null {
  if (!model || model === "inherit") {
    return null
  }
  if (!SAFE_MODEL_PATTERN.test(model)) {
    return null
  }
  return model
}

export default tool({
  description:
    "Spawn a named subagent with an optional per-spawn model override. " +
    "Use instead of the native task tool when per-spawn model selection is required. " +
    "Accepts aimi-engineering:CATEGORY:NAME subagent_type format and extracts the bare agent name.",
  args: {
    subagent_type: tool.schema
      .string()
      .describe(
        "Agent type in aimi-engineering:CATEGORY:NAME format or a bare OpenCode agent name"
      ),
    prompt: tool.schema
      .string()
      .describe("The task for the subagent to perform"),
    model: tool.schema
      .string()
      .optional()
      .describe(
        "Model override in provider/model-id format, e.g. anthropic/claude-opus-4-5. " +
          'Omit or pass "inherit" to inherit the session model.'
      ),
    description: tool.schema
      .string()
      .optional()
      .describe("Optional human-readable description of this spawn (unused at runtime)"),
  },
  async execute(args, context) {
    const agentName = deriveAgentName(args.subagent_type)
    const safeModel = validateModel(args.model)

    // Build the command as an array — Bun's $ array form passes each element
    // as a separate argv entry with no shell interpolation, preventing injection.
    const cmd: string[] = ["opencode", "run", "--agent", agentName, "--dir", context.directory]

    if (safeModel !== null) {
      cmd.push("--model", safeModel)
    }

    // Prompt is the positional argument — append last
    cmd.push(args.prompt)

    const output = await $`${cmd}`.text()
    return output
  },
})

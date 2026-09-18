# Additional agent and model targets

This is a documentation-based integration assessment, reviewed on 2026-09-17. Candidate tools were not installed or exercised in this audit. Recommendations describe integration priorities, not proven compatibility or comparative model quality.

## Recommendation

Add Gemini CLI as the first additional dialogue adapter after the Claude/Codex workflow works reliably. Evaluate OpenCode next for access to multiple providers and local models. Add GitHub Copilot CLI when demand justifies another account and policy integration. Assess Cursor's CLI separately from the existing Cursor configuration port. Keep Aider as a narrower alternative for scripted review and editing.

A dialogue adapter is smaller than a complete governance port: it launches a bounded task, constrains permissions, captures a result, and classifies failure. Supporting a critic through an adapter should not imply that every hook, skill, or runtime event has been ported.

## Candidate assessment

| Candidate | Documented integration surface | Value for this harness | Limitation and proposed priority |
| --- | --- | --- | --- |
| Gemini CLI | Headless prompts, JSON/JSONL results, model selection, and a documented plan approval mode. | Adds a Google model family to the initial Anthropic/OpenAI pairing. | First additional adapter. Validate read-only behavior and classify authentication and quota failures in fixtures. |
| OpenCode | Noninteractive runs, explicit provider/model selection, JSON events, and configurable permissions. | One adapter can support multiple providers and local inference. | Second. Pin a supported CLI generation because V2 changes configuration and permissions. |
| GitHub Copilot CLI | Noninteractive prompts, model selection, JSONL output, and tool allow/deny controls. | Offers another access route for users already using Copilot. | Conditional. Another client does not ensure an independent underlying model or failure domain. |
| Cursor CLI | Headless execution, structured output, and CLI-specific permission configuration. | Builds on an existing repository surface. | Evaluate separately. Existing port files do not prove a safe automated reviewer integration. |
| Aider | Scripted prompts and selectable hosted or Ollama models. | A focused alternative for review/edit tasks and local-model experiments. | Defer until needed. A dialogue adapter would still need its own result normalization and permission checks. |

Gemini's [headless reference](https://geminicli.com/docs/cli/headless/) documents output and exit status; its [configuration reference](https://geminicli.com/docs/reference/configuration/) documents plan mode, and [model selection](https://geminicli.com/docs/cli/model/) describes model controls. Headless mode can reuse cached authentication; an unauthenticated installation needs explicit setup. Authentication choice affects quota, pricing, and privacy, so the adapter must not silently switch methods. See [authentication](https://geminicli.com/docs/get-started/authentication/).

OpenCode documents `run`, `--model`, and JSON output in its [CLI reference](https://opencode.ai/v2/docs/cli/commands/). Its [provider guide](https://opencode.ai/v2/docs/providers) includes local Ollama, LM Studio, and vLLM integration. Its [permissions reference](https://opencode.ai/v2/docs/permissions) distinguishes V2 configuration from earlier versions. Local inference is an option, not evidence that an arbitrary model can perform reliable code review.

GitHub documents `--model`, `--output-format`, `--available-tools`, and permission controls in the [Copilot programmatic reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-programmatic-reference). An adapter must validate the effective model because a custom agent's model setting takes precedence over the command-line selection. Account entitlements and usage policy need a separate integration check; this audit makes no pricing claim.

Cursor documents [headless use](https://docs.cursor.com/en/cli/headless), [output formats](https://docs.cursor.com/en/cli/reference/output-format), and [CLI permissions](https://docs.cursor.com/cli/reference/permissions). Validate the installed version rather than assuming editor permissions apply to CLI runs. Aider documents [scripting](https://aider.chat/docs/scripting.html) and [Ollama models](https://aider.chat/docs/llms/ollama.html); these establish integration options, not equivalent governance coverage.

## Model selection

Treat the runtime, provider, and model as separate fields. A user selects a primary actor and an optional secondary reviewer. Each selection needs a runtime adapter, provider or account route, model identifier, and optional reasoning settings. Do not hard-code a permanent list of model releases in the harness.

Start evaluation with a Gemini model available through the installed Gemini CLI. For a local route, evaluate a coding-capable model supported by the chosen runtime, with Qwen or DeepSeek families as candidates rather than certified defaults. Capture the exact model version, hosting provider, and hardware in evaluation results. Provider availability is not evidence of task quality.

Model diversity and outage independence are different properties. Two tools can call the same model family or depend on the same account service. Report the actual pairing and avoid describing every two-tool run as an independent cross-model review.

## Fallback contract to implement

1. Allow no secondary reviewer to be configured. Do not require a second account for setup.
2. Detect disabled, missing, unauthenticated, unsupported-model, limited, timed-out, and permission-blocked states separately. Check availability without submitting a paid task where possible.
3. If the secondary is unavailable, use a separate read-only reviewer session on the primary when configured to do so, or record the review as skipped. Do not describe either outcome as completed cross-model review.
4. If the primary is unavailable, offer only a preconfigured, authorized actor route. Reviewer fallback must not silently grant implementation rights. Stop if no authorized actor is available.
5. Preserve account and billing choices. Never convert subscription failure into an unapproved API charge or send a private artifact to an unapproved provider.
6. Bound retries, time, and review rounds. Preserve a resumable artifact and report requested versus effective runtime, provider, and model.
7. Require a proven read-only capability for critic roles. Tool policy alone must not be described as operating-system isolation. Disable or isolate shell and external write-capable tools as needed.

These are proposed harness requirements. Existing tool documentation does not demonstrate that the harness implements them today.

## Evaluation before support

Exercise each adapter against the same bounded tasks: spec contradiction, missing negative test, implementation defect, parity gap, unsupported reviewer claim, and no-findings case. Include missing credentials, unavailable executables, quota responses, malformed output, timeout, interruption, and attempts to write through both file tools and shell commands.

Measure confirmed defects found, false positives, incorrect suggested changes, elapsed time, and incremental usage or cost. Record unsupported capabilities explicitly. Publish support only after these checks pass for a named tool version. This audit recommends no automatic installation and makes no external model calls.

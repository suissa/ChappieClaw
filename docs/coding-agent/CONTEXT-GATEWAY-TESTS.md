# Context Gateway contract test in ChappieClaw

This fork contains a provider-neutral test implementation of the Context Gateway contract from AllasCode in `src/coding/context_gateway.zig`.

The tests cover:

- accepting a candidate only when all caller-supplied validation flags are true and both byte and token counts strictly decrease;
- byte-identical fallback to the original request when validation is incomplete;
- rejecting invalid structured output and unauthorized tool calls;
- failing closed when the fixed-size audit journal is full;
- keeping raw payload bytes out of audit records.

The module is exported by `src/coding.zig`, which is already part of the root test graph. The existing CI workflow therefore runs these tests through `zig build test --summary all` using Zig 0.16.0.

## Scope and limitation

This verifies the gateway contract and documents its integration into the agent turn loop. Blocking and streaming provider requests pass through the request-admission hook; direct text/tool boundaries and buffered streaming output pass through response gates. The optional transformer callback is not configured by default.

The gateway does not independently prove that a transformation is lossless. Its caller must supply valid evidence for coverage, policy, cache compatibility, and token counts. FNV-1a fingerprints are for correlation only, not cryptographic integrity or authorization.


## Live runtime boundary

The agent turn loop invokes the provider-neutral Context Gateway before returning a direct text response and before dispatching each parsed tool call. Direct text is admitted through the text-response boundary. Tool arguments must parse as a JSON object and the tool name must be non-empty; rejected calls are converted into failed tool results and are not executed.

This is a structural gate, not an authorization grant. The existing `executeTool` and security-policy path remains responsible for tool authorization. The gateway is scoped to one model iteration with bounded audit capacity. If no transformer callback is configured, outbound provider messages remain unchanged. Streaming chunks are buffered and are not exposed until the complete response passes the response gate.


## Provider-boundary integration

`Agent.setContextTransformer(callback, ctx)` installs an optional provider-neutral adapter. For every blocking `chat()` and `streamChat()` attempt—including retry attempts—the agent passes the exact typed `ChatRequest` through this callback before the provider call. The adapter may return a `Candidate` containing a replacement request and its validation evidence. The runtime applies the Context Gateway admission rules; rejected, missing, or callback-error candidates fall back to the original request. Audit-capacity errors stop the call rather than silently bypassing the gateway.

The callback is the integration seam for a separate context condenser. This repository does not embed ChappieContextCondenser, make network calls to it, or claim that a candidate's `lossless` flag is independently proven. An adapter must produce evidence from its own validation process and must keep candidate slices alive for the supplied allocator's lifetime (normally the current turn arena).

Streaming provider chunks are now buffered by `context_stream_gate.Gate`. The downstream callback receives one validated text delta and a final chunk only after stream completion. If a streaming attempt fails and retries, its buffered partial output is discarded. Buffer allocation failure rejects publication rather than exposing a truncated answer. This strict mode increases time-to-first-token and buffers the complete output in memory.

No context transformer is installed by default; behavior remains unchanged until the application configures one with `setContextTransformer`.

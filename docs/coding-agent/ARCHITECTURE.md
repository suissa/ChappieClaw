# AllasCode Coding Agent Architecture

ChappieClaw remains a generic autonomous-agent runtime. Coding behavior is an opt-in specialization layered on top of the existing tool, skill, subagent, sandbox, observability, and ACP infrastructure.

## Lifecycle

Every autonomous code change follows:

```
inspect -> hypothesize -> plan -> mutate -> verify -> prove -> done
```

Mutation is forbidden until a causal hypothesis and a plan have been recorded. A run cannot reach proof or completion until verification evidence has passed.

## Authority split

- **CodeManager** inspects code, gathers diagnostics, forms a causal hypothesis, and plans.
- **CodeHealer** receives an authorized plan and performs bounded mutations.
- **HealingVerifier** receives the problem, original-state evidence, patch, acceptance criteria, and test surface. It verifies independently and does not inherit the healer's reasoning context.
- Final public success/error remains Runtime-owned; specialized agents provide evidence rather than self-authorizing completion.

## Atomic AllasCode SKILLs

The canonical knowledge unit is the same artifact knowledge used across AllasCode:

- `semantics`: what the artifact is, invariants, authority, relations, event/runtime contract.
- `authoring`: how to implement and test it, including writable paths.
- `healing`: optional empirical failure/fix patterns promoted only after independent verification.

A skill manifest provides machine-readable resolver metadata; `SKILL.md` remains the human/agent-readable explanation.

Resolution combines bounded knowledge rather than loading the whole architecture:

```
Action skill
+ language skill
+ architecture/protocol skill
+ current diagnostic/healing skill
= bounded coding context
```

## Safe mutation

Coding mode should prefer hashed read/edit operations so a patch based on stale source state is rejected. Workspace scope, path allowlists, command allowlists, sandboxing, and destructive-command policy remain hard runtime boundaries.

## Coding tools

The initial coding catalog covers search, symbols, compile, test, lint, format, diagnostics, and Git inspection. Language adapters begin with Zig, Rust, Go, and TypeScript.

## Healing knowledge loop

```
verified fix
 -> extract failure signature + causal hypothesis + fix pattern
 -> candidate healing skill
 -> validate
 -> promote
```

Failed or inconclusive fixes never become trusted knowledge.

## ACP

ACP sessions expose coding-mode state (workspace, phase, diagnostic/verification summary) without exposing hidden reasoning. ACP requests must use the same mutation policy as every other channel.

## Lineage

Each run records metadata needed to reconstruct the change safely: inspected file hashes, selected skill IDs/versions, hypothesis/plan hashes, mutation hashes, verification commands, diagnostics summary, and proof state. Raw secrets and unnecessary source payloads are excluded.

## Completion Discipline

**Nothing is done until it's fully done.** This is the #1 priority governing all work.

### Finish everything

Before declaring any task complete, verify against the source of truth:
- **Milestone/task has a checklist (ROADMAP, issue, spec)?** Every item must be addressed — implemented, tested, and checked off. If an item can't be done, explain why explicitly. Never silently skip items.
- **Tests are listed?** Every test must be implemented and run. A test that wasn't run is the same as a test that doesn't exist.
- **Code was written?** It must build and run successfully. "It should work" is not verification.

**Anti-pattern to avoid:** Implementing 80% of a task, declaring it "complete," and leaving the remaining 20% as implied future work. If the task says "verify f32, f16, int8" — verify all three, not just the first two.

### Self-review after implementation

After completing any non-trivial implementation, proactively review your own work before presenting it to the user:

1. **Completeness check:** Re-read the original requirements. Did you miss anything? Compare deliverables against the spec line by line.
2. **Build & test:** Run the build. Run the tests. If something fails, fix it — don't report partial success.
3. **Code quality scan:** Look at the code you wrote for:
   - Obvious bugs (off-by-one, null/nil handling, resource leaks)
   - Style consistency with existing code in the project
   - Missing error handling at boundaries
   - Hardcoded values that should be configurable
4. **Update tracking artifacts:** If there's a ROADMAP, checklist, or issue tracker — update it with actual results. Check boxes, note findings, record deviations.
5. **Propose improvements:** If you notice something worth improving but outside current scope, mention it explicitly rather than silently ignoring it.

If a self-review would take more effort than the implementation itself, at minimum do steps 1 (completeness) and 2 (build & test).

### When something doesn't work as expected

Document it honestly. If a test reveals a limitation (e.g., a backend doesn't support a feature), that's a finding — record it in the appropriate place (ROADMAP, report, or both) with the actual behavior and why. Don't paper over failures or quietly downgrade expectations.

---

## Anti-Patterns to Avoid

This project uses Obj-C++, C++17, Metal/MPS, and manual memory management (no ARC). Every code change must avoid these patterns. When reviewing code — your own or an agent's — check against this list.

### Concurrency & Data Races

- **Unprotected shared state between GCD and C++ threads.** CTranslate2 has its own thread pool. If GCD blocks access the same `Whisper` instance or `StorageView` without serialization, data races occur. Use a serial dispatch queue or separate model replicas per concurrent task.
- **Metal completion handler races.** `addCompletedHandler:` runs on an arbitrary Metal thread. Never modify shared state from a completion handler without synchronization — dispatch to a known queue.
- **C++ mutex held across `dispatch_async`.** A block may execute on a different thread than the one that locked. Use GCD serial queues for synchronization instead of mixing C++ mutexes with GCD.
- **`StorageView` shared across threads.** CTranslate2's tensor container is not thread-safe. Never pass a `StorageView` to one call while another thread reads or modifies it.
- **Concurrent encoding on the same `MTLCommandBuffer`.** Encoding is not thread-safe per command buffer. Create separate command buffers per thread via `MTLCommandQueue` (which is thread-safe).

### Time-Based Logic

- **Sleep-based polling.** Never use `usleep`/`sleep`/`[NSThread sleep...]` loops to wait for GPU or async work. Use `dispatch_semaphore_wait`, `MTLEvent`/`MTLSharedEvent`, or `addCompletedHandler:`.
- **`waitUntilCompleted` stalls.** Avoid blocking CPU while GPU executes when you could pipeline work. While GPU runs segment N, CPU should prepare segment N+1.
- **Hardcoded timeouts.** Don't hardcode timeouts for model loading or inference. Make them configurable or use cancellation tokens.

### Hardcoded Constants

- **Magic numbers.** Never write raw `3000`, `80`, `128`, `1500`, `0.5`, `2.4` etc. in code. Define named constants (`kMWDefaultChunkFrames`, `kMWCompressionRatioThreshold`) with a comment citing the source (e.g., Whisper paper, model config).
- **Hardcoded absolute paths.** Use configurable variables (CMake cache vars, environment vars, function parameters). No `/Users/...` in committed code.
- **Unchecked platform assumptions.** Don't assume Metal is available — check `MTLCreateSystemDefaultDevice()` and provide a clear error. Don't assume Apple Silicon (unified memory) without checking.

### God Objects & File Size

- **Single class doing everything.** `MWTranscriber` must delegate to `MWFeatureExtractor`, `MWTokenizer`, `MWDecodeLoop`, etc. — not absorb their logic. No class should exceed ~800 lines.
- **No file over 1000 lines.** If a file grows past this, split by responsibility.
- **No "Utils" dumping ground.** Group utilities by domain: `MWAudioMath.h`, `MWCompressionUtils.h`.
- **Header accumulation.** Don't put all types in one header. Use separate headers per concern: `MWTypes.h`, `MWErrors.h`, `MWSegment.h`, with an umbrella `MetalWhisper.h`.

### C++ Specific

- **Raw pointer ownership ambiguity.** Use `std::unique_ptr` for owning, raw pointers only for non-owning observers. Document ownership at every API boundary.
- **RAII gaps in exception paths.** Every `alloc`/`new`/resource acquisition must be cleaned up even if an exception is thrown. In MRC code, a C++ exception skips `[obj release]` — use `@try/@finally` or C++ RAII wrappers around Obj-C objects.
- **Object slicing.** Never store polymorphic objects by value. Use pointers or references.
- **Dangling references to temporaries.** Always copy `[nsString UTF8String]` into `std::string` — the `const char*` dies when the autorelease pool drains.
- **`shared_ptr` cycles.** Use `weak_ptr` for back-references. Prefer `unique_ptr` with non-owning raw pointers.
- **Header bloat.** Keep C++ includes strictly in `.mm` files. Never include CTranslate2 headers in public `.h` — this would break Swift imports (M10).

### Objective-C (MRC) Specific

- **Missing release on early-return paths.** Every `alloc`/`copy` must have a matching `release` on ALL code paths including error returns. Audit early returns for leaks.
- **Autorelease accumulation in loops.** Wrap every iteration of long-running loops (decode loop, batch processing) in `@autoreleasepool {}`.  For 1-hour audio this prevents hundreds of MB of leaked temporaries.
- **`@autoreleasepool` in init or around autoreleased return values.** Don't wrap init in `@autoreleasepool` (`[self release]` on failure risks premature dealloc). Don't wrap methods returning autoreleased objects — the pool drains the return value before the caller gets it.
- **Obj-C objects in C++ containers without retain.** `std::vector<NSString*>` doesn't call `retain` on insert or `release` on removal. Use `NSMutableArray` for Obj-C collections, or write a RAII wrapper.
- **Missing `@autoreleasepool` on C++ threads.** When CTranslate2 callbacks create Obj-C objects, there's no pool on the C++ thread. Wrap in `@autoreleasepool {}`.
- **Category method collisions.** Always prefix category methods: `mw_methodName`. Or prefer standalone functions over categories.
- **Forgetting `[super dealloc]`.** Must be the LAST line in `dealloc`, after all cleanup.

### Metal/GPU Specific

- **Unnecessary CPU↔GPU copies on unified memory.** Apple Silicon shares physical memory. Create `StorageView` on `Device::MPS` when the GPU will consume it. Pass `to_cpu=false` when the result feeds another GPU operation. Only copy to CPU for token/text processing.
- **No triple buffering for streaming.** For continuous audio (M13), maintain 3 mel spectrogram buffers with a `dispatch_semaphore_t(3)` to overlap CPU prep and GPU execution.
- **Blocking main thread with GPU work.** Always submit and wait for GPU work on background queues. Only dispatch UI updates to main.

### C++/Obj-C++ Interop

- **C++ exceptions crossing Obj-C boundaries.** Apple frameworks are not exception-safe — a C++ exception through `NSRunLoop`, GCD, or any Apple frame causes undefined behavior (typically abort). **Every** public Obj-C method calling C++ code must wrap in `try/catch`. No exceptions.
- **C++ types in public headers.** Never expose `std::string`, `StorageView`, etc. in `.h` files. Swift can't import them and it forces all importers to compile as Obj-C++. Use pimpl — declare C++ ivars in `@implementation`, not `@interface`.
- **Mixing memory models.** Don't `retain`/`release` C++ objects or `new`/`delete` Obj-C objects. Keep each in its own world.

### General

- **Cargo cult porting.** Don't transliterate Python line-by-line. Understand the algorithm, then implement idiomatically in C++/Obj-C++. Use Python as a spec, not a template.
- **Copy-paste error handling.** Extract a helper for the repeated try/catch→NSError pattern rather than duplicating it in every method.
- **Premature optimization.** Profile before writing SIMD intrinsics or Metal compute shaders for operations that aren't bottlenecks. For Whisper, the bottleneck is attention layers (GPU), not mel extraction or tokenization (CPU).
- **Golden hammer.** Don't route everything through Metal. Tokenization, string processing, file I/O belong on CPU. GPU is for matrix ops, FFT, model inference.
- **Boat anchor.** Don't build abstractions for features that don't exist yet (e.g., "generic backend" for CUDA support). YAGNI — this targets macOS Apple Silicon only.

---

## Temporary Files

You can use the `tmp/` subfolder in the current project folder to save any temporary files if needed.
This is useful for storing intermediate results, reports, or data during multi-step workflows.

---

## Agents

Agents folder: `.claude/agents/`. Use agents for all non-trivial subtasks — code writing, analysis, design, debugging, testing, documentation.

**Rules:**
- Before any subtask: select the best agent and read its `.md` file (always fresh re-read)
- Load ONE agent at a time (Exception: Opus-GLM may read multiple for prompt building)
- DO NOT use the Task tool for agents — use in-session loading (Exception: Opus-GLM uses spawn-glm.sh)
- Agent instructions are TEMPORARY — apply to current subtask only, discard after

**Discovery:** Glob `.claude/agents/*.md` to list, Grep by keyword. Prefer specialized over general agents.

### Request Workflow

1. **Memory:** `./.claude/tools/memory.sh context "<keywords>"` — extract from entities, technologies, services, error types. MANDATORY for non-trivial tasks
2. **Continuation:** `memory.sh search "GLM-CONTINUATION"` — resume if exists
3. **Evaluate GLM:** If any Opus-GLM delegate trigger matches → enter GLM flow (skip 4-5)
4. **Plan:** For multi-step tasks: `memory.sh session add plan "..."`
5. **Decompose:** List subtasks, map each to best agent, report to user

**Agent selection:** Most specialized wins (e.g., postgres-pro over database-optimizer). Split hybrid tasks into subtasks with different agents.

### Subtask Workflow

1. Read agent `.md` → apply to current subtask → complete fully → verify quality
2. Save discoveries to knowledge if non-trivial
3. Discard agent instructions → next subtask
4. After all subtasks: compose into one report

---

## Opus-GLM

Dynamic orchestration where Opus delegates work to GLM agents. Evaluates every task, designs the workflow, spawns agents, verifies output, delivers results. **Automatic by default.**

### When to Delegate

Evaluate every non-trivial task. Delegation is the default.

1. **Changes < 50 lines AND full context** → handle directly
2. **Otherwise**, any match → delegate:

- Independent parallelizable subtasks
- Production checks, security audits, code reviews
- Large refactors (5+ files) or deep research
- 3+ unrelated modules or domains
- Requires both research and implementation
- Would need >10 lead turns of direct work
- Analysis of >200 lines of code
- Requires shell commands to test/validate

| Scope | Agents/Stage | When |
|-------|--------|------|
| Focused | 1 | Single heavy task |
| Small | 2-3 | Few independent subtasks |
| Full | up to 3 | Project-wide analysis |

Prefer fewer well-prompted agents over many thin ones.

### Lead Role

The lead is an **autonomous orchestrator**, not a developer doing hands-on work.

**Does:** plan, decompose, design workflow stages, write agent prompts, spawn agents, verify results, fix gaps, synthesize, deliver.

**Does not:** run test suites, do comprehensive audits unprompted, write substantial code, do deep research. These are agent work.

**Self-check rules (MANDATORY):**
- 5+ consecutive Read/Grep/Bash calls without spawning = you're doing agent work. STOP and delegate
- If urgent work truly requires >5 direct turns, justify: `DIRECT WORK: [reason]`
- Exceptions: planning (skimming files to scope agents) and verification (reading files to check agent claims) both require heavy Read usage — this is allowed

**Verification vs implementation boundary:**
- Verification (lead does): Read files, compare to agent claims, label findings, update checklist, write synthesis
- Implementation (agent does): Writing/editing code, running test suites, fixing bugs, adding tests, refactoring
- **When to delegate:** Large implementation work (new features, 5+ files, 50+ lines of new code) → always spawn an agent
- **When lead does direct work:** Agent failed or produced poor results AND the remaining fix is manageable (under ~50 lines, few files). Justify with `DIRECT WORK: [reason]`. This is expected and efficient — don't respawn for small cleanup
- After verification, if many fixes are needed across many files: collect them into a fix-agent prompt and spawn

**Workflow autonomy:** The lead designs the complete workflow and runs it to completion without user interaction. The lead chooses what stages are needed (research, implement, test, audit, or any combination), their order, agent count, and can add or modify stages during execution as understanding deepens. Each stage follows the prepare → spawn → verify cycle. The lead has full authority to adapt the plan mid-execution — no restrictions on total agents or stages if the task requires them.

### Tools

All GLM agents use **sonnet** (hardcoded in spawn-glm.sh, no override).

**Spawn:**
```bash
.claude/tools/spawn-glm.sh -n NAME -f PROMPT_FILE
```
Returns `SPAWNED|name|pid|log_file`. Backgrounds immediately. Report: `tmp/{NAME}-report.md`, log: `tmp/{NAME}-log.txt`. Also writes to `tmp/{NAME}-status.txt` (reliable on Windows — stdout can be lost when parallel `.cmd` processes launch).

**Wait:**
```bash
.claude/tools/wait-glm.sh name1:$PID1 name2:$PID2 name3:$PID3
```
Blocks until all finish (Bash timeout: 600000). Do NOT use bare `wait` or `sleep` + poll loops. Prefer `name:pid` format — enables progress monitoring (first at 30s, then every 60s) and STALLED detection (0-byte log after 2min). Bare PIDs still work but skip log monitoring. If Bash times out before agents finish, re-invoke with same arguments — this is normal for long-running agents.

### Workflow

The lead designs the workflow. Typical flow: plan → for each stage: prepare → spawn → verify → synthesize → deliver. **Stages may be iterative (see Iterative Convergence).** The lead decides what stages are needed and in what order.

#### Planning

Research enough to write well-scoped prompts — skim files (structure, function names, imports, sizes), understand project layout, identify the right agents. Don't trace logic chains or do deep analysis — that's agent work. If the project is unfamiliar, spawn a research agent first. Decompose into stages. Brief user before spawning:
```
Plan: [N stages, M total agents]
  Stage 1: [purpose] — [agents] → delivers [what]
  Stage 2: [purpose] — [agents] → delivers [what] [iterative] (discretionary)
  Stage 3: [purpose] — uses Stage 2 output → delivers [what] [iterative] (mandatory)
```
Iterative stages MUST be marked with `[iterative]` in the brief. Mark `(mandatory)` vs `(discretionary)`. Do not wait for the user to ask.

Write full plan to `tmp/glm-plan.md`. Checkpoint.

Single-stage when all agents can work independently. Multi-stage when later work depends on earlier results or agents would need 30+ turns.

**Session start:** Clean stale GLM artifacts: `rm -f tmp/glm-plan.md tmp/stage-*-{checklist,synthesis}.md tmp/stage-*-iter-*-synthesis.md`

**Scoping pass:** When the change scope is unclear, the lead may spawn 1-2 lightweight agents before writing the formal plan. Scoping agents use `-scope` suffix (e.g., `s1-scope-review`). Their findings inform the plan but MUST be verified before any fixes are applied (see Verification hard rules). Write the formal plan after the scoping pass completes.

**Session boundaries:** If task will likely need >4 stages, plan explicit session splits using the continuation protocol. Long sessions degrade from compaction pressure.

#### Agent Preparation

For each agent in the current stage:

1. Define task with KEY FILES, CONTEXT, SCOPE, and 3-5 `MUST ANSWER:` questions (mandatory — prompts without these are invalid)
2. Read `.claude/agents/{agent}.md`, trim to task-relevant sections (see Prompts rule below), build prompt per Agent Prompt Template
3. Append boilerplate from `.claude/templates/`: quality rules (review or code variant), severity guide (review only), coordination + report format (review or code variant). Replace `{NAME}` placeholder in coordination template
4. Write to `tmp/{name}-prompt.txt`
5. **Validate prompt contains ALL:** trimmed agent .md, TASK ASSIGNMENT with MUST ANSWER questions, quality rules, severity guide (review only), environment (code only), coordination, report format. Missing ANY = do not spawn
6. Match agent type to task: REVIEW → code-reviewer, security-reviewer, architect. CODE → language-pro, debugger

Describe problems and desired behavior — do NOT paste exact fix code unless precision is critical (regex, API signatures, security logic). Name agents with stage prefix: `s1-researcher`, `s2-impl-auth`.

#### Execution

1. Spawn all agents via `spawn-glm.sh`. If stdout is empty (Windows `.cmd` issue), read `tmp/{NAME}-status.txt` to get PID. Checkpoint with PIDs and names
2. Do verification prep (pre-read key files for spot-checks)
3. `wait-glm.sh name1:$PID1 name2:$PID2 ...` — first progress at 30s, then every 60s, STALLED warnings, health check on finish
4. **Review output.** If ANY agent shows STALLED / EMPTY LOG / MISSING REPORT / EMPTY REPORT:
   - STALLED: kill the process (`kill PID`), read log to diagnose
   - EMPTY/MISSING: read the agent's log file to diagnose failure
   - Decide: respawn the agent OR note the gap and proceed
   - Do NOT silently skip failed agents — every failure must be explicitly addressed

#### Verification

The most critical step. **Every finding must be verified — no exceptions.**

**a) Read reports one at a time.** For each report, spot-check 3 findings first (read cited files, compare claims). If 2+ fail: mark report SUSPECT — verify only HIGH/CRITICAL findings individually, skip LOW/MEDIUM, note in checklist. Reports marked SUSPECT may still contain valuable findings at higher severities.

**b) Build checklist** at `tmp/stage-N-checklist.md` (MUST be on disk). Initialize from agent Findings tables — copy rows, add verification columns:
```
| # | Agent | Severity | File:Line | Description | Read? | Match? | Label |
|---|-------|----------|-----------|-------------|-------|--------|-------|
```

**c) For EVERY finding:**
1. **Read** the cited file:line (MANDATORY — no Read = invalid label)
2. **Compare** to agent's claim (YES/NO/PARTIAL)
3. **Assess** — LOW/MEDIUM: visual confirmation. HIGH/CRITICAL: trace callers to prove reachable
4. **Label:** VERIFIED / REJECTED (reason) / DOWNGRADED (correct severity) / UNABLE TO VERIFY
5. **Update** checklist on disk. Checkpoint every ~5 findings

**Hard rules:**
- A finding labeled without a Read tool call is INVALID
- 100% labeled before proceeding — no unlabeled findings
- If >30% rejected → flag report as unreliable
- After compaction during verification: first action = read checklist, continue from first unlabeled row
- No fixes without verification — even from scoping passes or informal agent runs. Every finding the lead acts on must have a Read-backed label first
- Valid labels are ONLY: VERIFIED / REJECTED (reason) / DOWNGRADED (correct severity) / UNABLE TO VERIFY. No other labels (e.g., "PLAUSIBLE", "NOT VERIFIED") are permitted

**d) Fix ALL verified actionable findings** regardless of severity. Deduplicate across agents. Don't defer fixable issues.

#### Between Stages

1. Write `tmp/stage-N-synthesis.md` — verified results, decisions, context for next stage
2. If scope changed from original plan, update `tmp/glm-plan.md` with actual stages and revised goals
3. Checkpoint. Clean up: `rm -f tmp/sN-*-prompt.txt`
4. Next stage prompts include synthesis as `PRIOR CONTEXT:` section
5. Never re-do verified work unless evidence shows it was wrong

**Iterative stages:** Between iterations, follow the Iterative Convergence protocol below — skip steps 1-5 until convergence is reached. On convergence, write final stage synthesis (step 1) and resume normal between-stages flow (steps 2-5).

#### Iterative Convergence

Some stages benefit from repeated runs until agents stop producing new meaningful output. What counts as "new output" depends on the stage purpose — new problems (audit), new information (research), new improvements (analysis), new risks (security), etc. The lead judges.

**When mandatory:** Final/critical stages — production checks, final audits, final quality gates. These MUST iterate to convergence.

**When lead decides:** Research, discovery, security audits, or any stage where missing something has high cost. The lead evaluates whether the domain and stakes warrant iteration.

**Usually not needed:** Implementation, simple context-gathering, one-off transformations.

**Mechanics:**
1. Each iteration = full prepare → spawn → verify cycle
2. After verification, assess: was new meaningful output produced?
   - **Yes** → write iteration synthesis to `tmp/stage-N-iter-K-synthesis.md`, prepare next iteration with cumulative context from all prior iterations
   - **No** → increment empty counter
3. Convergence = 2 consecutive iterations with no new meaningful output. Write final stage synthesis and move on
4. Lead SHOULD vary approach between iterations — different agents, focus areas, or angles — to avoid blind spots. Running identical agents repeatedly is wasteful
5. Lead can adjust agent count and type between iterations based on what prior iterations revealed
6. Lead sets max iterations per stage (default 5). If cap hit without convergence → synthesize what's known, note "convergence not reached" in delivery, proceed
7. **Mandatory convergence is mechanical, not discretionary.** Mandatory iterative stages CANNOT be declared converged after a single iteration, regardless of lead assessment. An iteration that produces ANY actionable finding is not empty — fix the issue, then run the next iteration. Only 2 consecutive empty iterations satisfy convergence

#### Delivery

After final stage:
- **Reviews/audits:** write report to `tmp/` with verified findings, rejected items, gaps
- **Code changes:** run build + tests as final smoke test (if failures, spawn fix-agent)
- **Research/analysis:** synthesize into clear summary
- Write `tmp/session-summary.md`: task goal, stages executed, total agents, iterations per iterative stage, verification stats, key decisions, phase durations (planning, preparation, execution/wait, verification, synthesis)
- Cleanup: `rm -f tmp/*-prompt.txt`. Keep logs, reports, summary
- Save workflow lessons to knowledge if applicable

### Agent Prompt Template

Prompt = trimmed agent `.md` + task-specific sections + boilerplate from templates:

```
You are a GLM agent named {NAME}.

IMPORTANT: Think deeply and verify rigorously. For every finding or action, invest your reasoning in PROVING it correct — trace logic step by step, verify assumptions against actual code, search for existing guards before claiming they're missing. Depth of verification matters more than number of findings. One well-proven finding is worth more than ten unverified ones.

{Task-relevant sections of .claude/agents/{agent}.md — see Prompts rule}

--- TASK ASSIGNMENT ---

PROJECT: {working directory and project description}

ENVIRONMENT (code tasks only):
{Runtime, test command, lint command}

PRIOR CONTEXT (stage 2+ or iteration 2+):
{Contents of tmp/stage-N-synthesis.md OR cumulative tmp/stage-N-iter-*-synthesis.md for iterations}

YOUR TASK: {KEY FILES, CONTEXT, SCOPE, MUST ANSWER questions}

{cat .claude/templates/quality-rules-review.txt OR quality-rules-code.txt}

{cat .claude/templates/severity-guide.txt — REVIEW/audit tasks only}

{cat .claude/templates/coordination-review.txt OR coordination-code.txt — replace {NAME}}
```

| Task Type | Quality Rules | Severity Guide | Coordination |
|-----------|--------------|----------------|--------------|
| Review/audit | quality-rules-review.txt | severity-guide.txt | coordination-review.txt |
| Code/refactor | quality-rules-code.txt | — | coordination-code.txt |
| Research | quality-rules-review.txt | — | coordination-review.txt |

Boilerplate templates live in `.claude/templates/`. Lead only writes the unique parts (agent .md selection + TASK ASSIGNMENT). Templates are `cat`-ed into the prompt file verbatim.

### Checkpoints & Recovery

**Save after every significant step.** One active checkpoint (delete previous first). Under 500 chars.

```bash
memory.sh session add context "CHECKPOINT: [task] | DONE: [steps] | NEXT: [remaining] | FILES: [key files] | BUILD/TEST: [commands]"
```

**Compaction recovery — MANDATORY sequence (do ALL steps, no skipping):**
1. `memory.sh session show` — restore session state
2. **Re-read CLAUDE.md Opus-GLM section** — ALWAYS. Phase-aware scope:
   - Planning/preparation: full section (## Opus-GLM through ### Rules)
   - Verification: through #### Delivery + ### Error Handling + ### Rules — skip prompt template/quality rules
   - Synthesis/delivery: through #### Delivery + ### Checkpoints through ### Rules — skip prompt template/quality rules
3. Read `tmp/glm-plan.md` — restore current plan
4. Read the latest `tmp/stage-N-checklist.md`, `tmp/stage-N-iter-K-synthesis.md`, or `tmp/stage-N-synthesis.md` — restore verification/iteration/stage state
5. Only then resume work

Do not rely on continuation summary alone. Do not skip step 2 — this is the #1 cause of workflow deviation after compaction.

| Checkpoint | Recovery |
|-----------|----------|
| Plan done | Read `tmp/glm-plan.md` → prepare agents |
| Agents prepared | List prompts → spawn |
| Agents spawned | Check PIDs/reports → verify or re-wait |
| Verifying stage N | Read `tmp/stage-N-checklist.md` → first unlabeled row |
| Iterating stage N, iter K | Read `tmp/stage-N-iter-K-synthesis.md` + cumulative context → prepare next iteration |
| Stage N done | Read synthesis + plan → next stage |

### Session Continuation

For tasks exceeding a single session:

1. Complete current stage fully
2. Write `tmp/glm-continuation.md`: original task, plan, completed stages, next stage, decisions, modified files, blockers
3. `memory.sh add context "GLM-CONTINUATION: [summary]" --tags opus-glm,continuation`
4. Tell user what's done and what continues

**Pickup:** `memory.sh search "GLM-CONTINUATION"` → read continuation file → read prior synthesis → continue next stage. On final stage, clean up continuation file and memory entry. Never re-do verified prior work.

### Error Handling

| Scenario | Action |
|----------|--------|
| No report after exit | Read log, note gap, fill critical items only |
| >30% false claims | Flag unreliable, rely on own verification |
| STALLED (flagged by wait-glm.sh) | Kill process, read log to diagnose, respawn or note gap |
| Agent claims success but output wrong | Flag report SUSPECT, verify independently |
| Zero issues on substantial task | Spot-check 2-3 key areas |
| Incorrect edits | Revert and fix directly |
| 2+ agents fail same env error | STOP respawning. Diagnose environment first |
| Iteration cap hit without convergence | Synthesize all iterations, note "convergence not reached" in delivery, proceed |

### Rules

**Limits:** Max 3 agents per stage (per iteration for iterative stages). Agents run until done (no turn limit). One task per agent. Respawn naming: `-r2`, `-r3`. No two agents edit same file per iteration (read overlap OK). Balance workload — each agent should cover roughly equal scope. **Iteration naming:** `s2i1-reviewer`, `s2i2-researcher` (stage 2, iteration 1/2). Respawn within iteration: `s2i1-reviewer-r2`.

**Prompts:** Include task-relevant sections of agent `.md` — skip sections that don't help with the specific task. Always keep: frontmatter, identity/focus sections, approach/workflow, safety patterns, common pitfalls. Skip when irrelevant: CI/CD, observability/logging, essential tools, dependency management, documentation standards, output sections, diagnostic/analysis commands. Lead decides per-task — if a section wouldn't help the agent do THIS task, skip it. Boilerplate (quality rules, severity guide, coordination, report format) comes from `.claude/templates/`. Agents don't load CLAUDE.md — all context must be in prompt.

**Verification:** Every finding labeled. Every label backed by Read. 100% complete before proceeding. ALL verified actionable findings fixed — via fix-agent if many, directly if few.

**Platform:** Windows: `claude-glm.cmd`; macOS/Linux: `claude-glm` (spawn-glm.sh handles this). Always redirect output to log files.

---

## Web Research

For any internet search:

1. Read agent instructions: `.claude/agents/web-searcher.md`
2. **ALWAYS** use `./.claude/tools/web_search.sh "query"` (or `.claude/tools/web_search.bat` on Windows). **NEVER use the built-in WebSearch tool** — all searches must go through the custom tool
   - **Multiple queries: combine into one call** — `web_search.sh "query1" "query2" "query3" -s 10` (parallel, cross-query URL dedup)
   - **Scientific queries: ALWAYS add `--sci`** for CS, physics, math, engineering, materials science, astronomy, or any non-medical academic topic. Enables: arXiv + OpenAlex.
   - **Medical queries: ALWAYS add `--med`** for medicine, clinical trials, pharmacology, biomedical, genetics, neuroscience, epidemiology, or any health/life science topic. Enables: PubMed + Europe PMC + OpenAlex.
   - **Tech queries: ALWAYS add `--tech`** for software development, DevOps, IT infrastructure, programming, startups, or any tech industry topic. Enables: Hacker News + Stack Overflow + Dev.to + GitHub.
   - **Both flags together (`--sci --med`)** for interdisciplinary queries (e.g., computational biology, bioinformatics, medical imaging AI). Use both when the topic spans science AND medicine.
   - **MANDATORY**: These flags MUST be used for ALL queries matching the above descriptions. Never omit them for relevant queries. When in doubt, add the flag — it never hurts.
3. Synthesize results into a report

**Note**: Always use forward slashes (`/`) in paths for agent tool run, even on Windows.
Dependencies handled automatically via uv.

---

## Memory System

Two-tier: **Knowledge** (`knowledge.md`) permanent, **Session** (`session.md`) temporary.

| Question | Use |
|----------|-----|
| Will this help in future sessions? | **Knowledge** |
| Current task only? | **Session** |
| Discovered a gotcha/pattern/config? | **Knowledge** |
| Tracking todos/progress/blockers? | **Session** |

### Knowledge

```bash
memory.sh add <category> "<content>" [--tags a,b,c]
```

| Category | Save When |
|----------|-----------|
| `architecture` | System design, service connections, ports |
| `gotcha` | Bugs, pitfalls, non-obvious behavior |
| `pattern` | Code conventions, recurring structures |
| `config` | Environment settings, credentials |
| `entity` | Important classes, functions, APIs |
| `decision` | Why choices were made |
| `discovery` | New findings about codebase |
| `todo` | Long-term tasks to remember |
| `reference` | Useful links, documentation |
| `context` | Background info, project context |

**Tags:** Cross-cutting concerns (e.g., `--tags redis,production,auth`). **Skip:** Trivial, easily grep-able, duplicates.

**After tasks:** State "**Memories saved:** [list]" or "**Memories saved:** None"

**Other:** `search "<query>"`, `list [--category CAT]`, `delete <id>`, `stats`

### Session

Tracks current task. Persists until cleared.

**Categories:** `plan`, `todo`, `progress`, `note`, `context`, `decision`, `blocker`. **Statuses:** `pending` → `in_progress` → `completed` | `blocked`.

```bash
memory.sh session add todo "Task" --status pending
memory.sh session show                    # View current
memory.sh session update <id> --status completed
memory.sh session delete <id>
memory.sh session clear                   # Current only
memory.sh session clear --all             # ALL sessions
```

### Checkpoints

Save after every significant step. One active checkpoint (delete previous first). Under 500 chars. Opus-GLM sessions: use the checkpoint protocol in the Opus-GLM section.

After compaction: run `memory.sh session show` immediately to restore state. One checkpoint at a time. Always include DONE and NEXT.

### Multi-Session

Multiple CLI instances work without conflicts. Resolution: `-S` flag > `MEMORY_SESSION` env > `.claude/current_session` file > `"default"`.

```bash
memory.sh session use feature-auth        # Switch session
memory.sh -S other session add todo "..." # One-off
memory.sh session sessions                # List all
```

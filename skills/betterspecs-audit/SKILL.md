---
name: betterspecs-audit
description: Audit an RSpec suite against the betterspecs.org guidelines and write a report of verified findings. A bundled parser (Prism, no gems) covers the mechanical rules, and a reading pass covers the rest (missing edge cases, unneeded data, over-mocking, duplication). Use when asked to "run betterspecs", "audit our specs", "check spec quality", "rspec best practices review", or to compare a suite's rubocop-rspec config with betterspecs.
allowed-tools: Read, Glob, Grep, Bash, Write, Agent
---

# Betterspecs audit

Audit a suite against <https://www.betterspecs.org>. The output is a report. You do not rewrite specs unless the user asks for that separately.

Some guidelines can be checked by a parser, so `scripts/betterspecs_audit.rb` (in this skill's directory) handles them. The rest need a reader who has the source file open, so you handle those. Keep the two apart in the report. A script count is a lead to check. It is not a verdict until you have looked.

`references/guidelines.md` holds, for each guideline, what betterspecs says, how current practice has moved on, which rule ids and rubocop-rspec cops cover it, what to look for while reading, and a before/after fix. Read the section for a guideline before you write a finding under it.

## 1. Run the parser

```bash
ruby <skill-dir>/scripts/betterspecs_audit.rb --root <project> --rubocop --limit 8 > /tmp/betterspecs.md
ruby <skill-dir>/scripts/betterspecs_audit.rb --root <project> --format json > /tmp/betterspecs.json
```

- It needs Ruby ≥ 3.3, which ships Prism. On older Rubies, run `gem install prism` first. Nothing gets loaded from the app, so it runs in seconds on thousands of specs.
- `--rubocop` runs `bundle exec rubocop --show-cops` and reports every betterspecs-mapped cop that the project has disabled or relaxed (for example `RSpec/LetSetup: Enabled: false`). Leave the flag off when the project doesn't use rubocop-rspec.
- `--rules` lists the rule ids. `--only`/`--except` narrow the run. `--max-description`, `--context-prefixes` and `--max-list` tune the thresholds.
- A spec line can opt out with `# betterspecs:disable <rule-id>` (or `all`).
- The JSON includes every finding. The markdown shows the first `--limit` findings per rule.

Rule ids map to guidelines as follows:

| Guideline | Rule ids | Nature |
|---|---|---|
| Describe your methods | `describe-method` | heuristic: snake_case describe that `app/`/`lib/` defines as a method |
| Use contexts | `describe-as-context`, `context-wording`, `description-conditional` | exact wording checks |
| Keep your description short | `description-length` | exact (40 chars) |
| Single expectation | `multiple-expectations` | exact, isolated spec dirs only, honours `:aggregate_failures` |
| Test all possible cases | `happy-path-only` | **candidate**: read it |
| Expect vs should | `should-syntax`, `expect-syntax-not-enforced` | exact |
| Use subject | `missing-subject` | **candidate** (same construction repeated ≥ 3×) |
| Use let and let! | `instance-variable`, `unreferenced-let-bang` | exact (skips groups that include shared examples) |
| Mock or not to mock | `any-instance`, `stubbed-subject`, `message-chain`, `stubbed-persistence` | exact / **candidate** |
| Create only the data you need | `large-data` | **candidate** (threshold) |
| Factories, not fixtures | `fixtures`, `raw-create` | exact / heuristic |
| Easy to read matchers | `weak-matcher`, `lambda-expectation` | exact, with a suggested rewrite |
| Shared examples | `duplicate-example` | **candidate** (identical bodies, ≥ 3 copies) |
| Test what you see | `controller-spec` | exact |
| Don't use should | `should-wording` | exact |
| Stubbing HTTP | `http-not-blocked` | config-level |
| Continuous testing / faster tests / formatter | `tooling` section | facts only, not findings |

## 2. Verify before you count

For every rule with findings, open at least three of them at random, plus every finding when a rule has fewer than ten, and read the lines around them. Sort each one into:

- **true**: betterspecs would ask for the change.
- **false positive**: the heuristic misread the code. Note the shape, e.g. "describe names an analytics event, not a method".
- **deliberate**: the project chose otherwise, and its config or docs say so, e.g. rubocop `MultipleExpectations: Max: 5`.

Report each rule's count together with its false-positive rate. If a rule is mostly false positives, give its count as "n flagged, mostly X-shaped, not actionable" and don't rank it. Known false-positive shapes for each rule are listed in `references/guidelines.md`.

## 3. Read what the parser cannot decide

Read these by hand. With more than ~150 spec files, fan the reading out with the Agent tool: one agent per spec directory (`models`, `requests`, `system`, `jobs`, …), each given this section, `references/guidelines.md`, the directory's hotspot files and a stratified random sample (≈ 8 files, or all of them if there are fewer). Every agent returns findings with `file:line`, the guideline, and a one-line fix. Nothing gets reported without an anchor.

For each file you read, open the source it tests, too.

1. **All possible cases** (`#all`). List the inputs and branches in the source method or action: not found, not owned or unauthorized, invalid params, boundaries (0, 1, max, nil, empty), and state-machine edges. Name each one the spec never exercises. Start with the `happy-path-only` candidates, but don't stop there, because a group with ten contexts can still skip the "not owned" branch.
2. **Create only the data you need** (`#data`). Look for `create` where `build`/`build_stubbed` would do because the example never touches the database. Look for factories whose defaults create associations nobody reads, `let!` chains that build a whole graph for one attribute, and loops that create records to test a count of two.
3. **Mock or not to mock** (`#mock`). Look for stubs on the app's own code (a service, a model method) where the real object would run in milliseconds, for `expect(...).to receive` that pins the implementation instead of an outcome, and for doubles of classes the app owns. Stubbing external HTTP, time or randomness is fine.
4. **Use subject** (`#subject`). Check the `missing-subject` candidates, and also look for the same `described_class.new(...)`/`perform` call repeated across examples with arguments that only vary through `let`.
5. **Shared examples** (`#shared`). Look for behavior repeated across files: auth redirects, 404-on-foreign-record, pagination, JSON error shapes. A text diff doesn't catch these because every copy is worded differently. Check whether `spec/shared_examples` or `spec/support` already has one that nobody uses.
6. **Test what you see** (`#integration`). Check whether request specs assert on what the user gets (status, body, redirect, flash) or on internals (instance variables, private calls), and whether the key flows have a system spec.

## 4. Write the report

Save it where the project keeps docs (`docs/audits/betterspecs-<YYYY-MM-DD>.md` if nothing else fits), unless the user names a place. Structure:

1. **Verdict**: two or three sentences on overall health and the one change that would help most.
2. **Scorecard**: one row per guideline with status (✅ follows / ⚠️ partly / ❌ violates / ➖ deliberately diverges), verified count, false-positive rate, and a pointer.
3. **Config gaps**: rubocop cops the project relaxed and RSpec config holes (expect-only syntax, net connect). These are the cheapest fixes, so list them first.
4. **Findings per guideline**: verified findings with `file:line`, a before/after for the pattern, and the candidate list that still needs a decision.
5. **Deliberate divergences**: places where the project goes against betterspecs on purpose, e.g. descriptive `it` sentences longer than 40 characters. Cite the config or doc that makes it deliberate. The recommendation there is "keep, or change the policy", not "fix 4 000 lines".
6. **Recommended actions**: ranked by value ÷ effort, each sized (one-line config, mechanical sweep, or per-file judgment), each saying how it would be enforced afterwards (cop, script `--fail-on`, or review checklist).
7. **Method**: the script version and command, what was sampled, and how many files were read by hand.

Rules for the report:

- Every number traces back to a command or to a list of files you read.
- Label each finding with how it was found: script-exact, script-heuristic, or read. Don't blur them.
- Flag guidelines that have aged (40-character descriptions, Spork/Zeus, Guard) as dated in the scorecard instead of counting them as failures. `references/guidelines.md` explains how each one has moved on.
- Don't pad. If the suite already follows a guideline, one ✅ line is enough.

## 5. Only if asked: fix

Fixing is a separate task with its own scope. When the user asks for it, go one rule at a time. Config gaps come first. Then do the mechanical sweeps (`weak-matcher` suggestions, `describe-as-context`, `unreferenced-let-bang` → `before`), and after each one re-run the script with `--only <rule>` and run the touched specs. Never mix a style sweep with behavior changes in the same commit.

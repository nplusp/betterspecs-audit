# betterspecs-audit

An agent skill that audits an RSpec suite against [betterspecs.org](https://www.betterspecs.org) and writes a report you can act on.

Half of betterspecs can be checked mechanically: `should` syntax, context wording, instance variables in `before`, `lambda` in `expect`. The other half needs a reader: whether every branch has a test, whether a spec creates more data than it needs, whether a mock replaces something that should run for real. The skill handles both halves separately:

1. **A parser.** [`betterspecs_audit.rb`](skills/betterspecs-audit/scripts/betterspecs_audit.rb) walks every spec with Prism and reports 25 rules, each tied to a betterspecs guideline. It needs no gems and doesn't boot the app. It audits 500 spec files / 7 000 examples in about 2 seconds.
2. **A reading pass.** [`SKILL.md`](skills/betterspecs-audit/SKILL.md) has the agent check samples of the parser's findings for false positives. It then reads the specs and their source for the judgment guidelines, and writes a report where every finding has a `file:line` and says how it was found.

```
$ ruby skills/betterspecs-audit/scripts/betterspecs_audit.rb --root test/fixtures/bad --only weak-matcher,unreferenced-let-bang
## `unreferenced-let-bang` — `let!` that no example reads; it is setup, say so with `before` (1)

- `spec/models/user_spec.rb:69` let!(:inactive) is never read — replace with `before { … }` so the intent is visible

## `weak-matcher` — Boolean assertion where a readable matcher exists (5)

- `spec/models/user_spec.rb:25` `expect(build(:user, :admin).admin?).to be(true)` — `expect(build(:user, :admin)).to be_admin`
- `spec/models/user_spec.rb:30` `expect(build(:user).admin?).to be_falsey` — `expect(build(:user)).not_to be_admin`
- `spec/models/user_spec.rb:116` `expect(build(:user).tags.count).to eq(0)` — `expect(build(:user).tags).to be_empty`
```

## Install

**Claude Code plugin**

```
/plugin marketplace add nplusp/betterspecs-audit
/plugin install betterspecs-audit@betterspecs-audit
```

**Any agent that reads `SKILL.md`** (Claude Code, Codex, Cursor, …), via [skills](https://github.com/vercel-labs/skills):

```bash
npx skills add nplusp/betterspecs-audit
```

**By hand:** copy `skills/betterspecs-audit/` into `~/.claude/skills/` (or your project's `.claude/skills/`).

Then ask: *"run betterspecs over our specs"*.

## Use the parser on its own

Requires Ruby ≥ 3.3 (tested on 3.3, 3.4 and 4.0).

```bash
ruby skills/betterspecs-audit/scripts/betterspecs_audit.rb                    # markdown report of ./spec
ruby skills/betterspecs-audit/scripts/betterspecs_audit.rb --format json      # every finding, machine-readable
ruby skills/betterspecs-audit/scripts/betterspecs_audit.rb --rubocop          # + rubocop-rspec cops you relaxed vs betterspecs
ruby skills/betterspecs-audit/scripts/betterspecs_audit.rb spec/models        # a subset
ruby skills/betterspecs-audit/scripts/betterspecs_audit.rb --rules            # list rule ids
```

| Option | Default | |
|---|---|---|
| `--root DIR` | cwd | project root |
| `--format markdown\|json` | markdown | |
| `--only` / `--except LIST` | | rule ids, comma-separated |
| `--max-description N` | 40 | example description length |
| `--context-prefixes LIST` | when,with,without | |
| `--max-list N` | 10 | `create_list` / `N.times { create }` threshold |
| `--fail-on never\|info\|warning\|error` | never | exit 1 at or above this severity, for CI |
| `--rubocop` | off | compare `bundle exec rubocop --show-cops` with betterspecs |

To silence a line, add `# betterspecs:disable rule-id` (or `all`) to it.

In CI, gate on the rules that have no false positives:

```bash
ruby betterspecs_audit.rb --only should-syntax,lambda-expectation,instance-variable,fixtures,http-not-blocked --fail-on error
```

## Rules

| Guideline | Rules |
|---|---|
| [Describe your methods](https://www.betterspecs.org/#describe) | `describe-method` |
| [Use contexts](https://www.betterspecs.org/#contexts) | `describe-as-context` `context-wording` `description-conditional` |
| [Keep your description short](https://www.betterspecs.org/#short) | `description-length` |
| [Single expectation](https://www.betterspecs.org/#single) | `multiple-expectations` (isolated specs only; honours `:aggregate_failures`) |
| [Test all possible cases](https://www.betterspecs.org/#all) | `happy-path-only` (candidate) |
| [Expect vs should](https://www.betterspecs.org/#expect) | `should-syntax` `expect-syntax-not-enforced` |
| [Use subject](https://www.betterspecs.org/#subject) | `missing-subject` (candidate) |
| [Use let and let!](https://www.betterspecs.org/#let) | `instance-variable` `unreferenced-let-bang` |
| [Mock or not to mock](https://www.betterspecs.org/#mock) | `any-instance` `stubbed-subject` `message-chain` `stubbed-persistence` (candidate) |
| [Create only the data you need](https://www.betterspecs.org/#data) | `large-data` |
| [Factories, not fixtures](https://www.betterspecs.org/#factories) | `fixtures` `raw-create` |
| [Easy to read matchers](https://www.betterspecs.org/#matchers) | `weak-matcher` (suggests the rewrite, polarity kept) `lambda-expectation` |
| [Shared examples](https://www.betterspecs.org/#shared) | `duplicate-example` (candidate) |
| [Test what you see](https://www.betterspecs.org/#integration) | `controller-spec` |
| [Don't use should](https://www.betterspecs.org/#should) | `should-wording` |
| [Stubbing HTTP](https://www.betterspecs.org/#stubbing) | `http-not-blocked` |

"Candidate" rules point the reading pass at a spot. They don't claim a violation. [`references/guidelines.md`](skills/betterspecs-audit/references/guidelines.md) covers each guideline: detection, known false-positive shapes, and a fix. It also says where betterspecs has aged: the 40-character limit, one expectation per example since `aggregate_failures`, and Spork/Guard.

### How it relates to rubocop-rspec

rubocop-rspec enforces style per file, and this skill doesn't replace it. It adds three things:

- rules rubocop-rspec has no cop for: description length, conditions in `it`, `describe "when …"`, `weak-matcher` with `be(true)`, and cross-file duplicates;
- `--rubocop` drift, which lists the betterspecs-mapped cops your config has relaxed, e.g. `LetSetup: Enabled: false`;
- the reading pass, which no linter can do.

## Development

```bash
ruby test/betterspecs_audit_test.rb
```

`test/fixtures/bad` marks each line that should be reported with `# expect: rule-id`. The main test asserts that the parser reports exactly those lines, and that every rule has at least one marked line. `test/fixtures/clean` is a tricky but compliant suite (spies, `aggregate_failures`, shared-example includes, `stub_request`, predicate calls with arguments), and it must report nothing. To add a rule, mark a violation in `bad`, add a near-miss to `clean`, and then write the code.

## License

MIT

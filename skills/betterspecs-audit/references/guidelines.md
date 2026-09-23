# Betterspecs guidelines: detection and fixes

One section per guideline on <https://www.betterspecs.org>, in site order. Each section has:

- **Says**: the guideline.
- **Today**: how current practice has moved on, if it has.
- **Detect**: the rule ids and cops that cover it.
- **Read for**: what to look for by hand.
- **False positives**: known shapes that fool the parser.
- **Fix**: a before/after.

---

## Describe your methods: `#describe`

**Says:** describe a method as `.class_method` / `#instance_method`, not in prose ("the authenticate method").

**Detect:** `describe-method` flags a nested `describe` inside a class spec whose text is a bare snake_case name (`"full_name"`) that some `def` in `app/` or `lib/` defines, or whose text mentions "method". Cop: `RSpec/DescribeMethod` checks only the second argument of the top-level describe, so it misses nested ones.

**False positives:** mostly filtered out by the `def` lookup: analytics event names (`"listing_expired"`) and columns aren't `def`s. Gems without `app/`/`lib/` skip the lookup and flag every snake_case describe.

**Fix:**
```ruby
describe "full_name" do       # →  describe "#full_name" do
describe "the authenticate method for User" do  # →  describe ".authenticate" do
```

## Use contexts: `#contexts`

**Says:** put conditions in a `context` whose description starts with *when*, *with* or *without*. Don't bury them in the `it` description.

**Detect:**
- `context-wording`: a context that doesn't start with an allowed prefix. Configure with `--context-prefixes`. Cop: `RSpec/ContextWording`.
- `describe-as-context`: a `describe "when …"`, which should be a `context`. No cop covers it.
- `description-conditional`: an `it "… when/if/unless …"`. No cop covers it. Skipped in `spec/system` and `spec/features`, where "when" usually names the user's action inside the example ("closes when you press Escape").

**Read for:** sibling examples that differ only by their condition clause. Those are two contexts waiting to be split out.

**False positives:** "when" used as a time word ("stamps the time when shipped"). These are rare.

**Fix:**
```ruby
it "returns 403 when the requester is not the author" do
# →
context "when the requester is not the author" do
  it { is_expected.to have_http_status(:forbidden) }
end
```

## Keep your description short: `#short`

**Says:** 40 characters at most. If it's longer, split it with a context.

**Today:** this is dated as a hard rule. rubocop-rspec has no length cop, and the RSpec style guide doesn't set a limit. Many strong suites use full sentences on purpose, because documentation-format output reads as a spec. Treat the limit as a smell detector: descriptions over ~60 characters that contain "when/and/if" usually hide a context or a second behavior. Report a suite-wide pattern as a **deliberate divergence** when the project's style is plainly sentence-like, not as 4 000 violations.

**Detect:** `description-length`, tuned with `--max-description`. Cross it with `description-conditional`, because a long description with a condition in it is the actionable subset.

## Single expectation test: `#single`

**Says:** in isolated unit specs, one expectation per example. In slow, non-isolated specs (DB, HTTP, end-to-end), several are fine.

**Today:** since RSpec 3.3, `:aggregate_failures` reports every failed expectation, which removes the original "you only see the first failure" cost. Several expectations about **one behavior** under `aggregate_failures` are accepted practice. Several **behaviors** in one example are still the smell.

**Detect:** `multiple-expectations` looks only at isolated directories (`models lib helpers services policies …`). It honours `:aggregate_failures` metadata, `aggregate_failures do` blocks, and suite-wide `define_derived_metadata`. Cop: `RSpec/MultipleExpectations`, whose `Max` betterspecs reads as 1.

**Read for:** examples whose expectations test different things (the return value *and* a side effect *and* a log line). Split those. Keep the ones that check several facets of one result and tag them `:aggregate_failures`.

## Test all possible cases: `#all`

**Says:** test the valid case, the edge cases and the invalid case. A `destroy` has at least three: found, not found, not owned.

**Detect:** `happy-path-only` is a **candidate** list only. It flags a `#method` / `.method` / `VERB /path` group with no nested context, where neither the group nor any example sounds like a failure path. Sibling groups for the same method count, so `"#fetch — happy path"` next to `"#fetch — errors"` passes.

**False positives:** failure paths worded neutrally ("renders the form again"), branchless one-liners, table-driven specs.

**Read for:** open the source and enumerate the inputs and branches:
- lookup: found / not found / found but not owned
- auth: signed out / wrong role / suspended
- params: valid / invalid / missing / extra
- values: nil, empty, 0, 1, max, negative, unicode, very long
- state machines: every transition from every state, including the illegal ones
- time: expiry boundaries, time zones

Each branch with no example is a finding. Anchor it at the describe line and name the source line of the branch.

## Expect vs should syntax: `#expect`

**Says:** always use `expect(...)`, use `is_expected.to` for one-liners, and set the config so only the new syntax is accepted.

**Detect:** `should-syntax` finds `obj.should`, `obj.stub`, `should_receive`, `Klass.any_instance`, and implicit `it { should … }`. `expect-syntax-not-enforced` means no `syntax = :expect` or `disable_monkey_patching!` was found in `.rspec` / `spec_helper` / `rails_helper` / `spec/support`. Cop: `RSpec/ImplicitExpect` (`EnforcedStyle: is_expected`).

**Fix:**
```ruby
# spec/spec_helper.rb
config.expect_with(:rspec) { |c| c.syntax = :expect }
config.mock_with(:rspec) { |m| m.syntax = :expect }
# or, stricter: config.disable_monkey_patching!
```

## Use subject: `#subject`

**Says:** when several examples use the same subject, declare it once with `subject` (named if it helps).

**Detect:** `missing-subject` is a **candidate**. It fires when 3 or more direct examples of a group repeat the **same** `described_class.new(...)` / `Constant.new(...)` (whitespace ignored) and no subject is in scope. Validation specs, which build a differently-invalid object each time, don't trigger it. Cop: `RSpec/NamedSubject` covers a different case (use the name, not `subject`).

**Read for:** constructions that differ only in arguments. Those become `subject(:component) { described_class.new(label:, url:) }` plus a `let` for each context. For jobs, `described_class.new.perform(x)` repeated everywhere is true but low value; `subject(:perform)` is the tidy form.

## Use let and let!: `#let`

**Says:** use `let` rather than instance variables in `before`. Use `let!` only when the record has to exist before the example runs.

**Detect:**
- `instance-variable`: an ivar assigned inside an example group, outside `def`. Cop: `RSpec/InstanceVariable`.
- `unreferenced-let-bang`: a `let!` that nothing in its group reads. It exists only for its side effect, so `before { create(...) }` says that more honestly. Cop: `RSpec/LetSetup`. The rule skips groups that include shared examples, because they may read the name.

**False positives:** a `let!` read only by a helper module in `spec/support`, or by `instance_exec` / `send` with a dynamic name.

**Fix:**
```ruby
let!(:active_listing) { create(:listing, user:) }   # never referenced
# →
before { create(:listing, user:) }
```

## Mock or not to mock: `#mock`

**Says:** don't overuse mocks. Test real behavior when you can.

**Today:** the consensus is to stub at the **boundary** (external HTTP, clock, randomness, slow third-party SDKs) and run your own code for real. Prefer spies (`have_received`) over `expect().to receive` set up before the action, and verified doubles (`instance_double`) over plain `double`.

**Detect:**
- `any-instance`: `allow_any_instance_of` / `expect_any_instance_of`. Cop: `RSpec/AnyInstance`.
- `stubbed-subject`: `allow(subject).to receive`, the object under test being stubbed. Cop: `RSpec/SubjectStub`. Spies that call the original (`and_call_original`) are skipped.
- `message-chain`: `receive_message_chain`. Cop: `RSpec/MessageChain`.
- `stubbed-persistence` is a **candidate**: `allow(Model).to receive(:find_by|:where|:create!…)`, or `save!`/`update!`/`destroy!` stubbed on anything. Read it: often it simulates a DB failure, which is legitimate. Sometimes it replaces a record that would have been one `create` away.

**Read for:** stubs on the app's own classes, and on anything that isn't a boundary.

## Create only the data you need: `#data`

**Says:** don't load more data than the test needs. If you think you need dozens of records, you're probably wrong.

**Detect:** `large-data` is a **candidate**: `create_list(:x, N)` or `N.times { create … }` with N ≥ `--max-list` (default 10).

**False positives:** the count *is* the behavior, e.g. a rate limit of 10/min, a cap of 20, "9+" badges. Right when N = limit + 1. Wrong when a smaller limit could be set with `stub_const` (as in `stub_const("Digest::MAX", 2)` + 3 records).

**Read for:**
- `create` where `build` / `build_stubbed` would do because the example never queries
- factory defaults that create heavy associations (images, orders, users) the example never reads
- pagination tests that could lower the page size instead of creating `per_page + 1` records

## Use factories and not fixtures: `#factories`

**Says:** use factories, not fixtures. For pure domain logic, needing neither is better still.

**Detect:** `fixtures` fires on `fixtures :all`/`:users`. `raw-create` fires on `Model.create!(a:, b:, c:, …)` with 3 or more attributes in a spec, which is a hand-built record that a factory would keep minimal and valid.

**False positives:** tests of `create` itself, and third-party models without a factory (e.g. `PaperTrail::Version`, `SolidQueue::Job`). For those, suggest adding a factory; don't call it wrong.

## Easy to read matchers: `#matchers`

**Says:** use readable matchers. `expect { }.to raise_error`, not `lambda { }`.

**Detect:**
- `lambda-expectation`: `expect(lambda { … })` / `expect(-> { … })`.
- `weak-matcher`: a boolean assertion on an expression that has a matcher. The message suggests the exact rewrite with its polarity preserved:
  - `expect(a == b).to be(true)` → `expect(a).to eq(b)`
  - `expect(list.include?(x)).to be_truthy` → `expect(list).to include(x)`
  - `expect(x.empty?).to be(false)` → `expect(x).not_to be_empty`
  - `expect(user.admin?).to be_falsey` → `expect(user).not_to be_admin`
  - `expect(items.count).to eq(0)` → `expect(items).to be_empty` (collections only: a model class has `count` but no `empty?`, so `Order.count` is left alone)

  It skips predicates with arguments (`be_verify(raw_body: …)` reads worse), `can_/is_/should_…?` names (`be_can_sell`), safe navigation (`&.`, where the rewrite would drop nil-safety), predicates with a block (`any? { … }`, since `be_any` drops the block), calls with two or more arguments (`Proxies.include?(list, ip)` is a module function), and `key?` (non-Hash receivers such as Nokogiri nodes break `include`).

  Cop: `RSpec/PredicateMatcher`. Its default `Strict: true` ignores `be(true)`, so the script catches more.

**Why:** the readable matcher also fails with a readable message: "expected `user.admin?` to be falsey" instead of "expected true, got false".

## Shared examples: `#shared`

**Says:** use shared examples to DRY up behavior that repeats, mostly across endpoints.

**Detect:** `duplicate-example` is a **candidate**. It reports identical example bodies (normalized whitespace, ≥ 80 characters) found in 3 or more places.

**Read for:** the same behavior worded differently in each file: "redirects to sign in when signed out", "returns 404 for another user's record", pagination and JSON error shapes. Check `spec/shared_examples`/`spec/support` for existing groups nobody uses.

## Test what you see: `#integration`

**Says:** test models deeply, and test the application through integration (request/system) specs, not controller specs.

**Detect:** `controller-spec` fires on files under `spec/controllers` or tagged `type: :controller`, and on `assigns`/`render_template`/`assert_template`.

**Read for:** request specs that assert on internals instead of the response, and main user flows that have no system spec.

## Don't use should: `#should`

**Says:** write descriptions in the third person present tense: "does not change timings", not "should not change timings".

**Detect:** `should-wording` fires on descriptions that start with "should". A "should" inside a rationale ("…a human should look") is fine. Cop: `RSpec/ExampleWording`.

## Automatic tests with guard: `#continuous` · Faster tests: `#faster` · Formatter: `#formatter`

**Today:** these are dated. Spork and Zeus are dead. Guard is optional; editor test runners and `bin/rspec --only-failures` cover the same need. Rails boot time is solved with bootsnap and, for suites, `parallel_tests`/`turbo_tests`. A formatter is a preference. The script reports these as **tooling facts** (`.rspec`, Guardfile, parallel_tests, bootsnap, spring, webmock/vcr), never as findings. Mention a gap only if it hurts the team, e.g. a 20-minute suite with no parallelism.

## Stubbing HTTP requests: `#stubbing`

**Says:** never hit real external services. Stub them with WebMock or VCR.

**Detect:** `http-not-blocked` fires when no `webmock/rspec`, `disable_net_connect!` or `VCR.configure` appears in the spec support files, or when an `allow_net_connect!` re-opens the network.

**Read for:** `allow_localhost` or `allow:` lists broader than the test browser needs, and clients stubbed at the Ruby-method level instead of at HTTP (which misses serialization bugs).

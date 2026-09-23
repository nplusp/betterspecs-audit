#!/usr/bin/env ruby
# frozen_string_literal: true

# Audits an RSpec suite against https://www.betterspecs.org.
#
# Covers the guidelines a parser can decide. The ones that need a reader
# ("test all possible cases", "create only the data you need") come out as
# candidates for the skill's judgment pass, never as verdicts.
#
# Ruby >= 3.3 (Prism ships with it). No gems required.

require "json"
require "open3"
require "optparse"
require "prism"
require "yaml"

module BetterspecsAudit
  VERSION = "1.0.1"
  SITE = "https://www.betterspecs.org"

  GUIDELINES = {
    "describe" => "Describe your methods",
    "contexts" => "Use contexts",
    "short" => "Keep your description short",
    "single" => "Single expectation test",
    "all" => "Test all possible cases",
    "expect" => "Expect vs should syntax",
    "subject" => "Use subject",
    "let" => "Use let and let!",
    "mock" => "Mock or not to mock",
    "data" => "Create only the data you need",
    "factories" => "Use factories and not fixtures",
    "matchers" => "Easy to read matchers",
    "shared" => "Shared examples",
    "integration" => "Test what you see",
    "should" => "Don't use should",
    "stubbing" => "Stubbing HTTP requests"
  }.freeze

  Rule = Struct.new(:id, :guideline, :severity, :summary)

  RULES = [
    Rule.new(id: "describe-method", guideline: "describe", severity: "warning",
      summary: "Name the method under test: `describe '#name'` / `describe '.name'`"),
    Rule.new(id: "describe-as-context", guideline: "contexts", severity: "warning",
      summary: "A `describe` that states a condition is a `context`"),
    Rule.new(id: "context-wording", guideline: "contexts", severity: "warning",
      summary: "Start a context with when / with / without"),
    Rule.new(id: "description-conditional", guideline: "contexts", severity: "warning",
      summary: "An `it` that states a condition wants a `context` around it"),
    Rule.new(id: "description-length", guideline: "short", severity: "warning",
      summary: "Example description longer than the limit"),
    Rule.new(id: "multiple-expectations", guideline: "single", severity: "warning",
      summary: "More than one expectation in an isolated unit example"),
    Rule.new(id: "happy-path-only", guideline: "all", severity: "info",
      summary: "Method/endpoint group with no context and no failure-path example"),
    Rule.new(id: "should-syntax", guideline: "expect", severity: "error",
      summary: "Old `should` / `stub` syntax"),
    Rule.new(id: "expect-syntax-not-enforced", guideline: "expect", severity: "warning",
      summary: "RSpec config does not restrict expectations to the `expect` syntax"),
    Rule.new(id: "missing-subject", guideline: "subject", severity: "info",
      summary: "Several examples build the object under test inline instead of a `subject`"),
    Rule.new(id: "instance-variable", guideline: "let", severity: "error",
      summary: "Instance variable in an example group; use `let`"),
    Rule.new(id: "unreferenced-let-bang", guideline: "let", severity: "warning",
      summary: "`let!` that no example reads; it is setup, say so with `before`"),
    Rule.new(id: "any-instance", guideline: "mock", severity: "warning",
      summary: "`allow_any_instance_of` / `expect_any_instance_of`"),
    Rule.new(id: "stubbed-subject", guideline: "mock", severity: "warning",
      summary: "Stub on the object under test"),
    Rule.new(id: "message-chain", guideline: "mock", severity: "warning",
      summary: "`receive_message_chain` / `stub_chain`"),
    Rule.new(id: "stubbed-persistence", guideline: "mock", severity: "info",
      summary: "Stubbed persistence call; real records would test real behavior"),
    Rule.new(id: "large-data", guideline: "data", severity: "info",
      summary: "Creates many records; right only when the count is the threshold under test"),
    Rule.new(id: "fixtures", guideline: "factories", severity: "error",
      summary: "Rails fixtures instead of factories"),
    Rule.new(id: "raw-create", guideline: "factories", severity: "warning",
      summary: "Record built attribute-by-attribute instead of through a factory"),
    Rule.new(id: "weak-matcher", guideline: "matchers", severity: "warning",
      summary: "Boolean assertion where a readable matcher exists"),
    Rule.new(id: "lambda-expectation", guideline: "matchers", severity: "error",
      summary: "Lambda passed to `expect`; use a block"),
    Rule.new(id: "duplicate-example", guideline: "shared", severity: "info",
      summary: "Same example body in several places; shared example candidate"),
    Rule.new(id: "controller-spec", guideline: "integration", severity: "warning",
      summary: "Controller spec / controller internals; test through requests"),
    Rule.new(id: "should-wording", guideline: "should", severity: "warning",
      summary: "\"should\" in an example description"),
    Rule.new(id: "http-not-blocked", guideline: "stubbing", severity: "error",
      summary: "Real HTTP is not blocked in the suite")
  ].to_h { |rule| [rule.id, rule] }.freeze

  SEVERITY_WEIGHT = {"error" => 5, "warning" => 2, "info" => 1}.freeze
  SEVERITY_RANK = {"info" => 0, "warning" => 1, "error" => 2}.freeze

  # Directories whose specs are isolated units, where betterspecs asks for one
  # expectation per example. Request, system and job specs pay for their setup
  # and may assert several things.
  ISOLATED_TYPES = %w[
    models lib helpers services policies validators serializers presenters
    decorators queries forms values interactors commands unit
  ].freeze

  BROWSER_TYPES = %w[system features feature].freeze

  # ActiveRecord's query and persistence API. Stubbing these swaps the database
  # for a guess about what it would return. Query names like `first` or `count`
  # are common attribute names too, so they only count when stubbed on a class.
  PERSISTENCE_QUERY_METHODS = %i[
    find find_by find_by! where all first last take pluck exists? count create create!
  ].freeze
  PERSISTENCE_WRITE_METHODS = %i[save save! update update! destroy destroy! reload].freeze

  # Example descriptions that already speak about a failure path.
  NEGATIVE_WORDING = /\b(not?|never|invalid|error|errors|reject|rejects|exclude|excludes|forbids?|requires?|blocks?|prevents?|limits?|throttles?|fail|fails|raise|raises|without|missing|denie[sd]|den(y|ies)|unauthori[sz]ed|forbidden|redirect|redirects|blank|empty|nil|ignore|ignores|refuse|refuses|skip|skips|cannot|can't|doesn't|does not|nothing|only|unless|expired|too|false)\b/i

  GROUP_METHODS = %i[
    describe context feature example_group
    xdescribe xcontext xfeature fdescribe fcontext ffeature
    shared_examples shared_examples_for shared_context
  ].freeze
  SHARED_GROUP_METHODS = %i[shared_examples shared_examples_for shared_context].freeze
  EXAMPLE_METHODS = %i[
    it specify example scenario its focus
    fit fspecify fexample fscenario xit xspecify xexample xscenario
  ].freeze
  SHARED_INCLUDE_METHODS = %i[it_behaves_like it_should_behave_like include_examples include_context].freeze
  OLD_SYNTAX_METHODS = %i[should should_not should_receive should_not_receive stub stub! stub_chain unstub any_instance].freeze
  EXPECTATION_TARGETS = %i[to not_to to_not].freeze
  STUB_MATCHERS = %i[receive receive_messages receive_message_chain].freeze
  # A spy that still runs the real method replaces nothing.
  PASS_THROUGH = %i[and_call_original and_wrap_original].freeze
  IVAR_WRITES = [
    Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode,
    Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode
  ].freeze

  Options = Struct.new(
    :root, :paths, :format, :limit, :max_description, :context_prefixes,
    :max_list, :duplicate_min_chars, :duplicate_min_count, :only, :except,
    :fail_on, :rubocop
  ) do
    def self.defaults
      new(
        root: Dir.pwd, paths: [], format: "markdown", limit: 5, max_description: 40,
        context_prefixes: %w[when with without], max_list: 10,
        duplicate_min_chars: 80, duplicate_min_count: 3, only: nil, except: [],
        fail_on: "never", rubocop: false
      )
    end
  end

  Finding = Struct.new(:rule, :path, :line, :message) do
    def severity = RULES.fetch(rule).severity

    def to_h = {rule:, severity:, guideline: RULES.fetch(rule).guideline, path:, line:, message:}
  end

  Group = Struct.new(
    :kind, :method, :text, :text_kind, :line, :lets, :subject_names, :examples,
    :child_groups, :children, :referenced, :includes_shared, :metadata
  ) do
    def shared? = kind == :shared
  end

  Example = Struct.new(
    :method, :text, :text_kind, :line, :expectations, :aggregated, :constructions,
    :body_source
  )

  # Walks one spec file. Tracks the open example groups so rules can ask
  # "which subjects are in scope" or "did anything below this group read x".
  class FileAudit
    attr_reader :findings, :examples, :groups, :parse_errors

    def initialize(path, relative_path, options, project)
      @path = path
      @relative = relative_path
      @options = options
      @project = project
      @findings = []
      @examples = []
      @groups = 0
      @parse_errors = []
      @ivars_seen = Set.new
      @lines = []
    end

    def run
      source = File.read(@path)
      @lines = source.lines
      result = Prism.parse(source, filepath: @path)
      @parse_errors = result.errors.map { |e| "#{@relative}:#{e.location.start_line}: #{e.message}" }
      @type = spec_type_from_path
      @described_constant = nil
      visit(result.value, [], nil, false)
      if controller_spec? && @top_line
        add("controller-spec", @top_line, "controller spec — betterspecs tests what the user sees: move to a request or system spec")
      end
      self
    end

    private

    def spec_type_from_path
      parts = @relative.split("/")
      index = parts.index("spec")
      index ? parts[index + 1] : parts.first
    end

    def isolated? = ISOLATED_TYPES.include?(@type)

    def controller_spec? = @type == "controllers"

    def visit(node, stack, example, in_def)
      case node
      when Prism::DefNode
        node.compact_child_nodes.each { |child| visit(child, stack, example, true) }
        return
      when Prism::CallNode
        if group_call?(node)
          return visit_group(node, stack, example, in_def)
        elsif example_call?(node, stack)
          return visit_example(node, stack, in_def)
        end
        check_call(node, stack, example)
      when *IVAR_WRITES
        check_ivar(node, stack) unless in_def
      end
      node.compact_child_nodes.each { |child| visit(child, stack, example, in_def) }
    end

    def group_call?(node)
      return false unless GROUP_METHODS.include?(node.name)
      return false unless node.block.is_a?(Prism::BlockNode)

      node.receiver.nil? || (node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :RSpec)
    end

    def example_call?(node, stack)
      !stack.empty? && node.receiver.nil? && EXAMPLE_METHODS.include?(node.name) &&
        node.block.is_a?(Prism::BlockNode)
    end

    def visit_group(node, stack, example, in_def)
      first = node.arguments&.arguments&.first
      text, text_kind = describe_argument(first)
      kind = if SHARED_GROUP_METHODS.include?(node.name) || stack.any?(&:shared?)
        :shared
      elsif %i[context xcontext fcontext].include?(node.name)
        :context
      else
        :describe
      end
      group = Group.new(
        kind:, method: node.name, text:, text_kind:, line: node.location.start_line,
        lets: [], subject_names: Set.new, examples: [], child_groups: 0, children: [],
        referenced: Set.new, includes_shared: false, metadata: metadata_of(node)
      )
      @groups += 1
      if stack.empty?
        @top_line ||= group.line
        @described_constant = first.slice if constant?(first)
        @type = "controllers" if group.metadata[:type] == "controller"
      else
        stack.last.child_groups += 1
        stack.last.children << group
      end

      check_group_description(group, stack)
      inner = stack + [group]
      node.block.compact_child_nodes.each { |child| visit(child, inner, example, in_def) }
      close_group(group, inner)
    end

    def visit_example(node, stack, in_def)
      text, text_kind = describe_argument(node.arguments&.arguments&.first)
      metadata = metadata_of(node)
      example = Example.new(
        method: node.name, text:, text_kind:, line: node.location.start_line, expectations: 0,
        aggregated: metadata[:aggregate_failures] || stack.any? { |g| g.metadata[:aggregate_failures] },
        constructions: Set.new, body_source: node.block.body&.slice.to_s
      )
      stack.last.examples << example
      @examples << example
      check_example_description(example)
      node.block.compact_child_nodes.each { |child| visit(child, stack, example, in_def) }
      close_example(example)
    end

    def check_group_description(group, stack)
      return unless group.text_kind == :string && !group.shared?

      text = group.text
      if group.kind == :context
        prefixes = @options.context_prefixes.map { |p| Regexp.escape(p) }.join("|")
        unless text.match?(/\A(#{prefixes})\b/)
          add("context-wording", group.line,
            "context #{text.inspect} — start with #{@options.context_prefixes.join(" / ")}")
        end
        return
      end

      if text.match?(/\A(when|with|without|if|unless)\b/i)
        add("describe-as-context", group.line, "describe #{text.inspect} states a condition — use `context`")
      elsif !stack.empty? && @described_constant && method_like?(text) && @project.defines_method?(text)
        add("describe-method", group.line,
          "describe #{text.inspect} — did you mean `describe \"##{text}\"` (instance) or `\".#{text}\"` (class)?")
      elsif !stack.empty? && text.match?(/\bmethod\b/i)
        add("describe-method", group.line, "describe #{text.inspect} — name the method: `#name` or `.name`")
      end
    end

    # A bare snake_case word with an underscore or a ?, ! or = suffix reads as
    # a method name. Single plain words ("validations", "scopes") are topics,
    # and names nothing defines (analytics events, columns) are not methods.
    def method_like?(text)
      text.match?(/\A[a-z_][a-z0-9_]*[?!=]?\z/) && (text.include?("_") || text.match?(/[?!=]\z/))
    end

    def check_example_description(example)
      return unless example.text_kind == :string
      return if example.method == :its

      text = example.text
      if text.length > @options.max_description
        add("description-length", example.line,
          "#{text.length} chars (limit #{@options.max_description}): #{text.inspect}")
      end
      if text.match?(/\A(it\s+)?should\b/i)
        add("should-wording", example.line, "#{text.inspect} — third person present tense: \"returns\", not \"should return\"")
      end
      # In system/feature specs "when" usually names the user's action inside
      # the example ("closes when you press Escape"), not a precondition.
      if !BROWSER_TYPES.include?(@type) && (match = text.match(/\s(if|when|unless)\s/i))
        add("description-conditional", example.line,
          "#{text.inspect} — move the \"#{match[1]} …\" part into a `context`")
      end
    end

    def close_example(example)
      return unless isolated? && example.expectations > 1 && !example.aggregated
      return if @project.aggregate_failures_default

      add("multiple-expectations", example.line,
        "#{example.expectations} expectations in an isolated #{@type} example — split, or tag :aggregate_failures")
    end

    def close_group(group, stack)
      check_unreferenced_let_bang(group)
      check_missing_subject(group, stack)
      group.children.each { |child| check_happy_path_only(child, group.children) }
      check_happy_path_only(group, [group]) if stack.size == 1
      record_duplicates(group)
    end

    def check_unreferenced_let_bang(group)
      return if group.shared? || group.includes_shared

      group.lets.each do |let|
        next unless let[:bang]
        next if group.referenced.include?(let[:name])

        add("unreferenced-let-bang", let[:line],
          "let!(:#{let[:name]}) is never read — replace with `before { … }` so the intent is visible")
      end
    end

    # Only the same construction repeated counts. Validation specs build a
    # differently-invalid object per example on purpose.
    def check_missing_subject(group, stack)
      return if stack.any? { |g| g.subject_names.any? }

      construction, copies = group.examples.flat_map { |e| e.constructions.to_a }.tally.max_by { |_, n| n }
      return if copies.nil? || copies < 3

      add("missing-subject", group.line,
        "#{copies} examples repeat `#{construction[0, 60]}` — extract `subject(:name) { … }`")
    end

    # Siblings count: "#fetch — happy path" is fine next to "#fetch — errors".
    def check_happy_path_only(group, siblings)
      return unless group.kind == :describe && group.text_kind == :string

      subject = group.text[/\A(?:[#.]|::)[a-z_]\w*[?!=]?|\A(?:GET|POST|PUT|PATCH|DELETE|HEAD)\s+\S+/]
      return unless subject
      return if group.child_groups.positive? || group.includes_shared || group.examples.empty?

      related = siblings.select { |g| g.text_kind == :string && g.text.start_with?(subject) }
      return if related.any? { |g| g.text.match?(NEGATIVE_WORDING) }
      return if related.flat_map(&:examples).any? { |e| e.text.to_s.match?(NEGATIVE_WORDING) }

      add("happy-path-only", group.line,
        "#{group.text.inspect}: #{group.examples.size} example(s), no context, no failure path — read it: are edge/invalid cases covered elsewhere?")
    end

    def record_duplicates(group)
      group.examples.each do |example|
        body = example.body_source.gsub(/\s+/, " ").strip
        next if body.length < @options.duplicate_min_chars

        @project.record_example_body(body, @relative, example.line)
      end
    end

    def check_call(node, stack, example)
      name = node.name
      args = node.arguments&.arguments || []
      current = stack.last

      if node.receiver.nil? && args.empty? && node.block.nil?
        stack.each { |g| g.referenced << name }
      end
      if node.receiver.nil? && %i[send public_send __send__].include?(name) && args.first.is_a?(Prism::SymbolNode)
        stack.each { |g| g.referenced << args.first.unescaped.to_sym }
      end

      if current && node.receiver.nil?
        case name
        when :let, :let!
          if args.first.is_a?(Prism::SymbolNode)
            current.lets << {name: args.first.unescaped.to_sym, bang: name == :let!, line: node.location.start_line}
          end
        when :subject, :subject!
          current.subject_names << (args.first.is_a?(Prism::SymbolNode) ? args.first.unescaped.to_sym : :subject)
        when *SHARED_INCLUDE_METHODS
          stack.each { |g| g.includes_shared = true }
        end
      end

      if example && node.receiver.nil? && %i[expect is_expected are_expected].include?(name)
        example.expectations += 1
      end
      if example && node.receiver.nil? && name == :aggregate_failures && node.block
        example.aggregated = true
      end
      if example && name == :new && builds_described?(node.receiver)
        example.constructions << node.slice.gsub(/\s+/, "")
      end

      check_old_syntax(node, example)
      check_lambda(node)
      check_weak_matcher(node)
      check_mocks(node, stack)
      check_data(node)
      check_fixtures(node)
      check_controller_internals(node)
    end

    def builds_described?(receiver)
      return false unless receiver

      (receiver.is_a?(Prism::CallNode) && receiver.name == :described_class && receiver.receiver.nil?) ||
        (@described_constant && constant?(receiver) && receiver.slice == @described_constant)
    end

    def check_old_syntax(node, example)
      return unless OLD_SYNTAX_METHODS.include?(node.name)

      if node.receiver
        return if node.name == :any_instance && !node.receiver.is_a?(Prism::ConstantReadNode) && !node.receiver.is_a?(Prism::ConstantPathNode)

        add("should-syntax", node.location.start_line, "`#{node.receiver.slice}.#{node.name}` — use `expect(…)` / `allow(…).to receive`")
      elsif example && %i[should should_not].include?(node.name)
        add("should-syntax", node.location.start_line, "implicit `#{node.name}` — use `is_expected.#{(node.name == :should) ? "to" : "not_to"}`")
      end
    end

    def check_lambda(node)
      if node.name == :expect && node.receiver.nil?
        arg = node.arguments&.arguments&.first
        if lambda?(arg)
          add("lambda-expectation", node.location.start_line, "`expect(#{arg.slice[0, 30]}…)` — write `expect { … }`")
        end
      elsif (EXPECTATION_TARGETS + %i[should should_not]).include?(node.name) && lambda?(node.receiver)
        add("lambda-expectation", node.location.start_line, "lambda receives `.#{node.name}` — write `expect { … }.#{(node.name == :should) ? "to" : node.name}`")
      end
    end

    def lambda?(node)
      node.is_a?(Prism::LambdaNode) ||
        (node.is_a?(Prism::CallNode) && %i[lambda proc].include?(node.name) && node.receiver.nil? && node.block)
    end

    def check_weak_matcher(node)
      return unless EXPECTATION_TARGETS.include?(node.name)

      target = node.receiver
      return unless target.is_a?(Prism::CallNode) && target.name == :expect && target.receiver.nil?

      actual = target.arguments&.arguments&.first
      matcher = node.arguments&.arguments&.first
      return unless actual.is_a?(Prism::CallNode) && matcher.is_a?(Prism::CallNode)
      return if actual.safe_navigation?
      # `any? { … }` loses its block in `be_any`; `include?(list, x)` is a
      # module function, not a collection query.
      return if actual.block || (actual.arguments&.arguments&.size.to_i > 1)

      suggestion =
        if boolean_matcher?(matcher)
          positive = (node.name == :to) != falsy_matcher?(matcher)
          boolean_suggestion(actual, positive)
        # A model class has `count` but no `empty?`, so `expect(Order).to be_empty`
        # would raise; only collections get the rewrite.
        elsif %i[size count length].include?(actual.name) && collection?(actual.receiver) &&
            eq_literal?(matcher, Prism::IntegerNode, 0)
          "`expect(#{actual.receiver.slice}).#{node.name} be_empty`"
        end
      return unless suggestion

      add("weak-matcher", node.location.start_line, "`#{node.slice.lines.first.strip[0, 70]}` — #{suggestion}")
    end

    def boolean_matcher?(matcher)
      return true if matcher.receiver.nil? && %i[be_truthy be_falsey be_falsy].include?(matcher.name) && matcher.arguments.nil?
      return false unless matcher.receiver.nil? && %i[be eq eql equal].include?(matcher.name)

      arg = matcher.arguments&.arguments
      arg&.size == 1 && (arg.first.is_a?(Prism::TrueNode) || arg.first.is_a?(Prism::FalseNode))
    end

    def collection?(node)
      return false if node.nil? || constant?(node)

      !(node.is_a?(Prism::CallNode) && node.name == :described_class && node.receiver.nil?)
    end

    def falsy_matcher?(matcher)
      %i[be_falsey be_falsy].include?(matcher.name) || matcher.arguments&.arguments&.first.is_a?(Prism::FalseNode)
    end

    def eq_literal?(matcher, klass, value)
      return false unless matcher.receiver.nil? && %i[eq be eql equal].include?(matcher.name)

      arg = matcher.arguments&.arguments
      arg&.size == 1 && arg.first.is_a?(klass) && arg.first.value == value
    end

    # `positive` is whether the original asserts the predicate holds, after
    # folding in `not_to` and falsy matchers.
    def boolean_suggestion(actual, positive)
      name = actual.name.to_s
      receiver = actual.receiver&.slice
      return unless receiver

      arg = actual.arguments&.arguments&.first&.slice
      positive = !positive if name == "!="
      verb = positive ? "to" : "not_to"
      matcher =
        case name
        when "==", "!=" then "eq(#{arg})"
        when ">", "<", ">=", "<=" then "be #{name} #{arg}"
        when "include?" then "include(#{arg})"
        when "nil?" then "be_nil"
        when "empty?" then "be_empty"
        when "is_a?", "kind_of?" then "be_a(#{arg})"
        # `be_verify(raw_body: …)` or `be_can_sell` read worse than the call
        # they replace, so only plain argument-free predicates get one.
        when /\Ahas_(.+)\?\z/ then "have_#{$1}" unless arg
        when /\A(?!(?:can|is|should|will|does|did)_)(.+)\?\z/ then "be_#{$1}" unless arg
        end
      matcher && "`expect(#{receiver}).#{verb} #{matcher}`"
    end

    def check_mocks(node, stack)
      name = node.name
      line = node.location.start_line
      if node.receiver.nil? && %i[allow_any_instance_of expect_any_instance_of].include?(name)
        add("any-instance", line, "`#{name}` — inject the collaborator, or stub a single instance")
      end
      if %i[receive_message_chain stub_chain].include?(name)
        add("message-chain", line, "`#{name}` — a chain of stubs mirrors the implementation; stub one collaborator")
      end

      return unless EXPECTATION_TARGETS.include?(name)

      target = node.receiver
      return unless target.is_a?(Prism::CallNode) && %i[allow expect].include?(target.name) && target.receiver.nil?

      matcher = node.arguments&.arguments&.first
      matcher_root = root_call(matcher)
      return unless matcher_root && STUB_MATCHERS.include?(matcher_root.name)
      return if chain_names(matcher).intersect?(PASS_THROUGH)

      stubbed = target.arguments&.arguments&.first
      check_stubbed_persistence(matcher_root, stubbed, line)
      return unless stubbed.is_a?(Prism::CallNode) && stubbed.receiver.nil? && stubbed.arguments.nil?

      subjects = stack.flat_map { |g| g.subject_names.to_a }
      if subjects.include?(stubbed.name) || stubbed.name == :subject
        add("stubbed-subject", line, "stubs `#{stubbed.name}`, the object under test — the spec now tests the stub")
      end
    end

    def check_stubbed_persistence(matcher, stubbed, line)
      return unless matcher.name == :receive

      message = matcher.arguments&.arguments&.first
      return unless message.is_a?(Prism::SymbolNode)

      method = message.unescaped.to_sym
      stubs_write = PERSISTENCE_WRITE_METHODS.include?(method)
      stubs_class_query = PERSISTENCE_QUERY_METHODS.include?(method) && constant?(stubbed)
      return unless stubs_write || stubs_class_query

      add("stubbed-persistence", line, "`#{stubbed&.slice}` stubs `#{method}` — would a real record make this stub unnecessary?")
    end

    def chain_names(node)
      names = []
      while node.is_a?(Prism::CallNode)
        names << node.name
        node = node.receiver
      end
      names
    end

    def root_call(node)
      node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::CallNode)
      node.is_a?(Prism::CallNode) ? node : nil
    end

    def check_data(node)
      args = node.arguments&.arguments || []
      if node.receiver.nil? && node.name == :create_list && args[1].is_a?(Prism::IntegerNode) && args[1].value >= @options.max_list
        add("large-data", node.location.start_line, "`create_list(#{args[0]&.slice}, #{args[1].value})` — does the behavior need #{args[1].value} rows?")
      end
      if node.name == :times && node.receiver.is_a?(Prism::IntegerNode) && node.receiver.value >= @options.max_list &&
          node.block && contains_create?(node.block)
        add("large-data", node.location.start_line, "`#{node.receiver.value}.times { create … }` — does the behavior need that many rows?")
      end
      return unless %i[create create!].include?(node.name)
      described = node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :described_class
      return unless constant?(node.receiver) || described
      return if constant?(node.receiver) && node.receiver.slice.end_with?("FactoryBot")

      hash = args.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
      return if hash.nil? || hash.elements.size < 3

      add("raw-create", node.location.start_line,
        "`#{node.receiver.slice}.#{node.name}` with #{hash.elements.size} attributes — a factory keeps only the attributes this test cares about")
    end

    def contains_create?(node)
      return true if node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[create create!].include?(node.name)

      node.compact_child_nodes.any? { |child| contains_create?(child) }
    end

    def check_fixtures(node)
      return unless node.receiver.nil? && node.name == :fixtures && node.arguments

      add("fixtures", node.location.start_line, "`#{node.slice}` — use FactoryBot factories")
    end

    def check_controller_internals(node)
      return unless node.receiver.nil? && %i[assigns render_template assert_template].include?(node.name)

      add("controller-spec", node.location.start_line, "`#{node.name}` inspects controller internals — assert on the response the user sees")
    end

    def check_ivar(node, stack)
      return if stack.empty?
      return if @ivars_seen.include?(node.name)

      @ivars_seen << node.name
      add("instance-variable", node.location.start_line, "`#{node.name}` — use `let(:#{node.name.to_s.delete_prefix("@")})`")
    end

    def describe_argument(node)
      case node
      when Prism::StringNode then [node.unescaped, :string]
      when Prism::InterpolatedStringNode
        text = node.parts.map { |part| part.is_a?(Prism::StringNode) ? part.unescaped : part.slice }.join
        [text, node.parts.first.is_a?(Prism::StringNode) ? :string : :interpolated]
      when Prism::SymbolNode then [":#{node.unescaped}", :symbol]
      when nil then [nil, :none]
      else [node.slice, constant?(node) ? :constant : :other]
      end
    end

    def constant?(node) = node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

    def metadata_of(node)
      metadata = {}
      (node.arguments&.arguments || []).each do |arg|
        case arg
        when Prism::SymbolNode then metadata[arg.unescaped.to_sym] = true
        when Prism::KeywordHashNode, Prism::HashNode
          arg.elements.each do |pair|
            next unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)

            value = pair.value
            metadata[pair.key.unescaped.to_sym] =
              case value
              when Prism::SymbolNode then value.unescaped
              when Prism::TrueNode then true
              when Prism::FalseNode then false
              else value.slice
              end
          end
        end
      end
      metadata
    end

    def add(rule, line, message)
      return if suppressed?(rule, line)

      @findings << Finding.new(rule:, path: @relative, line:, message:)
    end

    # `# betterspecs:disable rule-a, rule-b` (or `all`) on the reported line,
    # also after another directive in the same comment
    # (`# rubocop:disable RSpec/AnyInstance -- betterspecs:disable any-instance`).
    def suppressed?(rule, line)
      text = @lines[line - 1].to_s
      match = text.match(/#.*\bbetterspecs:disable\s+([\w\-, ]+)/)
      return false unless match

      ids = match[1].split(/[\s,]+/)
      ids.include?("all") || ids.include?(rule)
    end
  end

  # Suite-level state: config files, cross-file duplicates, tooling facts.
  class Project
    attr_reader :root, :options, :aggregate_failures_default

    def initialize(options)
      @options = options
      @root = File.expand_path(options.root)
      @bodies = Hash.new { |h, k| h[k] = [] }
      @support_text = read_support_text
      @aggregate_failures_default = @support_text.match?(/aggregate_failures\]\s*=\s*true|aggregate_failures:\s*true/) &&
        @support_text.match?(/define_derived_metadata|config\.(before|around)/)
    end

    def spec_files
      patterns = @options.paths.empty? ? ["spec/**/*_spec.rb"] : @options.paths
      patterns.flat_map { |pattern|
        full = File.expand_path(pattern, @root)
        if File.directory?(full)
          Dir.glob(File.join(full, "**/*_spec.rb"))
        elsif File.file?(full)
          [full]
        else
          Dir.glob(full)
        end
      }.uniq.sort
    end

    def defines_method?(name)
      @defined_methods ||= Dir.glob(File.join(@root, "{app,lib}/**/*.rb")).each_with_object(Set.new) do |file, names|
        File.foreach(file) do |line|
          if (match = line.match(/^\s*def\s+(?:self\.)?([a-z_]\w*[?!=]?)/))
            names << match[1]
          end
        end
      end
      @defined_methods.empty? || @defined_methods.include?(name)
    end

    def record_example_body(body, path, line)
      @bodies[body] << [path, line]
    end

    def duplicate_findings
      @bodies.filter_map do |body, places|
        next if places.size < @options.duplicate_min_count

        path, line = places.first
        others = places.drop(1).first(4).map { |p, l| "#{p}:#{l}" }
        more = (places.size > 5) ? " (+#{places.size - 5} more)" : ""
        Finding.new(rule: "duplicate-example", path:, line:,
          message: "same body in #{places.size} examples: #{body[0, 60].inspect}… also #{others.join(", ")}#{more}")
      end
    end

    def config_findings
      findings = []
      helper = %w[spec/spec_helper.rb spec/rails_helper.rb].find { |f| File.exist?(File.join(@root, f)) } || "spec/spec_helper.rb"
      unless @support_text.match?(/syntax\s*=\s*:expect\b|disable_monkey_patching!/)
        findings << Finding.new(rule: "expect-syntax-not-enforced", path: helper, line: 1,
          message: "add `config.expect_with(:rspec) { |c| c.syntax = :expect }` (or `config.disable_monkey_patching!`)")
      end
      blocks_http = @support_text.match?(%r{webmock/rspec|disable_net_connect!|VCR\.configure})
      if !blocks_http
        findings << Finding.new(rule: "http-not-blocked", path: helper, line: 1,
          message: "no WebMock/VCR guard found — `require \"webmock/rspec\"` makes an unstubbed request fail the test")
      elsif (line = allow_net_connect_line)
        findings << Finding.new(rule: "http-not-blocked", path: line[0], line: line[1],
          message: "`allow_net_connect!` re-enables real HTTP for the rest of the run")
      end
      findings
    end

    def tooling
      rspec_file = File.join(@root, ".rspec")
      lock = File.join(@root, "Gemfile.lock")
      lock_text = File.exist?(lock) ? File.read(lock) : ""
      {
        rspec_options: File.exist?(rspec_file) ? File.read(rspec_file).split : [],
        guardfile: File.exist?(File.join(@root, "Guardfile")),
        parallel_tests: lock_text.match?(/^\s{4}(parallel_tests|turbo_tests|knapsack)\b/),
        spring: lock_text.match?(/^\s{4}spring\b/),
        bootsnap: lock_text.match?(/^\s{4}bootsnap\b/),
        rubocop_rspec: lock_text.match?(/^\s{4}rubocop-rspec\b/),
        factory_bot: lock_text.match?(/^\s{4}factory_bot\b/),
        webmock: lock_text.match?(/^\s{4}webmock\b/),
        vcr: lock_text.match?(/^\s{4}vcr\b/)
      }
    end

    # Each cop maps to a betterspecs guideline and the setting that guideline
    # implies. A project may relax one on purpose; the report states the gap
    # and leaves the call to the reader.
    RUBOCOP_EXPECTATIONS = {
      "RSpec/ContextWording" => ["contexts", {"Enabled" => true, "Prefixes" => %w[when with without]}],
      "RSpec/DescribeMethod" => ["describe", {"Enabled" => true}],
      "RSpec/MultipleExpectations" => ["single", {"Enabled" => true, "Max" => 1}],
      "RSpec/ImplicitExpect" => ["expect", {"Enabled" => true, "EnforcedStyle" => "is_expected"}],
      "RSpec/NamedSubject" => ["subject", {"Enabled" => true}],
      "RSpec/InstanceVariable" => ["let", {"Enabled" => true}],
      "RSpec/LetSetup" => ["let", {"Enabled" => true}],
      "RSpec/AnyInstance" => ["mock", {"Enabled" => true}],
      "RSpec/SubjectStub" => ["mock", {"Enabled" => true}],
      "RSpec/MessageChain" => ["mock", {"Enabled" => true}],
      "RSpec/PredicateMatcher" => ["matchers", {"Enabled" => true}],
      "RSpec/ExampleWording" => ["should", {"Enabled" => true}]
    }.freeze

    def rubocop_drift
      cops = RUBOCOP_EXPECTATIONS.keys.join(",")
      out, status = Open3.capture2e("bundle", "exec", "rubocop", "--show-cops", cops, chdir: @root)
      return {available: false, error: out.lines.last(3).join.strip} unless status.success?

      config = YAML.safe_load(out, permitted_classes: [Regexp, Symbol]) || {}
      {available: true, drift: self.class.rubocop_drift_from(config)}
    rescue Errno::ENOENT => e
      {available: false, error: e.message}
    end

    def self.rubocop_drift_from(config)
      RUBOCOP_EXPECTATIONS.filter_map do |cop, (guideline, expected)|
        actual = config[cop]
        next {cop:, guideline:, expected:, actual: "not loaded (is rubocop-rspec required?)"} unless actual

        gaps = expected.reject { |key, value| actual[key] == value }
        next if gaps.empty?

        {cop:, guideline:, expected: gaps, actual: gaps.keys.to_h { |k| [k, actual[k]] }}
      end
    end

    private

    def support_files
      %w[.rspec spec/spec_helper.rb spec/rails_helper.rb].map { |f| File.join(@root, f) }.select { |f| File.file?(f) } +
        Dir.glob(File.join(@root, "spec/support/**/*.rb"))
    end

    def read_support_text
      support_files.map { |f| File.read(f) }.join("\n")
    end

    def allow_net_connect_line
      support_files.each do |file|
        File.foreach(file).with_index(1) do |text, line|
          next if text.strip.start_with?("#")
          return [relative(file), line] if text.match?(/\ballow_net_connect!/)
        end
      end
      nil
    end

    def relative(path) = path.delete_prefix(@root + "/")
  end

  class Runner
    def initialize(options)
      @options = options
      @project = Project.new(options)
    end

    def call
      files = @project.spec_files
      audits = files.map do |path|
        FileAudit.new(path, path.delete_prefix(@project.root + "/"), @options, @project).run
      end
      findings = (audits.flat_map(&:findings) + @project.duplicate_findings + @project.config_findings)
        .select { |f| selected?(f.rule) }
        .sort_by { |f| [f.path, f.line, f.rule] }
      Report.new(
        options: @options, root: @project.root, files: files.size,
        examples: audits.sum { |a| a.examples.size }, groups: audits.sum(&:groups),
        findings:, parse_errors: audits.flat_map(&:parse_errors),
        tooling: @project.tooling, rubocop: (@options.rubocop ? @project.rubocop_drift : nil)
      )
    end

    private

    def selected?(rule)
      (@options.only.nil? || @options.only.include?(rule)) && !@options.except.include?(rule)
    end
  end

  Report = Struct.new(:options, :root, :files, :examples, :groups, :findings, :parse_errors, :tooling, :rubocop) do
    def counts
      RULES.keys.to_h { |id| [id, findings.count { |f| f.rule == id }] }
    end

    def hotspots(limit = 15)
      findings.reject { |f| f.severity == "info" }
        .group_by(&:path)
        .map { |path, list| {path:, score: list.sum { |f| SEVERITY_WEIGHT[f.severity] }, findings: list.size} }
        .sort_by { |h| [-h[:score], h[:path]] }
        .first(limit)
    end

    def failed?
      return false if options.fail_on == "never"

      threshold = SEVERITY_RANK.fetch(options.fail_on)
      findings.any? { |f| SEVERITY_RANK[f.severity] >= threshold }
    end

    def to_json(*)
      JSON.pretty_generate(
        version: VERSION, root:, files:, groups:, examples:,
        summary: counts.reject { |_, n| n.zero? },
        findings: findings.map(&:to_h),
        hotspots: hotspots,
        rubocop: rubocop, tooling: tooling, parse_errors: parse_errors
      )
    end

    def to_markdown
      out = +"# Betterspecs audit\n\n"
      out << "#{files} spec files · #{groups} example groups · #{examples} examples · #{findings.size} findings\n\n"
      out << "| Guideline | Rule | Severity | Count |\n|---|---|---|---:|\n"
      RULES.each_value do |rule|
        count = counts[rule.id]
        out << "| [#{GUIDELINES[rule.guideline]}](#{SITE}/##{rule.guideline}) | `#{rule.id}` | #{rule.severity} | #{count} |\n"
      end

      unless hotspots.empty?
        out << "\n## Hotspots (error ×5, warning ×2)\n\n| File | Score | Findings |\n|---|---:|---:|\n"
        hotspots.each { |h| out << "| `#{h[:path]}` | #{h[:score]} | #{h[:findings]} |\n" }
      end

      findings.group_by(&:rule).sort_by { |id, _| RULES.keys.index(id) }.each do |id, list|
        rule = RULES.fetch(id)
        out << "\n## `#{id}` — #{rule.summary} (#{list.size})\n\n"
        list.first(options.limit).each { |f| out << "- `#{f.path}:#{f.line}` #{f.message}\n" }
        out << "- … #{list.size - options.limit} more (`--format json` lists all)\n" if list.size > options.limit
      end

      if rubocop
        out << "\n## rubocop-rspec vs betterspecs\n\n"
        if !rubocop[:available]
          out << "rubocop unavailable: #{rubocop[:error]}\n"
        elsif rubocop[:drift].empty?
          out << "Every mapped cop is configured the way betterspecs reads.\n"
        else
          out << "| Cop | Guideline | betterspecs | project |\n|---|---|---|---|\n"
          rubocop[:drift].each do |d|
            out << "| `#{d[:cop]}` | #{GUIDELINES[d[:guideline]]} | `#{d[:expected]}` | `#{d[:actual]}` |\n"
          end
        end
      end

      out << "\n## Tooling (continuous testing, faster tests, formatter)\n\n"
      tooling.each do |key, value|
        value = value.empty? ? "(none)" : value.join(" ") if value.is_a?(Array)
        out << "- #{key}: #{value}\n"
      end

      unless parse_errors.empty?
        out << "\n## Parse errors\n\n"
        parse_errors.first(20).each { |e| out << "- #{e}\n" }
      end
      out
    end
  end

  def self.parse_options(argv)
    options = Options.defaults
    parser = OptionParser.new do |o|
      o.banner = "Usage: betterspecs_audit.rb [options] [paths/globs...]\n\nAudits RSpec specs against #{SITE}."
      o.on("--root DIR", "Project root (default: cwd)") { |v| options.root = v }
      o.on("--format FORMAT", %w[markdown json], "markdown (default) or json") { |v| options.format = v }
      o.on("--limit N", Integer, "Findings listed per rule in markdown (default 5)") { |v| options.limit = v }
      o.on("--max-description N", Integer, "Example description length limit (default 40)") { |v| options.max_description = v }
      o.on("--context-prefixes LIST", Array, "Allowed context prefixes (default when,with,without)") { |v| options.context_prefixes = v }
      o.on("--max-list N", Integer, "create_list / N.times threshold (default 10)") { |v| options.max_list = v }
      o.on("--duplicate-min-chars N", Integer, "Shortest example body counted as duplicate (default 80)") { |v| options.duplicate_min_chars = v }
      o.on("--duplicate-min-count N", Integer, "Copies needed to report a duplicate (default 3)") { |v| options.duplicate_min_count = v }
      o.on("--only LIST", Array, "Run only these rule ids") { |v| options.only = v }
      o.on("--except LIST", Array, "Skip these rule ids") { |v| options.except = v }
      o.on("--fail-on LEVEL", %w[never info warning error], "Exit 1 at or above this severity (default never)") { |v| options.fail_on = v }
      o.on("--rubocop", "Compare the project's effective rubocop-rspec config with betterspecs") { options.rubocop = true }
      o.on("--rules", "List rule ids and exit") do
        RULES.each_value { |r| puts format("%-28s %-8s %-12s %s", r.id, r.severity, r.guideline, r.summary) }
        exit
      end
      o.on("-v", "--version") do
        puts VERSION
        exit
      end
    end
    options.paths = parser.parse(argv)
    unknown = [*options.only, *options.except] - RULES.keys
    raise OptionParser::InvalidArgument, "unknown rule id(s): #{unknown.join(", ")}" unless unknown.empty?

    options
  end

  def self.run(argv, stdout: $stdout)
    options = parse_options(argv)
    report = Runner.new(options).call
    stdout.puts((options.format == "json") ? report.to_json : report.to_markdown)
    report.failed? ? 1 : 0
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit BetterspecsAudit.run(ARGV)
  rescue OptionParser::ParseError => e
    warn e.message
    exit 2
  end
end

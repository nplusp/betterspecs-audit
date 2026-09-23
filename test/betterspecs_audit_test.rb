# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require_relative "../skills/betterspecs-audit/scripts/betterspecs_audit"

class BetterspecsAuditTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)
  BAD = File.join(FIXTURES, "bad")
  CLEAN = File.join(FIXTURES, "clean")

  def audit(root, *args)
    options = BetterspecsAudit.parse_options(["--root", root, *args])
    BetterspecsAudit::Runner.new(options).call
  end

  def triples(findings)
    findings.map { |f| [f.rule, f.path, f.line] }.sort
  end

  # Each fixture line that should be reported carries `# expect: rule-a, rule-b`.
  def expected_markers(root)
    Dir.glob(File.join(root, "spec/**/*.rb")).flat_map do |file|
      relative = file.delete_prefix(root + "/")
      File.foreach(file).with_index(1).flat_map do |text, line|
        match = text.match(/# expect: ([\w\-, ]+)/)
        match ? match[1].split(/,\s*/).map { |rule| [rule.strip, relative, line] } : []
      end
    end.sort
  end

  def test_bad_fixture_reports_exactly_the_marked_lines
    assert_equal expected_markers(BAD), triples(audit(BAD).findings)
  end

  def test_every_rule_has_a_marked_violation
    marked = expected_markers(BAD).map(&:first).uniq.sort
    assert_equal BetterspecsAudit::RULES.keys.sort, marked
  end

  def test_clean_fixture_reports_nothing
    assert_empty triples(audit(CLEAN).findings)
  end

  def test_weak_matcher_keeps_negation
    finding = audit(BAD, "--only", "weak-matcher").findings.find { |f| f.message.include?("be_falsey") }
    assert_includes finding.message, "`expect(build(:user)).not_to be_admin`"
  end

  def test_only_applies_to_cross_file_findings
    rules = audit(BAD, "--only", "duplicate-example,http-not-blocked").findings.map(&:rule).uniq.sort
    assert_equal %w[duplicate-example http-not-blocked], rules
  end

  def test_except_drops_a_rule
    rules = audit(BAD, "--except", "weak-matcher").findings.map(&:rule)
    refute_includes rules, "weak-matcher"
    assert_includes rules, "fixtures"
  end

  def test_unknown_rule_id_is_rejected
    assert_raises(OptionParser::InvalidArgument) { BetterspecsAudit.parse_options(["--only", "nope"]) }
  end

  def test_fail_on_sets_exit_status
    out = StringIO.new
    assert_equal 1, BetterspecsAudit.run(["--root", BAD, "--fail-on", "error"], stdout: out)
    assert_equal 0, BetterspecsAudit.run(["--root", CLEAN, "--fail-on", "info"], stdout: out)
    assert_equal 0, BetterspecsAudit.run(["--root", BAD], stdout: out)
  end

  def test_json_output_lists_every_finding
    out = StringIO.new
    BetterspecsAudit.run(["--root", BAD, "--format", "json"], stdout: out)
    json = JSON.parse(out.string)
    assert_equal expected_markers(BAD).size, json["findings"].size
    assert_equal 5, json["summary"]["weak-matcher"]
    assert_equal "spec/models/user_spec.rb", json["hotspots"].first["path"]
  end

  def test_markdown_links_each_guideline
    report = audit(BAD).to_markdown
    assert_includes report, "(https://www.betterspecs.org/#let)"
    assert_includes report, "## `instance-variable`"
  end

  def test_paths_limit_the_scan
    report = audit(BAD, "spec/requests")
    assert_equal 1, report.files
    assert_equal %w[duplicate-example expect-syntax-not-enforced http-not-blocked], report.findings.map(&:rule).uniq.sort
  end

  def test_description_limit_is_configurable
    rules = audit(BAD, "--max-description", "80").findings.map(&:rule)
    refute_includes rules, "description-length"
  end

  def test_context_prefixes_are_configurable
    rules = audit(BAD, "--context-prefixes", "when,with,without,admin").findings.map(&:rule)
    refute_includes rules, "context-wording"
  end

  def test_disable_comment_is_what_silences_the_clean_fixture
    with_project(CLEAN) do |root|
      file = File.join(root, "spec/models/order_spec.rb")
      File.write(file, File.read(file).sub(" # betterspecs:disable description-length", ""))
      assert_equal ["description-length"], audit(root).findings.map(&:rule)
    end
  end

  def test_disable_can_follow_another_directive
    with_project(BAD) do |root|
      file = File.join(root, "spec/models/user_spec.rb")
      File.write(file, File.read(file).sub("# expect: any-instance", "# rubocop:disable RSpec/AnyInstance -- betterspecs:disable any-instance"))
      refute_includes audit(root).findings.map(&:rule), "any-instance"
    end
  end

  def test_global_aggregate_failures_silences_multiple_expectations
    with_project(BAD) do |root|
      File.write(File.join(root, "spec/spec_helper.rb"), <<~RUBY)
        RSpec.configure do |config|
          config.define_derived_metadata { |meta| meta[:aggregate_failures] = true }
        end
      RUBY
      refute_includes audit(root).findings.map(&:rule), "multiple-expectations"
    end
  end

  def test_allow_net_connect_reopens_http
    with_project(CLEAN) do |root|
      FileUtils.mkdir_p(File.join(root, "spec/support"))
      File.write(File.join(root, "spec/support/net.rb"), "# comment allow_net_connect!\nWebMock.allow_net_connect!\n")
      finding = audit(root).findings.find { |f| f.rule == "http-not-blocked" }
      assert_equal ["spec/support/net.rb", 2], [finding.path, finding.line]
    end
  end

  def test_rubocop_drift_names_relaxed_cops
    config = BetterspecsAudit::Project::RUBOCOP_EXPECTATIONS.to_h { |cop, (_, expected)| [cop, expected.dup] }
    assert_empty BetterspecsAudit::Project.rubocop_drift_from(config)

    config["RSpec/LetSetup"] = {"Enabled" => false}
    config["RSpec/MultipleExpectations"] = {"Enabled" => true, "Max" => 5}
    config.delete("RSpec/SubjectStub")
    drift = BetterspecsAudit::Project.rubocop_drift_from(config).to_h { |d| [d[:cop], d[:actual]] }
    assert_equal({"Enabled" => false}, drift["RSpec/LetSetup"])
    assert_equal({"Max" => 5}, drift["RSpec/MultipleExpectations"])
    assert_match(/not loaded/, drift["RSpec/SubjectStub"])
  end

  def test_parse_errors_are_reported_not_raised
    with_project(CLEAN) do |root|
      File.write(File.join(root, "spec/models/broken_spec.rb"), "RSpec.describe Foo do\n  it \"x\" do\n")
      report = audit(root)
      assert(report.parse_errors.any? { |e| e.start_with?("spec/models/broken_spec.rb") })
    end
  end

  private

  def with_project(source)
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(source, "."), dir)
      yield dir
    end
  end
end

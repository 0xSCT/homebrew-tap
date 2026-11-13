# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "digest"
require "fileutils"
require "json"
require "rbconfig"
require_relative "tap_ci"

# Exercise source selection and publication trust boundaries with workspace fixtures.
class TapCITest < Minitest::Test
  SCRIPT = File.expand_path("tap_ci.rb", __dir__).freeze

  def test_changed_formulae_covers_every_commit_in_the_push
    Dir.mktmpdir("tap-ci-test-", File.expand_path("../..", __dir__)) do |repository|
      git = lambda do |*args|
        stdout, stderr, status = Open3.capture3("git", *args, chdir: repository)
        assert status.success?, stderr
        stdout.strip
      end
      git.call("init", "--quiet")
      git.call("config", "user.name", "Tap CI Test")
      git.call("config", "user.email", "tap-ci-test@example.invalid")
      File.write(File.join(repository, "README.md"), "Test repository\n")
      git.call("add", "README.md")
      git.call("commit", "--quiet", "-m", "Initial fixture")
      base = git.call("rev-parse", "HEAD")
      Dir.mkdir(File.join(repository, "Formula"))
      %w[raygui sdl3-static].each do |name|
        File.write(File.join(repository, "Formula", "#{name}.rb"), "# Git change fixture\n")
        git.call("add", "Formula/#{name}.rb")
        git.call("commit", "--quiet", "-m", "Add #{name}")
      end
      head = git.call("rev-parse", "HEAD")
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, "changed-formulae", base, head, chdir: repository
      )
      assert_equal %w[raygui sdl3-static], stdout.strip.split(","), stderr
      assert status.success?, stderr
    end
  end

  def test_added_deleted_cask_only_and_initial_ranges
    with_repository do |repository, git|
      FileUtils.mkdir_p("#{repository}/Formula")
      FileUtils.mkdir_p("#{repository}/Casks")
      File.write("#{repository}/Formula/raylib.rb", "# fixture\n")
      File.write("#{repository}/Formula/imgui.rb", "# fixture\n")
      base = commit_fixture(git)
      File.delete("#{repository}/Formula/raylib.rb")
      File.write("#{repository}/Formula/sdl3-static.rb", "# fixture\n")
      File.write("#{repository}/Casks/editor.rb", "# fixture\n")
      head = commit_fixture(git)
      assert_equal ["sdl3-static"], TapCI.changed_formulae(base_sha: base, head_sha: head, repository: repository)
      assert_equal ["sdl3-static"], TapCI.added_formulae(base_sha: base, head_sha: head, repository: repository)
      assert_equal %w[imgui sdl3-static],
                   TapCI.changed_formulae(base_sha: "0" * 40, head_sha: head, repository: repository)
      File.write("#{repository}/Casks/editor.rb", "# changed cask\n")
      cask_head = commit_fixture(git)
      assert_empty TapCI.changed_formulae(base_sha: head, head_sha: cask_head, repository: repository)
      File.delete("#{repository}/Formula/imgui.rb")
      deleted_head = commit_fixture(git)
      assert_empty TapCI.changed_formulae(base_sha: cask_head, head_sha: deleted_head, repository: repository)
    end
  end

  def test_selection_uses_reviewed_tree_not_working_tree_and_rejects_shell_input
    with_repository do |repository, git|
      FileUtils.mkdir_p("#{repository}/Formula")
      base = commit_fixture(git)
      File.write("#{repository}/Formula/raygui.rb", "# fixture\n")
      head = commit_fixture(git)
      File.delete("#{repository}/Formula/raygui.rb")
      File.write("#{repository}/Formula/untracked.rb", "# fixture\n")
      assert_equal ["raygui"], TapCI.changed_formulae(base_sha: base, head_sha: head, repository: repository)
      error = assert_raises(ArgumentError) do
        TapCI.changed_formulae(base_sha: "HEAD; touch injected", head_sha: head, repository: repository)
      end
      assert_match(/Invalid commit SHA/, error.message)
      refute File.exist?("#{repository}/injected")
    end
  end

  def test_platform_filter_preserves_graphics_and_excludes_arm_compilers
    names = %w[imgui lldb-sct llvm-sct raygui sdl3-static]
    assert_equal %w[imgui raygui sdl3-static], TapCI.platform_formulae(names, "arm64")
    assert_equal names, TapCI.platform_formulae(names, "x86_64")
    assert_raises(ArgumentError) { TapCI.platform_formulae(names, "unknown") }
  end

  def test_native_execution_requires_ephemeral_github_repository_and_matching_architecture
    environment = { "GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "0xSCT/homebrew-tap" }
    assert_nil TapCI.verify_native_environment!(
      environment: environment, architecture: "arm64", native_architecture: "arm64",
    )
    [
      [environment.merge("GITHUB_ACTIONS" => "false"), "arm64", "arm64", /GitHub Actions native job required/],
      [environment.except("GITHUB_ACTIONS"), "arm64", "arm64",
       /GitHub Actions native job required/],
      [environment.merge("GITHUB_REPOSITORY" => "other/homebrew-tap"), "arm64", "arm64",
       /Unexpected native repository/],
      [environment, "arm64", "x86_64", /Native architecture mismatch/],
      [environment, "unknown", "unknown", /Unknown native architecture/],
    ].each do |variables, architecture, native_architecture, message|
      error = assert_raises(ArgumentError) do
        TapCI.verify_native_environment!(
          environment: variables, architecture: architecture, native_architecture: native_architecture,
        )
      end
      assert_match message, error.message
    end
  end

  def test_native_order_rejects_dependency_cycles_and_other_tap_identity
    formulae = native_formula_metadata
    formulae.find { |formula| formula.fetch("name") == "sdl2-static" }["dependencies"] = ["0xsct/tap/imgui"]
    error = assert_raises(ArgumentError) do
      TapCI.native_formulae(names: %w[imgui sdl2-static], formulae: formulae)
    end
    assert_match(/Cyclic native formula dependencies/, error.message)
    error = assert_raises(ArgumentError) do
      TapCI.native_formulae(names: ["other/tap/imgui"], formulae: formulae)
    end
    assert_match(/Invalid selected formula/, error.message)
  end

  def test_initial_native_selection_orders_canonical_dependencies_before_short_archive_names
    with_repository do |repository, git|
      FileUtils.mkdir_p("#{repository}/Formula")
      %w[imgui lldb-sct llvm-sct raygui raylib-static sdl2-static sdl3-static].each do |name|
        File.write("#{repository}/Formula/#{name}.rb", "# selection fixture\n")
      end
      head = commit_fixture(git)
      names = TapCI.changed_formulae(base_sha: "0" * 40, head_sha: head, repository: repository)
      ordered = TapCI.native_formulae(names: names, formulae: native_formula_metadata)
      assert_equal %w[sdl2-static imgui llvm-sct lldb-sct raylib-static raygui sdl3-static], ordered
      refute ordered.any? { |name| name.include?("/") }, "Archive names must remain short"
      assert_equal %w[sdl2-static imgui raylib-static raygui sdl3-static],
                   TapCI.native_formulae(names:    TapCI.platform_formulae(names, "arm64"),
                                         formulae: native_formula_metadata)
    end
  end

  def test_native_source_commands_bootstrap_unbottled_intel_closure_before_bottle_build
    formulae = native_formula_metadata
    core_names = %w[cmake python@3.15 z3 swig]
    core = formulae.select { |formula| core_names.include?(formula.fetch("name")) }
    assert_equal %w[cmake python@3.15 z3 swig], core.map { |formula| formula.fetch("name") }
    core.each { |formula| refute formula.dig("bottle", "stable", "files").key?("tahoe") }
    assert_equal %w[ca-certificates mpdecimal openssl@4 sqlite xz zstd],
                 core[1].fetch("dependencies")
    assert_equal %w[cmake python@3.15], core[2].fetch("build_dependencies")
    assert_equal ["pcre2"], core[3].fetch("dependencies")

    ordered = TapCI.native_formulae(names: %w[lldb-sct llvm-sct], formulae: formulae)
    assert_equal %w[llvm-sct lldb-sct], ordered
    commands = ordered.flat_map do |name|
      formula = formulae.find { |entry| entry.fetch("full_name") == "0xsct/tap/#{name}" }
      TapCI.native_commands(formula)
    end
    assert_equal [
      ["brew", "install", "--only-dependencies", "--include-test", "--build-from-source", "0xsct/tap/llvm-sct"],
      ["brew", "install", "--build-bottle", "--include-test", "0xsct/tap/llvm-sct"],
      ["brew", "test", "0xsct/tap/llvm-sct"],
      ["brew", "bottle", "--json",
       "--root-url=https://github.com/0xsct/homebrew-tap/releases/download/llvm-sct-23.1.5_1",
       "0xsct/tap/llvm-sct"],
      ["brew", "install", "--only-dependencies", "--include-test", "--build-from-source", "0xsct/tap/lldb-sct"],
      ["brew", "install", "--build-bottle", "--include-test", "0xsct/tap/lldb-sct"],
      ["brew", "test", "0xsct/tap/lldb-sct"],
      ["brew", "bottle", "--json",
       "--root-url=https://github.com/0xsct/homebrew-tap/releases/download/lldb-sct-23.1.5_1",
       "0xsct/tap/lldb-sct"],
    ], commands
  end

  def test_preinstalled_tap_formula_is_rebuilt_in_bottle_mode_not_silently_reused
    formula = native_formula_metadata.find { |entry| entry.fetch("name") == "llvm-sct" }
    formula["installed"] = [{ "version" => "23.1.5_1", "built_as_bottle" => false }]
    commands = TapCI.native_commands(formula)
    assert_equal ["brew", "uninstall", "--formula", "--force", "--ignore-dependencies", "0xsct/tap/llvm-sct"],
                 commands[0]
    assert_equal ["brew", "install", "--only-dependencies", "--include-test", "--build-from-source",
                  "0xsct/tap/llvm-sct"], commands[1]
    assert_equal ["brew", "install", "--build-bottle", "--include-test", "0xsct/tap/llvm-sct"], commands[2]
  end

  def test_native_success_gate_requires_every_selected_archive_and_json_pair
    with_retained_publication do |data, directory|
      File.delete("#{directory}/0.bottle.json")
      File.delete(data[:downloaded_bottles].first.fetch("archive_path"))
      expected = data[:expected_bottles]
      assert_nil TapCI.verify_native_bottles!(
        expected_bottles: expected, architecture: "x86_64", directory: directory,
      )
      File.delete("#{directory}/2.bottle.json")
      File.delete(data[:downloaded_bottles].last.fetch("archive_path"))
      error = assert_raises(ArgumentError) do
        TapCI.verify_native_bottles!(expected_bottles: expected, architecture: "x86_64", directory: directory)
      end
      assert_match(%r{Missing bottle pair: 0xsct/tap/llvm-sct tahoe}, error.message)
    end

    with_publication do |data|
      Dir.mktmpdir("tap-ci-native-empty-", File.expand_path("../..", __dir__)) do |directory|
        error = assert_raises(ArgumentError) do
          TapCI.verify_native_bottles!(
            expected_bottles: data[:expected_bottles], architecture: "arm64", directory: directory,
          )
        end
        assert_match(%r{Missing bottle pair: 0xsct/tap/raygui arm64_golden_gate}, error.message)
      end
    end
  end

  def test_native_success_gate_rejects_unreviewed_core_bottle_records
    with_retained_publication do |data, directory|
      entry = data[:downloaded_bottles].last
      record = JSON.parse(JSON.generate(entry.slice("formula", "bottle")))
      File.write("#{directory}/core.bottle.json", JSON.generate("cmake" => record))
      error = assert_raises(ArgumentError) do
        TapCI.verify_native_bottles!(
          expected_bottles: data[:expected_bottles], architecture: "x86_64", directory: directory,
        )
      end
      assert_match(/Invalid bottle record/, error.message)
    end
  end

  def test_publisher_accepts_mixed_case_repository_but_still_fails_closed_on_protected_main
    snapshot = [{}, {}, { "name" => "main", "protected" => true }]
    with_publishing_environment("0xSCT/homebrew-tap") do
      with_replaced_method(TapCI, :publication_snapshot, ->(*_args) { snapshot }) do
        error = assert_raises(ArgumentError) { TapCI.publish("7", "a" * 40) }
        assert_match(/Protected main branch/, error.message)
      end
    end
    ["other/homebrew-tap", "0xSCT/homebrew-other", "0xSCT/homebrew-tap-extra",
     "0xSCT/homebrew-tap/", " 0xSCT/homebrew-tap", "https://github.com/0xSCT/homebrew-tap"].each do |name|
      with_publishing_environment(name) do
        error = assert_raises(ArgumentError) { TapCI.publish("7", "a" * 40) }
        assert_match(/Unexpected publishing repository/, error.message)
      end
    end
  end

  def test_publication_snapshot_accepts_exact_mixed_case_base_repository_only
    require "utils/github"
    request = {
      "state" => "open", "head" => { "sha" => "a" * 40 },
      "base" => { "ref" => "main", "repo" => { "full_name" => "0xScT/Homebrew-Tap" } }
    }
    run = { "id" => 42, "run_attempt" => 2, "head_sha" => "a" * 40 }
    branch = { "name" => "main", "protected" => false }
    responses = {
      "pulls/7" => request, "actions/runs/42" => run, "branches/main" => branch,
      "" => { "permissions" => { "push" => true } }
    }
    with_replaced_method(TapCI, :api, ->(path) { responses.fetch(path) }) do
      suites = [[{ "workflowRun" => { "databaseId" => 42 } }]]
      with_replaced_method(GitHub, :get_workflow_run, ->(*_args, **_kwargs) { suites }) do
        paginate = ->(*_args, **_kwargs, &block) { block.call("jobs" => []) }
        with_replaced_method(GitHub::API, :paginate_rest, paginate) do
          actual_request, actual_run, actual_branch = TapCI.publication_snapshot("7", "a" * 40)
          assert_equal request, actual_request
          assert_equal run.merge("jobs" => []), actual_run
          assert_equal true, actual_branch.dig("permissions", "push")
          [nil, [], "other/homebrew-tap", "0xSCT/homebrew-other", "0xSCT/homebrew-tap-extra",
           "0xSCT/homebrew-tap/", " 0xSCT/homebrew-tap"].each do |name|
            request["base"]["repo"]["full_name"] = name
            error = assert_raises(ArgumentError) { TapCI.publication_snapshot("7", "a" * 40) }
            assert_match(/Unexpected base repository/, error.message)
          end
        end
      end
    end
  end

  def test_accepts_exact_mixed_native_bottle_pairs
    with_publication { |data| assert_nil TapCI.verify_publication!(**data) }
  end

  def test_compiler_only_accepts_intel_only_and_empty_sets_accept_no_bottles
    with_publication do |data|
      data[:expected_bottles].delete("0xsct/tap/raygui")
      data[:downloaded_bottles].reject! { |entry| entry["name"] == "0xsct/tap/raygui" }
      data[:selected_run]["jobs"].reject! { |job| job["name"] == "native (arm64)" }
      assert_nil TapCI.verify_publication!(**data)
      data[:expected_bottles].clear
      data[:downloaded_bottles].clear
      assert_nil TapCI.verify_publication!(**data)
    end
  end

  def test_rejects_changed_head_newer_failed_run_and_rerun_attempt
    rejection(/PR head changed/) { |data| data[:pull_request]["head"]["sha"] = "b" * 40 }
    rejection(/Newest tests.yml run changed/) do |data|
      data[:selected_run]["latest"]["id"] = 43
      data[:selected_run]["latest"]["conclusion"] = "failure"
    end
    rejection(/Run attempt changed/) { |data| data[:selected_run]["latest"]["run_attempt"] = 3 }
    rejection(/Run head mismatch/) { |data| data[:selected_run]["head_sha"] = "b" * 40 }
    rejection(/tests.yml run not successful/) { |data| data[:selected_run]["conclusion"] = "failure" }
    rejection(/Wrong tests.yml workflow/) { |data| data[:selected_run]["path"] = ".github/workflows/other.yml" }
    rejection(/tests.yml run not successful/) { |data| data[:selected_run]["latest"]["conclusion"] = "failure" }
    rejection(/tests.yml run not successful/) { |data| data[:selected_run]["latest"]["status"] = "in_progress" }
  end

  def test_rejects_failed_incomplete_missing_or_wrong_native_jobs
    rejection(/Required native job not successful: arm64/) do |data|
      data[:selected_run]["jobs"][0]["conclusion"] = "failure"
    end
    rejection(/Required native job not successful: x86_64/) do |data|
      data[:selected_run]["jobs"][1]["status"] = "in_progress"
    end
    rejection(/Missing required native job: arm64/) { |data| data[:selected_run]["jobs"].shift }
    rejection(/Native runner mismatch: arm64/) { |data| data[:selected_run]["jobs"][0]["labels"] = ["macos-26"] }
    rejection(/Native job attempt mismatch/) { |data| data[:selected_run]["jobs"][0]["run_attempt"] = 1 }
  end

  def test_existing_architecture_payloads_do_not_hide_a_missing_formula
    rejection(%r{Missing bottle pair: 0xsct/tap/imgui arm64_golden_gate}) do |data|
      data[:expected_bottles]["0xsct/tap/imgui"] = {
        "pkg_version" => "1.92.5",
        "tags"        => %w[arm64_golden_gate tahoe],
        "path"        => "Library/Taps/0xsct/homebrew-tap/Formula/imgui.rb",
      }
    end
  end

  def test_rejects_missing_formula_version_tag_and_archive_hash
    rejection(%r{Missing bottle pair: 0xsct/tap/raygui arm64_golden_gate}) do |data|
      data[:downloaded_bottles].shift
    end
    rejection(/Bottle version mismatch/) { |data| data[:downloaded_bottles][0]["formula"]["pkg_version"] = "9.0" }
    rejection(/Unexpected bottle tag/) { |data| data[:downloaded_bottles][0]["tag"] = "arm64_tahoe" }
    rejection(/Bottle archive hash mismatch/) do |data|
      File.write(data[:downloaded_bottles][0]["archive_path"], "tampered")
    end
    rejection(/Bottle archive hash mismatch/) { |data| data[:downloaded_bottles][0]["sha256"] = "0" * 64 }
    rejection(/Bottle archive filename mismatch/) do |data|
      data[:downloaded_bottles][0]["bottle"]["tags"]["arm64_golden_gate"]["local_filename"] = "../secret.tar.gz"
    end
    rejection(/Bottle formula path mismatch/) do |data|
      data[:downloaded_bottles][0]["formula"]["path"] = "../secret.rb"
    end
    rejection(/Bottle release URL mismatch/) do |data|
      data[:downloaded_bottles][0]["bottle"]["root_url"] = "https://evil.invalid"
    end
    rejection(/Duplicate bottle pair/) { |data| data[:downloaded_bottles] << data[:downloaded_bottles][0] }
  end

  def test_rejects_narrowed_expected_set_and_branch_policy
    rejection(/Invalid required tags/) { |data| data[:expected_bottles]["0xsct/tap/raygui"]["tags"] = ["tahoe"] }
    rejection(/Protected main branch/) { |data| data[:branch]["protected"] = true }
    rejection(/Unknown main branch policy/) { |data| data[:branch].delete("protected") }
    rejection(/Repository write permission required/) { |data| data[:branch]["permissions"]["push"] = false }
    rejection(/main branch required/) { |data| data[:branch]["name"] = "release" }
    rejection(/Pull request must target main/) { |data| data[:pull_request]["base"]["ref"] = "release" }
  end

  def test_retained_payload_reader_rejects_orphan_archives_and_symlinks
    with_publication do |data|
      directory = File.dirname(data[:downloaded_bottles][0]["archive_path"])
      data[:downloaded_bottles].each_with_index do |entry, index|
        record = JSON.generate(entry["name"] => entry.slice("formula", "bottle"))
        File.write("#{directory}/#{index}.bottle.json", record)
      end
      assert_equal 3, TapCI.downloaded_bottles(directory).size
      File.write("#{directory}/orphan.bottle.tar.gz", "orphan")
      error = assert_raises(ArgumentError) { TapCI.downloaded_bottles(directory) }
      assert_match(/Unpaired bottle archives/, error.message)
      File.delete("#{directory}/orphan.bottle.tar.gz")
      archive = data[:downloaded_bottles][0]["archive_path"]
      File.rename(archive, "#{archive}.original")
      File.symlink("#{archive}.original", archive)
      error = assert_raises(ArgumentError) { TapCI.downloaded_bottles(directory) }
      assert_match(/Unsafe retained bottle file/, error.message)
    end
  end

  def test_rejects_hidden_empty_tag_record_before_publication
    with_retained_publication do |data, directory|
      hidden = {
        "formula" => {
          "name"        => "hidden",
          "pkg_version" => "0.1",
          "path"        => "Library/Taps/0xsct/homebrew-tap/Formula/hidden.rb",
        },
        "bottle"  => {
          "root_url" => "https://github.com/0xsct/homebrew-tap/releases/download/hidden-0.1",
          "rebuild"  => 0,
          "tags"     => {},
        },
      }
      File.write("#{directory}/hidden.bottle.json", JSON.generate("0xsct/tap/hidden" => hidden))
      error = assert_raises(ArgumentError) do
        entries = TapCI.downloaded_bottles(directory)
        TapCI.verify_publication!(**data, downloaded_bottles: entries)
      end
      assert_match(/Invalid bottle tags/, error.message)
    end
  end

  def test_rejects_non_hash_and_empty_retained_documents
    [nil, [], "metadata", {}].each do |document|
      with_retained_publication do |_data, directory|
        File.write("#{directory}/invalid.bottle.json", JSON.generate(document))
        error = assert_raises(ArgumentError) { TapCI.downloaded_bottles(directory) }
        assert_match(/Invalid bottle document/, error.message)
      end
    end
  end

  def test_rejects_malformed_retained_records_and_tag_maps
    [nil, [], "metadata", {}].each do |record|
      with_retained_publication do |_data, directory|
        File.write("#{directory}/invalid.bottle.json", JSON.generate("0xsct/tap/hidden" => record))
        error = assert_raises(ArgumentError) { TapCI.downloaded_bottles(directory) }
        assert_match(/Invalid bottle record/, error.message)
      end
    end
    [["formula", "name"], ["formula", "pkg_version"], ["formula", "path"],
     ["bottle", "root_url"], ["bottle", "rebuild"]].each do |section, field|
      with_retained_publication do |data, directory|
        entry = data[:downloaded_bottles].first
        record = JSON.parse(JSON.generate(entry.slice("formula", "bottle")))
        record.fetch(section).delete(field)
        File.write("#{directory}/invalid.bottle.json", JSON.generate(entry.fetch("name") => record))
        error = assert_raises(ArgumentError) { TapCI.downloaded_bottles(directory) }
        assert_match(/Invalid bottle record/, error.message)
      end
    end
    [nil, [], "tahoe", {}].each do |tags|
      with_retained_publication do |data, directory|
        entry = data[:downloaded_bottles].first
        record = JSON.parse(JSON.generate(entry.slice("formula", "bottle")))
        record.fetch("bottle")["tags"] = tags
        File.write("#{directory}/invalid.bottle.json", JSON.generate(entry.fetch("name") => record))
        error = assert_raises(ArgumentError) { TapCI.downloaded_bottles(directory) }
        assert_match(/Invalid bottle tags/, error.message)
      end
    end
    [nil, [], {}].each do |tag_metadata|
      with_retained_publication do |data, directory|
        entry = data[:downloaded_bottles].first
        record = JSON.parse(JSON.generate(entry.slice("formula", "bottle")))
        record.fetch("bottle")["tags"] = { entry.fetch("tag") => tag_metadata }
        File.write("#{directory}/invalid.bottle.json", JSON.generate(entry.fetch("name") => record))
        error = assert_raises(ArgumentError) { TapCI.downloaded_bottles(directory) }
        assert_match(/Invalid bottle tag metadata/, error.message)
      end
    end
  end

  private

  def with_replaced_method(receiver, name, replacement)
    original = receiver.method(name)
    receiver.singleton_class.send(:define_method, name, replacement)
    yield
  ensure
    receiver.singleton_class.send(:define_method, name, original)
  end

  def with_publishing_environment(repository)
    previous = ENV.to_h.slice("GITHUB_REF", "GITHUB_REPOSITORY")
    ENV["GITHUB_REF"] = "refs/heads/main"
    ENV["GITHUB_REPOSITORY"] = repository
    yield
  ensure
    %w[GITHUB_REF GITHUB_REPOSITORY].each do |key|
      previous.key?(key) ? ENV[key] = previous.fetch(key) : ENV.delete(key)
    end
  end

  def native_formula_metadata
    # Projected brew info --json=v2 fields; core dependency edges match the 2026-11-13 API.
    tap = [
      ["imgui", "1.93.0", 0, ["0xsct/tap/sdl2-static"], ["pkgconf"], ["pkgconf"]],
      ["lldb-sct", "23.1.5", 1, %w[0xsct/tap/llvm-sct python@3.15 xz z3 zstd], %w[cmake ninja swig], []],
      ["llvm-sct", "23.1.5", 1, %w[zstd z3], %w[cmake ninja python@3.15], ["python@3.15"]],
      ["raygui", "5.0", 0, ["0xsct/tap/raylib-static"], [], ["pkgconf"]],
      ["raylib-static", "6.2", 0, [], ["cmake"], ["pkgconf"]],
      ["sdl2-static", "2.32.10", 0, [], ["cmake"], ["pkgconf"]],
      ["sdl3-static", "3.4.20", 0, [], ["cmake"], ["pkgconf"]],
    ].map do |name, version, revision, dependencies, build_dependencies, test_dependencies|
      {
        "name" => name, "full_name" => "0xsct/tap/#{name}", "tap" => "0xsct/tap", "aliases" => [],
        "versions" => { "stable" => version }, "revision" => revision, "installed" => [],
        "dependencies" => dependencies, "build_dependencies" => build_dependencies,
        "test_dependencies" => test_dependencies, "recommended_dependencies" => []
      }
    end
    core = [
      ["cmake", "4.5.0", [], [], []],
      ["python@3.15", "3.15.2", %w[ca-certificates mpdecimal openssl@4 sqlite xz zstd], ["pkgconf"], []],
      ["z3", "5.4.1", [], %w[cmake python@3.15], ["python@3.15"]],
      ["swig", "4.5.1", ["pcre2"], [], []],
    ].map do |name, version, dependencies, build_dependencies, test_dependencies|
      {
        "name" => name, "full_name" => name, "tap" => "homebrew/core",
        "versions" => { "stable" => version }, "revision" => 0, "installed" => [],
        "aliases" => (name == "python@3.15") ? %w[python python3 python@3] : [],
        "dependencies" => dependencies, "build_dependencies" => build_dependencies,
        "test_dependencies" => test_dependencies, "recommended_dependencies" => [],
        "bottle" => { "stable" => { "files" => { "arm64_golden_gate" => {}, "arm64_tahoe" => {} } } }
      }
    end
    tap + core
  end

  def with_retained_publication
    with_publication do |data|
      directory = File.dirname(data[:downloaded_bottles].first.fetch("archive_path"))
      data[:downloaded_bottles].each_with_index do |entry, index|
        record = JSON.generate(entry.fetch("name") => entry.slice("formula", "bottle"))
        File.write("#{directory}/#{index}.bottle.json", record)
      end
      yield data, directory
    end
  end

  def with_repository
    Dir.mktmpdir("tap-ci-test-", File.expand_path("../..", __dir__)) do |repository|
      git = lambda do |*args|
        stdout, stderr, status = Open3.capture3("git", *args, chdir: repository)
        assert status.success?, stderr
        stdout.strip
      end
      git.call("init", "--quiet")
      git.call("config", "user.name", "Tap CI Test")
      git.call("config", "user.email", "tap-ci-test@example.invalid")
      File.write("#{repository}/README.md", "fixture\n")
      yield repository, git
    end
  end

  def commit_fixture(git)
    git.call("add", "--all")
    git.call("commit", "--quiet", "-m", "Fixture change")
    git.call("rev-parse", "HEAD")
  end

  def rejection(message)
    with_publication do |data|
      yield data
      error = assert_raises(ArgumentError) { TapCI.verify_publication!(**data) }
      assert_match message, error.message
    end
  end

  def with_publication
    Dir.mktmpdir("tap-ci-bottles-", File.expand_path("../..", __dir__)) do |directory|
      sha = "a" * 40
      expected = {
        "0xsct/tap/raygui"   => {
          "pkg_version" => "4.0",
          "tags"        => %w[arm64_golden_gate tahoe],
          "path"        => "Library/Taps/0xsct/homebrew-tap/Formula/raygui.rb",
        },
        "0xsct/tap/llvm-sct" => {
          "pkg_version" => "21.1.8_1",
          "tags"        => ["tahoe"],
          "path"        => "Library/Taps/0xsct/homebrew-tap/Formula/llvm-sct.rb",
        },
      }
      entries = expected.flat_map do |name, metadata|
        metadata.fetch("tags").map do |tag|
          short_name = Utils.name_from_full_name(name)
          filename = "#{short_name}--#{metadata.fetch("pkg_version")}.#{tag}.bottle.tar.gz"
          archive = "#{directory}/#{filename}"
          File.write(archive, "#{name} #{tag}\n")
          digest = Digest::SHA256.file(archive).hexdigest
          formula = metadata.slice("pkg_version", "path")
          formula["name"] = short_name
          formula["tap_git_revision"] = sha
          root_url = "https://github.com/0xsct/homebrew-tap/releases/download/" \
                     "#{short_name}-#{metadata.fetch("pkg_version")}"
          {
            "name"         => name,
            "tag"          => tag,
            "archive_path" => archive,
            "sha256"       => digest,
            "formula"      => formula,
            "bottle"       => {
              "root_url" => root_url,
              "rebuild"  => 0,
              "tags"     => {
                tag => {
                  "local_filename" => filename,
                  "filename"       => filename.sub("--", "-"),
                  "sha256"         => digest,
                },
              },
            },
          }
        end
      end
      jobs = [["arm64", "xcode-27"], ["x86_64", "macos-26-intel"]].map do |arch, runner|
        { "name" => "native (#{arch})", "labels" => [runner], "run_id" => 42, "run_attempt" => 2,
          "status" => "completed", "conclusion" => "success" }
      end
      yield(
        pull_request:       {
          "number" => 7,
          "state"  => "open",
          "head"   => { "sha" => sha },
          "base"   => { "ref" => "main" },
        },
        expected_sha:       sha,
        selected_run:       {
          "id"          => 42,
          "run_attempt" => 2,
          "head_sha"    => sha,
          "status"      => "completed",
          "conclusion"  => "success",
          "path"        => ".github/workflows/tests.yml",
          "jobs"        => jobs,
          "latest"      => {
            "id"          => 42,
            "run_attempt" => 2,
            "head_sha"    => sha,
            "status"      => "completed",
            "conclusion"  => "success",
          },
        },
        expected_bottles:   expected,
        downloaded_bottles: entries,
        branch:             { "name" => "main", "protected" => false, "permissions" => { "push" => true } },
      )
    end
  end
end

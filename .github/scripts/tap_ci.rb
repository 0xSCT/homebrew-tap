# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# Select native tap packages and validate reviewed bottle publication before upload.
module TapCI
  TAP = "0xsct/tap"
  REPOSITORY = "0xsct/homebrew-tap"
  COMPILERS = %w[llvm-sct lldb-sct].freeze
  RUNNERS = { "arm64" => "xcode-27", "x86_64" => "macos-26-intel" }.freeze
  GRAPHICS_TAGS = %w[arm64_golden_gate tahoe].freeze

  module_function

  def brew_executable
    HOMEBREW_BREW_FILE.to_s
  end

  def command(*args, repository: Dir.pwd)
    args[0] = brew_executable if args.first == "brew"
    stdout, stderr, status = Open3.capture3(*args, chdir: repository)
    raise ArgumentError, "Command failed: #{args.first}: #{stderr}" unless status.success?

    stdout
  end

  def validate_sha!(sha)
    return if sha.is_a?(String) && sha.match?(/\A[0-9a-f]{40}\z/)

    raise ArgumentError, "Invalid commit SHA"
  end

  def changed_paths(base_sha:, head_sha:, repository:)
    validate_sha!(base_sha)
    validate_sha!(head_sha)
    current = command("git", "ls-tree", "-r", "--name-only", "-z", head_sha, repository:).split("\0")
    return current if base_sha == "0" * 40

    changed = command("git", "diff", "--no-renames", "--name-only", "-z", base_sha, head_sha, "--",
                      repository:).split("\0")
    current & changed
  end

  def package_names(paths, directory)
    paths.filter_map do |path|
      match = path.match(%r{\A#{directory}/(?:[a-z0-9]/)?([a-z0-9][a-z0-9+@._-]*)\.rb\z})
      match[1] if match
    end.uniq.sort
  end

  def changed_formulae(base_sha:, head_sha:, repository:)
    package_names(changed_paths(base_sha:, head_sha:, repository:), "Formula")
  end

  def added_formulae(base_sha:, head_sha:, repository:)
    paths = changed_paths(base_sha:, head_sha:, repository:)
    if base_sha != "0" * 40
      existing = command("git", "ls-tree", "-r", "--name-only", "-z", base_sha, repository:).split("\0")
      paths -= existing
    end
    package_names(paths, "Formula")
  end

  def platform_formulae(names, architecture)
    raise ArgumentError, "Unknown native architecture" unless RUNNERS.key?(architecture)

    (architecture == "arm64") ? names - COMPILERS : names
  end

  def repository_identity?(identity)
    identity.is_a?(String) && identity.downcase == REPOSITORY
  end

  def verify_native_environment!(environment:, architecture:, native_architecture:)
    raise ArgumentError, "GitHub Actions native job required" if environment["GITHUB_ACTIONS"] != "true"
    raise ArgumentError, "Unexpected native repository" unless repository_identity?(environment["GITHUB_REPOSITORY"])
    raise ArgumentError, "Unknown native architecture" unless RUNNERS.key?(architecture)
    raise ArgumentError, "Native architecture mismatch" if native_architecture != architecture

    nil
  end

  def qualified_formula_names(names)
    unless names.all? { |name| name.is_a?(String) && name.match?(/\A[a-z0-9][a-z0-9+@._-]*\z/) }
      raise ArgumentError, "Invalid selected formula"
    end

    names.map { |name| "#{TAP}/#{name}" }
  end

  def native_formulae(names:, formulae:)
    selected = qualified_formula_names(names)
    metadata = formulae.to_h { |formula| [formula.fetch("full_name"), formula] }
    ordered = []
    visiting = []
    dependency_fields = %w[dependencies build_dependencies test_dependencies recommended_dependencies]
    visit = lambda do |name|
      return if ordered.include?(name)
      raise ArgumentError, "Cyclic native formula dependencies" if visiting.include?(name)

      visiting << name
      formula = metadata.fetch(name)
      dependencies = dependency_fields.flat_map do |field|
        formula.fetch(field, [])
      end
      (dependencies & selected).each { |dependency| visit.call(dependency) }
      visiting.pop
      ordered << name
    end
    selected.each { |name| visit.call(name) }
    ordered.map { |name| name.delete_prefix("#{TAP}/") }
  end

  def native_commands(formula)
    name = formula.fetch("full_name")
    if !name.is_a?(String) || !name.match?(%r{\A0xsct/tap/[a-z0-9][a-z0-9+@._-]*\z})
      raise ArgumentError, "Invalid selected formula"
    end

    version = formula["pkg_version"] || formula.fetch("versions").fetch("stable")
    if !formula.key?("pkg_version") && formula.fetch("revision").positive?
      version = "#{version}_#{formula.fetch("revision")}"
    end
    if !version.is_a?(String) || !version.match?(/\A[a-zA-Z0-9+._-]+\z/)
      raise ArgumentError, "Invalid selected formula version"
    end

    commands = []
    # A clean CI root makes Homebrew retain its build dependencies and record bottle mode.
    unless formula.fetch("installed").empty?
      commands << ["brew", "uninstall", "--formula", "--force", "--ignore-dependencies", name]
    end
    commands << ["brew", "install", "--only-dependencies", "--include-test", "--build-from-source", name]
    commands << ["brew", "install", "--build-bottle", "--include-test", name]
    commands << ["brew", "test", name]
    root_url = "https://github.com/#{REPOSITORY}/releases/download/#{formula.fetch("name")}-#{version}"
    commands << ["brew", "bottle", "--json", "--root-url=#{root_url}", name]
    commands
  end

  def build_native(names:, architecture:, repository:)
    verify_native_environment!(environment: ENV, architecture: architecture,
                               native_architecture: command("uname", "-m", repository:).strip)
    require "formula"

    names = platform_formulae(names, architecture)
    formulae = qualified_formula_names(names).map do |full_name|
      formula = Formulary.factory(full_name)
      formula.to_hash.merge(
        "pkg_version"  => formula.pkg_version.to_s,
        "dependencies" => formula.deps.reject(&:optional?).map { |dependency| dependency.to_formula.full_name },
      )
    end
    metadata = formulae.to_h { |formula| [formula.fetch("name"), formula] }
    Dir.chdir(repository) do
      native_formulae(names: names, formulae: formulae).each do |name|
        native_commands(metadata.fetch(name)).each do |args|
          system(brew_executable, *args.drop(1), exception: true)
        end
      end
    end
  end

  def verify_branch!(branch)
    raise ArgumentError, "main branch required" if branch["name"] != "main"
    raise ArgumentError, "Unknown main branch policy" unless [true, false].include?(branch["protected"])
    raise ArgumentError, "Protected main branch" if branch["protected"]
    raise ArgumentError, "Repository write permission required" if branch.dig("permissions", "push") != true
  end

  def verify_run!(pull_request:, expected_sha:, selected_run:, architectures:)
    validate_sha!(expected_sha)
    raise ArgumentError, "PR head changed" if pull_request.dig("head", "sha") != expected_sha
    raise ArgumentError, "Pull request must be open" if pull_request["state"] != "open"
    raise ArgumentError, "Pull request must target main" if pull_request.dig("base", "ref") != "main"
    raise ArgumentError, "Wrong tests.yml workflow" if selected_run["path"] != ".github/workflows/tests.yml"

    latest = selected_run.fetch("latest")
    raise ArgumentError, "Newest tests.yml run changed" if latest["id"] != selected_run["id"]
    raise ArgumentError, "Run attempt changed" if latest["run_attempt"] != selected_run["run_attempt"]
    if selected_run["head_sha"] != expected_sha || latest["head_sha"] != expected_sha
      raise ArgumentError, "Run head mismatch"
    end

    if !selected_run["id"].is_a?(Integer) || !selected_run["id"].positive? ||
       !selected_run["run_attempt"].is_a?(Integer) || !selected_run["run_attempt"].positive? ||
       selected_run["status"] != "completed" || selected_run["conclusion"] != "success" ||
       latest["status"] != "completed" || latest["conclusion"] != "success"
      raise ArgumentError, "tests.yml run not successful"
    end

    architectures.each do |architecture|
      jobs = latest.fetch("jobs", selected_run.fetch("jobs")).select do |job|
        job["name"] == "native (#{architecture})"
      end
      raise ArgumentError, "Missing required native job: #{architecture}" if jobs.empty?
      raise ArgumentError, "Duplicate required native job: #{architecture}" unless jobs.one?

      job = jobs.first
      if job["run_id"] != selected_run["id"] || job["run_attempt"] != selected_run["run_attempt"]
        raise ArgumentError, "Native job attempt mismatch"
      end

      unless job.fetch("labels").include?(RUNNERS.fetch(architecture))
        raise ArgumentError, "Native runner mismatch: #{architecture}"
      end

      if job["status"] != "completed" || job["conclusion"] != "success"
        raise ArgumentError, "Required native job not successful: #{architecture}"
      end
    end
  end

  def verify_publication!(pull_request:, expected_sha:, selected_run:, expected_bottles:,
                          downloaded_bottles:, branch:)
    verify_branch!(branch)
    pairs = expected_pairs(expected_bottles)
    architectures = pairs.map { |_, tag| (tag == "tahoe") ? "x86_64" : "arm64" }.uniq
    verify_run!(pull_request:, expected_sha:, selected_run:, architectures:)
    verify_bottle_pairs!(expected_bottles:, downloaded_bottles:, pairs:)
  end

  def verify_native_bottles!(expected_bottles:, architecture:, directory:)
    raise ArgumentError, "Unknown native architecture" unless RUNNERS.key?(architecture)

    native_tag = (architecture == "arm64") ? "arm64_golden_gate" : "tahoe"
    pairs = expected_pairs(expected_bottles).select { |_, tag| tag == native_tag }
    verify_bottle_pairs!(expected_bottles:, downloaded_bottles: downloaded_bottles(directory), pairs:)
  end

  def expected_pairs(expected_bottles)
    require "bottle"

    expected_bottles.flat_map do |name, metadata|
      if !name.is_a?(String) || !name.match?(%r{\A0xsct/tap/[a-z0-9][a-z0-9+@._-]*\z}) ||
         !metadata.is_a?(Hash) || !metadata["pkg_version"].is_a?(String) ||
         !metadata["pkg_version"].match?(/\A[a-zA-Z0-9+._-]+\z/)
        raise ArgumentError, "Invalid expected formula metadata"
      end

      tags = COMPILERS.include?(Utils.name_from_full_name(name)) ? ["tahoe"] : GRAPHICS_TAGS
      if !metadata["tags"].is_a?(Array) || metadata["tags"].sort != tags.sort
        raise ArgumentError, "Invalid required tags: #{name}"
      end

      tags.map { |tag| [name, tag] }
    end
  end

  def verify_bottle_pairs!(expected_bottles:, downloaded_bottles:, pairs:)
    seen = []
    downloaded_bottles.each do |entry|
      name = entry.fetch("name")
      tag = entry.fetch("tag")
      metadata = expected_bottles[name]
      raise ArgumentError, "Unexpected bottled formula: #{name}" unless metadata
      raise ArgumentError, "Unexpected bottle tag: #{name} #{tag}" unless pairs.include?([name, tag])
      raise ArgumentError, "Duplicate bottle pair: #{name} #{tag}" if seen.include?([name, tag])

      formula = entry.fetch("formula")
      bottle = entry.fetch("bottle")
      short_name = Utils.name_from_full_name(name)
      version = metadata.fetch("pkg_version")
      raise ArgumentError, "Bottle version mismatch: #{name}" if formula["pkg_version"] != version
      if formula["path"] != metadata.fetch("path") || formula["name"] != short_name
        raise ArgumentError, "Bottle formula path mismatch: #{name}"
      end

      root_url = "https://github.com/#{REPOSITORY}/releases/download/#{short_name}-#{version}"
      raise ArgumentError, "Bottle release URL mismatch: #{name}" if bottle["root_url"] != root_url

      rebuild = bottle.fetch("rebuild")
      raise ArgumentError, "Invalid bottle rebuild" if !rebuild.is_a?(Integer) || rebuild.negative?

      filename = ::Bottle::Filename.new(
        short_name, PkgVersion.parse(version), Utils::Bottles.tag(tag.to_sym), rebuild
      )
      tag_metadata = bottle.fetch("tags").fetch(tag)
      if tag_metadata["local_filename"] != filename.to_s || tag_metadata["filename"] != filename.url_encode ||
         File.basename(entry.fetch("archive_path")) != filename.to_s
        raise ArgumentError, "Bottle archive filename mismatch: #{name} #{tag}"
      end

      archive = entry.fetch("archive_path")
      raise ArgumentError, "Unsafe retained bottle file" if !File.file?(archive) || File.symlink?(archive)

      checksum = tag_metadata.fetch("sha256")
      if !checksum.is_a?(String) || !checksum.match?(/\A[0-9a-f]{64}\z/) || checksum != entry["sha256"] ||
         checksum != Digest::SHA256.file(archive).hexdigest
        raise ArgumentError, "Bottle archive hash mismatch: #{name} #{tag}"
      end

      seen << [name, tag]
    end
    missing = pairs - seen
    raise ArgumentError, "Missing bottle pair: #{missing.first.join(" ")}" unless missing.empty?

    nil
  end

  def downloaded_bottles(directory)
    directory = File.realpath(directory)
    records = Dir.glob("#{directory}/*.bottle.json").flat_map do |json_path|
      raise ArgumentError, "Unsafe retained bottle file" if !File.file?(json_path) || File.symlink?(json_path)

      document = JSON.parse(File.read(json_path))
      if !document.is_a?(Hash) || document.empty?
        raise ArgumentError, "Invalid bottle document"
      end

      document.each { |name, metadata| validate_bottle_record!(name, metadata) }
      document.to_a
    end
    entries = records.flat_map do |name, metadata|
      metadata.fetch("bottle").fetch("tags").map do |tag, tag_metadata|
        filename = tag_metadata.fetch("local_filename")
        if filename != File.basename(filename) || !filename.end_with?(".tar.gz")
          raise ArgumentError, "Bottle archive filename mismatch"
        end

        archive = File.join(directory, filename)
        raise ArgumentError, "Unsafe retained bottle file" if !File.file?(archive) || File.symlink?(archive)

        { "name" => name, "tag" => tag, "formula" => metadata.fetch("formula"),
          "bottle" => metadata.fetch("bottle"), "archive_path" => archive,
          "sha256" => Digest::SHA256.file(archive).hexdigest }
      end
    end
    archives = Dir.glob("#{directory}/*.tar.gz")
    referenced = entries.map { |entry| entry.fetch("archive_path") }.uniq.sort
    raise ArgumentError, "Unpaired bottle archives" if archives != referenced

    entries
  rescue JSON::ParserError => e
    raise ArgumentError, "Invalid bottle document: #{e.message}"
  end

  def validate_bottle_record!(name, metadata)
    if !name.is_a?(String) || !name.match?(%r{\A0xsct/tap/[a-z0-9][a-z0-9+@._-]*\z}) ||
       !metadata.is_a?(Hash) || !metadata["formula"].is_a?(Hash) || !metadata["bottle"].is_a?(Hash)
      raise ArgumentError, "Invalid bottle record"
    end

    formula = metadata.fetch("formula")
    bottle = metadata.fetch("bottle")
    if %w[name pkg_version path].any? { |field| !formula[field].is_a?(String) || formula[field].empty? } ||
       !bottle["root_url"].is_a?(String) || bottle["root_url"].empty? ||
       !bottle["rebuild"].is_a?(Integer) || bottle["rebuild"].negative?
      raise ArgumentError, "Invalid bottle record"
    end

    tags = bottle["tags"]
    raise ArgumentError, "Invalid bottle tags" if !tags.is_a?(Hash) || tags.empty?

    required_fields = %w[local_filename filename sha256]
    tags.each do |tag, tag_metadata|
      raise ArgumentError, "Invalid bottle tag metadata" unless tag_metadata.is_a?(Hash)

      missing_fields = required_fields.any? do |field|
        !tag_metadata[field].is_a?(String) || tag_metadata[field].empty?
      end
      if !tag.is_a?(String) || tag.empty? || missing_fields
        raise ArgumentError, "Invalid bottle tag metadata"
      end
    end
  end

  def api(path)
    url = "#{GitHub::API_URL}/repos/#{REPOSITORY}"
    url += "/#{path}" unless path.empty?
    GitHub::API.open_rest(url)
  end

  def publication_snapshot(pull_request_number, expected_sha)
    pull_request = api("pulls/#{pull_request_number}")
    raise ArgumentError, "PR head changed" if pull_request.dig("head", "sha") != expected_sha
    raise ArgumentError, "Pull request must target main" if pull_request.dig("base", "ref") != "main"
    unless repository_identity?(pull_request.dig("base", "repo", "full_name"))
      raise ArgumentError, "Unexpected base repository"
    end

    user, repo = REPOSITORY.split("/")
    suites = GitHub.get_workflow_run(
      user, repo, pull_request_number, workflow_id: "tests.yml", head_sha: expected_sha
    ).first
    raise ArgumentError, "Missing tests.yml check suite" if suites.empty?

    run_id = suites.last.fetch("workflowRun").fetch("databaseId")
    run = api("actions/runs/#{run_id}")
    jobs = []
    jobs_url = "#{GitHub::API_URL}/repos/#{REPOSITORY}/actions/runs/#{run_id}/attempts/#{run.fetch("run_attempt")}/jobs"
    GitHub::API.paginate_rest(jobs_url, per_page: 100) do |page|
      jobs.concat(page.fetch("jobs"))
      break if page.fetch("jobs").length < 100
    end
    branch = api("branches/main")
    branch["permissions"] = api("").fetch("permissions")
    [pull_request, run.merge("jobs" => jobs), branch]
  end

  def expected_bottles(names)
    require "formula"

    Formulary.clear_cache
    names.to_h do |name|
      formula = Formulary.factory("#{TAP}/#{name}")
      [formula.full_name, {
        "pkg_version" => formula.pkg_version.to_s,
        "path"        => formula.tap_path.to_s.delete_prefix("#{HOMEBREW_REPOSITORY}/"),
        "tags"        => COMPILERS.include?(name) ? ["tahoe"] : GRAPHICS_TAGS,
      }]
    end
  end

  def publish(pull_request_number, expected_sha)
    unless pull_request_number.match?(/\A[1-9][0-9]*\z/)
      raise ArgumentError, "Invalid pull request number"
    end

    validate_sha!(expected_sha)
    raise ArgumentError, "Publisher must run from main" if ENV.fetch("GITHUB_REF") != "refs/heads/main"
    unless repository_identity?(ENV.fetch("GITHUB_REPOSITORY"))
      raise ArgumentError, "Unexpected publishing repository"
    end

    require "formula"
    require "utils/github"
    require "utils/github/artifacts"
    pull_request, selected_run, branch = publication_snapshot(pull_request_number, expected_sha)
    verify_branch!(branch)
    verify_run!(pull_request:, expected_sha:,
                selected_run: selected_run.merge("latest" => selected_run), architectures: [])
    repository = Tap.fetch(TAP).path.to_s
    main_sha = branch.fetch("commit").fetch("sha")
    if command("git", "rev-parse", "HEAD", repository:).strip != main_sha
      raise ArgumentError, "Trusted checkout is not current main"
    end

    command("git", "fetch", "origin", expected_sha, repository:)
    base = command("git", "merge-base", "origin/main", expected_sha, repository:).strip
    names = changed_formulae(base_sha: base, head_sha: expected_sha, repository:)
    command("git", "checkout", "--detach", expected_sha, repository:)
    begin
      expected = expected_bottles(names)
    ensure
      command("git", "checkout", "main", repository:)
      Formulary.clear_cache
    end
    architectures = expected.values.flat_map { |metadata| metadata.fetch("tags") }.uniq.map do |tag|
      (tag == "tahoe") ? "x86_64" : "arm64"
    end
    verify_run!(pull_request:, expected_sha:,
                selected_run: selected_run.merge("latest" => selected_run), architectures:)
    pattern = "bottles_{arm64,x86_64}_#{selected_run.fetch("id")}_#{selected_run.fetch("run_attempt")}"
    output = File.join(ENV.fetch("RUNNER_TEMP"), "tap-pr-pull-output")
    File.write(output, "")
    previous_output = ENV.fetch("GITHUB_OUTPUT")
    ENV["GITHUB_OUTPUT"] = output
    begin
      # pr-pull downloads once and cherry-picks, but --no-upload creates no bottle commit.
      system(brew_executable, "pr-pull", "--no-upload", "--retain-bottle-dir", "--tap=#{TAP}",
             "--head-sha=#{expected_sha}", "--artifact-pattern=#{pattern}", pull_request_number, exception: true)
    ensure
      ENV["GITHUB_OUTPUT"] = previous_output
    end
    bottle_path = File.readlines(output, chomp: true).filter_map do |line|
      line.delete_prefix("bottle_path=") if line.start_with?("bottle_path=")
    end.last
    raise ArgumentError, "Missing retained bottle directory" unless bottle_path

    current_request, current_run, current_branch = publication_snapshot(pull_request_number, expected_sha)
    if current_branch.dig("commit", "sha") != branch.dig("commit", "sha")
      raise ArgumentError, "main changed during publication"
    end

    selected_run["latest"] = current_run
    verify_publication!(pull_request: current_request, expected_sha:, selected_run:, expected_bottles: expected,
                        downloaded_bottles: downloaded_bottles(bottle_path), branch: current_branch)
    # Hashing large compiler bottles takes time; check live policy and run again immediately before upload.
    final_request, final_run, final_branch = publication_snapshot(pull_request_number, expected_sha)
    verify_branch!(final_branch)
    verify_run!(pull_request: final_request, expected_sha:,
                selected_run: selected_run.merge("latest" => final_run), architectures:)
    raise ArgumentError, "main changed during publication" if final_branch.dig("commit", "sha") != main_sha

    unless expected.empty?
      Dir.chdir(bottle_path) { system(brew_executable, "pr-upload", exception: true) }
      File.open(previous_output, "a") { |file| file.puts "bottle_path=#{bottle_path}" }
    end
    # A normal push rejects concurrent changes and branch policy; never force or bypass.
    system("git", "-C", repository, "push", "origin", "HEAD:main", exception: true)
  end

  def remote_casks(base_sha:, head_sha:, repository:)
    names = package_names(changed_paths(base_sha:, head_sha:, repository:), "Casks")
    names.select do |name|
      info = JSON.parse(command("brew", "info", "--json=v2", "--cask", "#{TAP}/#{name}", repository:))
      info.fetch("casks").one? && info.fetch("casks").first.fetch("url").start_with?("https://")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    case action = ARGV.shift
    when "changed-formulae", "added-formulae"
      base, head, architecture = ARGV
      names = if action == "added-formulae"
        TapCI.added_formulae(base_sha: base, head_sha: head, repository: Dir.pwd)
      else
        TapCI.changed_formulae(base_sha: base, head_sha: head, repository: Dir.pwd)
      end
      puts (architecture ? TapCI.platform_formulae(names, architecture) : names).join(",")
    when "remote-casks"
      base, head = ARGV
      puts TapCI.remote_casks(base_sha: base, head_sha: head, repository: Dir.pwd).join(",")
    when "build-native", "verify-native"
      architecture, selection = ARGV
      names = TapCI.platform_formulae(selection.to_s.split(","), architecture)
      if action == "build-native"
        TapCI.build_native(names: names, architecture: architecture, repository: Dir.pwd)
      else
        TapCI.verify_native_bottles!(
          expected_bottles: TapCI.expected_bottles(names), architecture: architecture, directory: Dir.pwd,
        )
      end
    when "publish"
      TapCI.publish(*ARGV)
    else
      raise ArgumentError, "Usage: tap_ci.rb {changed-formulae|added-formulae} BASE HEAD [ARCH] | " \
                           "remote-casks BASE HEAD | {build-native|verify-native} ARCH FORMULAE | publish PR SHA"
    end
  rescue ArgumentError, KeyError, JSON::ParserError => e
    warn e.message
    exit 1
  end
end

# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "socket"
require "tmpdir"
require "yaml"

# The review trail CI checks (`.github/review-trail/check.py`, run by
# `.github/workflows/review-trail.yml`): a pull request that changes a path on the risk list
# passes only with `Review: <agent> @ <head SHA> — AKCEPTACJA` for its current head, in its
# description or a member's comment (the rule is "Reviews" in minos-moderation/minos,
# docs/claude/sessions.md). The script runs as the workflow runs it, on synthetic events,
# path lists and comments, and once against a fake of GitHub's API for the comments it reads
# itself. A port of `tests/Repo/ReviewTrailTest.php` in the PHP plugins.
#
# Plain Ruby: it runs in the standalone tier and inside Discourse's harness alike, so it
# defines no top-level constant. It needs python3 and git; without them it is skipped, and
# CI's standalone tier fails on a skip.
RSpec.describe "The review trail" do
  trail_head = "0123456789abcdef0123456789abcdef01234567"
  old_head = "fedcba9876543210fedcba9876543210fedcba98"
  risk_file = "lib/minos_moderation/signature.rb"
  risk_dir = "lib/minos_moderation/"
  exempt_file = "docs/development.md"

  # The same values for the helpers below (a `def` sees no local of the block).
  let(:trail_head) { trail_head }
  let(:old_head) { old_head }
  let(:risk_file) { risk_file }
  let(:risk_dir) { risk_dir }
  let(:exempt_file) { exempt_file }
  let(:root) { File.expand_path("../..", __dir__) }
  let(:check_py) { File.join(root, ".github/review-trail/check.py") }
  let(:exempt) { File.join(root, ".github/review-trail/exempt-paths.txt") }
  let(:workflow_path) { File.join(root, ".github/workflows/review-trail.yml") }

  before do
    tools = %w[python3 git bash].all? { |tool| system("command -v #{tool} > /dev/null 2>&1") }
    skip "python3, git and bash are needed: CI runs the check with them" unless tools
  end

  around do |example|
    Dir.mktmpdir("minos-discourse-trail-test-") do |dir|
      @dir = dir
      example.run
    end
  end

  # The workflow as a Hash. YAML 1.1 reads the key `on` as true; the GitHub runner reads it
  # as the trigger, so both spellings are taken.
  def workflow
    YAML.safe_load(File.read(workflow_path, encoding: "UTF-8"))
  end

  def trigger(parsed)
    parsed.key?("on") ? parsed["on"] : parsed[true]
  end

  # The Sonnet agent's risk markers, as the rules spec pins them (its `let`).
  def sonnet_risk_markers
    source = File.read(File.join(root, "spec/repo/claude_rules_spec.rb"), encoding: "UTF-8")
    match = source.match(/let\(:sonnet_risk_markers\) do\s*%w\[(.*?)\]/m)
    expect(match).not_to be_nil, "the rules spec has no sonnet_risk_markers list"
    markers = match[1].split
    # The guard: the list read is the real one, not an empty or a partial match.
    expect(markers).to include(".github/", ".claude/", "CLAUDE.md")
    markers
  end

  # The changed paths that stand for a marker: a folder's file, the path itself, and every
  # file of the repository a bare file name matches.
  def paths_for(marker)
    return ["#{marker}x.rb"] if marker.end_with?("/")
    return [marker] if marker.include?("/")
    found = Dir.glob("**/#{marker}", base: root).reject { |path| path.start_with?("vendor/", "tmp/", ".git/") }
    expect(found).not_to be_empty, "the risk marker #{marker} names no file"
    ([marker] + found).uniq
  end

  def capture(env, *command, chdir: nil, stdin: "")
    options = { stdin_data: stdin }
    options[:chdir] = chdir if chdir
    if env
      options[:unsetenv_others] = true
      out, err, status = Open3.capture3(env, *command, **options)
    else
      out, err, status = Open3.capture3(*command, **options)
    end
    # The check and git write UTF-8, whatever the locale says.
    [status.exitstatus, out.force_encoding(Encoding::UTF_8), err.force_encoding(Encoding::UTF_8)]
  end

  def run_check(arguments, env = nil)
    capture(env, "python3", "-I", check_py, *arguments)
  end

  def write_inputs(paths, comments, body, author)
    event = { "action" => "edited", "pull_request" => {
      "number" => 7, "body" => body, "author_association" => author,
      "head" => { "sha" => trail_head }, "base" => { "sha" => old_head },
    } }
    File.write(File.join(@dir, "event.json"), JSON.generate(event))
    File.write(File.join(@dir, "paths.txt"), paths.join("\n") + "\n")
    File.write(File.join(@dir, "comments.json"), JSON.generate(comments)) unless comments.nil?
  end

  # Runs the check on a pull request event for the head, with the comments given.
  def check(paths, comments, body, author = "MEMBER")
    write_inputs(paths, comments, body, author)
    run_check(["--event", File.join(@dir, "event.json"), "--paths", File.join(@dir, "paths.txt"),
               "--exempt", exempt, "--comments", File.join(@dir, "comments.json")])
  end

  def git(repo, *arguments)
    status, out, err = capture({ "HOME" => @dir, "PATH" => ENV.fetch("PATH", ""), "GIT_CONFIG_NOSYSTEM" => "1" },
                               "git", "-c", "user.name=test", "-c", "user.email=test@example.invalid",
                               "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", *arguments, chdir: repo)
    expect(status).to eq(0), "git #{arguments.join(" ")}: #{err}"
    out.strip
  end

  # A repository on its base commit (with the review trail's files or without), then a
  # branch for the pull request's change: the stand-in for GitHub the step fetches from.
  def repository(with_trail, exempt_text = nil)
    repo = File.join(@dir, "repo-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(File.join(repo, risk_dir))
    FileUtils.mkdir_p(File.join(repo, "docs"))
    File.write(File.join(repo, risk_file), "# frozen_string_literal: true\n")
    File.write(File.join(repo, exempt_file), "# A\n")
    git(repo, "init", "-q", "-b", "main")
    paths = [risk_file, exempt_file]
    if with_trail
      FileUtils.mkdir_p(File.join(repo, ".github/review-trail"))
      FileUtils.cp(check_py, File.join(repo, ".github/review-trail/check.py"))
      if exempt_text.nil?
        FileUtils.cp(exempt, File.join(repo, ".github/review-trail/exempt-paths.txt"))
      else
        File.write(File.join(repo, ".github/review-trail/exempt-paths.txt"), exempt_text)
      end
      paths += [".github/review-trail/check.py", ".github/review-trail/exempt-paths.txt"]
    end
    git(repo, "add", "--", *paths)
    git(repo, "commit", "-q", "-m", "base")
    git(repo, "checkout", "-q", "-b", "pr")
    repo
  end

  # Commits the work tree's changes as the pull request's head, makes the runner's checkout
  # (the base branch alone, as actions/checkout fetches it for `pull_request_target`) and
  # runs the workflow's step there. Returns the exit status, the output and the checkout.
  def run_step(repo, message)
    git(repo, "add", "--", ".")
    git(repo, "commit", "-q", "-m", message)
    base = git(repo, "rev-parse", "main")
    head = git(repo, "rev-parse", "HEAD")
    runner = "#{repo}.checkout"
    FileUtils.mkdir_p(runner)
    git(runner, "init", "-q", "-b", "main")
    git(runner, "remote", "add", "origin", repo)
    git(runner, "fetch", "-q", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
    git(runner, "checkout", "-q", "-B", "main", "origin/main")
    File.write("#{repo}.event.json", JSON.generate("pull_request" => {
      "number" => 7, "body" => nil, "author_association" => "MEMBER",
      "head" => { "sha" => head }, "base" => { "sha" => base },
    }))
    temp = "#{repo}.runner"
    FileUtils.mkdir_p(temp)
    script = workflow.dig("jobs", "trail", "steps", 1, "run").to_s
    expect(script).not_to be_empty, "the step has no script"
    env = api_env.merge("BASE_SHA" => base, "HEAD_SHA" => head, "GITHUB_EVENT_PATH" => "#{repo}.event.json",
                        "RUNNER_TEMP" => temp, "HOME" => @dir, "GIT_CONFIG_NOSYSTEM" => "1")
    status, out, err = capture(env, "bash", "-e", "-c", script, chdir: runner)
    [status, out + err, runner]
  end

  # What the check needs to read the fake API.
  def api_env
    { "GITHUB_API_URL" => "http://127.0.0.1:#{@api_port}", "GITHUB_REPOSITORY" => "minos-moderation/plugin-discourse",
      "GITHUB_TOKEN" => "test-token", "PATH" => ENV.fetch("PATH", "") }
  end

  # A fake of GitHub's API that lists the comments of pull request 7, page by page, to the
  # test token only, and logs every request into @api_log, for the block's duration.
  def with_fake_api(comments)
    server = TCPServer.new("127.0.0.1", 0)
    @api_port = server.addr[1]
    @api_log = []
    thread = Thread.new do
      loop do
        client = server.accept
        begin
          request = client.gets.to_s
          headers = {}
          while (line = client.gets) && line != "\r\n"
            name, value = line.split(":", 2)
            headers[name.downcase] = value.to_s.strip if value
          end
          uri = request.split(" ")[1].to_s
          auth = headers["authorization"].to_s
          @api_log << "#{uri} #{auth}"
          page = uri.match(%r{\A/repos/minos-moderation/plugin-discourse/issues/7/comments\?per_page=100&page=(\d+)\z})
          code, body =
            if auth != "Bearer test-token"
              [401, "{}"]
            elsif page.nil?
              [404, "{}"]
            else
              [200, JSON.generate(comments[(page[1].to_i - 1) * 100, 100] || [])]
            end
          client.write("HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\n" \
                       "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        ensure
          client.close
        end
      end
    end
    yield
  ensure
    thread&.kill
    server&.close
  end

  # The lines of a log that the runner reads as commands: those that start with `::` once
  # the leading whitespace is trimmed, and those that hold the legacy `##[`.
  def command_lines(log)
    log.split(/\r\n|\r|\n/).filter_map do |line|
      # [[:space:]] is Unicode White_Space here: every \p{Z} included.
      trimmed = line.sub(/\A[[:space:]]+/, "")
      trimmed if trimmed.start_with?("::") || line.include?("##[")
    end
  end

  # Every path a risk marker of the rules spec names needs a review, and what the Sonnet
  # agent may change needs none: the exempt list and the agents' risk list are one list.
  it "asks a review for every risk marker and none for the Sonnet agent's scope" do
    paths = sonnet_risk_markers.flat_map { |marker| paths_for(marker) }
    # CLAUDE.md on every level; the locales, whose keys are never the Sonnet agent's; the
    # test data the specs prove the plugin with, the gateway's vector among it.
    paths += %w[
      docs/CLAUDE.md lib/minos_moderation/CLAUDE.md config/locales/server.pl_PL.yml config/locales/client.en.yml
      spec/fixtures/signature.json spec/fixtures/reader_view.json spec/repo/claude_rules_spec.rb
      spec/repo/review_trail_spec.rb lib/minos_moderation/webhook_payload.rb config/routes.rb plugin.rb
      Gemfile Gemfile.lock LICENSE assets/javascripts/x.js
    ]
    paths.each do |path|
      status, out = check([path], [], nil)
      expect(status).to eq(1), "#{path} must need a review: #{out}"
    end
    ["README.md", "docs/development.md", "docs/notes.md"].each do |path|
      status, out = check([path], [], nil)
      expect(status).to eq(0), "#{path} is the Sonnet agent's: #{out}"
      expect(out).to include("No changed path is on the risk list")
    end
  end

  accept = "Review: przeglad-bezpieczenstwa @ #{trail_head} — AKCEPTACJA"
  member = lambda do |body, role = "MEMBER"|
    { "body" => body, "author_association" => role, "user" => { "login" => "owner-login" } }
  end
  {
    "no line" => [nil, [], 1],
    "in the description" => ["Agent: programista (Opus)\n\n#{accept}", [], 0],
    "in a member's comment, the SHA abbreviated to 12" =>
      [nil, [member.call("Review: przeglad-bezpieczenstwa @ #{trail_head[0, 12]} — AKCEPTACJA")], 0],
    "the SHA abbreviated to 8" =>
      [nil, [member.call("Review: przeglad-bezpieczenstwa @ #{trail_head[0, 8]} — AKCEPTACJA")], 1],
    "the SHA abbreviated to 7" =>
      [nil, [member.call("Review: przeglad-bezpieczenstwa @ #{trail_head[0, 7]} — AKCEPTACJA")], 1],
    "for an older head" => [nil, [member.call("Review: przeglad-bezpieczenstwa @ #{old_head} — AKCEPTACJA")], 1],
    "a SHA too short to name a commit" => [nil, [member.call("Review: przeglad-bezpieczenstwa @ 012345 — AKCEPTACJA")], 1],
    "changes asked" => [nil, [member.call("Review: przeglad-bezpieczenstwa @ #{trail_head} — POPRAWKI")], 1],
    "changes asked after the acceptance" =>
      [accept, [member.call("Review: przeglad-bezpieczenstwa @ #{trail_head} - POPRAWKI (1 major)")], 1],
    "accepted after changes asked" =>
      [nil, [member.call("Review: x @ #{trail_head} — POPRAWKI"),
             member.call("Re-check.\nReview: przeglad-bezpieczenstwa @ #{trail_head} – AKCEPTACJA")], 0],
    "by someone without a role in the repository" => [nil, [member.call(accept, "NONE")], 1],
    "by a contributor" => [nil, [member.call(accept, "CONTRIBUTOR")], 1],
    "quoted inside a sentence" => [nil, [member.call("as in: #{accept}")], 1],
  }.each do |name, (body, comments, expected)|
    it "passes a risk path only with an acceptance of the current head: #{name}" do
      status, out = check([risk_file, "README.md"], comments, body)
      expect(status).to eq(expected), out
      expect(out).to include(risk_file)
    end
  end

  it "does not count a description by someone without a role" do
    status, out = check(["#{risk_dir}x.rb"], [], accept, "CONTRIBUTOR")
    expect(status).to eq(1), out
  end

  {
    "no argument" => [],
    "a missing event" => ["--event", "{dir}/none.json", "--paths", "{dir}/paths.txt", "--exempt", "{exempt}",
                          "--comments", "{dir}/comments.json"],
    "an exempt list without a pattern" => ["--event", "{dir}/event.json", "--paths", "{dir}/paths.txt", "--exempt",
                                           "{dir}/empty.txt", "--comments", "{dir}/comments.json"],
    "comments that are no list" => ["--event", "{dir}/event.json", "--paths", "{dir}/paths.txt", "--exempt", "{exempt}",
                                    "--comments", "{dir}/event.json"],
  }.each do |name, arguments|
    it "exits 2 on bad input: #{name}" do
      write_inputs(["#{risk_dir}x.rb"], [], nil, "MEMBER")
      File.write(File.join(@dir, "comments.json"), "[]")
      File.write(File.join(@dir, "empty.txt"), "# only a comment\n\n")
      status, out, err = run_check(arguments.map { |a| a.sub("{dir}", @dir).sub("{exempt}", exempt) })
      expect(status).to eq(2), out + err
    end
  end

  # Without `--comments` the script reads every page of the comments from the API, with the
  # token, as in CI; the acceptance on the second page counts.
  it "reads the comments from the API page by page" do
    comments = Array.new(100) { |i| { "body" => "comment #{i}", "author_association" => "MEMBER", "user" => { "login" => "a" } } }
    comments << { "body" => "Review: przeglad-bezpieczenstwa @ #{trail_head} — AKCEPTACJA",
                  "author_association" => "MEMBER", "user" => { "login" => "owner-login" } }
    with_fake_api(comments) do
      write_inputs(["#{risk_dir}x.rb"], nil, nil, "MEMBER")
      arguments = ["--event", File.join(@dir, "event.json"), "--paths", File.join(@dir, "paths.txt"), "--exempt", exempt]
      status, out, err = run_check(arguments, api_env)
      expect(status).to eq(0), out + err
      expect(out).to include("a comment by owner-login")
      expect(@api_log.size).to eq(2), "two pages, then it stops: #{@api_log.inspect}"
      expect(@api_log[0]).to end_with("Bearer test-token")
      expect(out + err).not_to include("test-token"), "the token is never printed"

      status, _out, err = run_check(arguments, api_env.reject { |key, _| key == "GITHUB_TOKEN" })
      expect(status).to eq(2), "without a token it cannot tell"
      expect(err).to include("GITHUB_TOKEN")
    end
  end

  # The workflow runs the check on every change of a pull request, its description's
  # included, as the base branch has it (`pull_request_target`), with nothing but read
  # permissions, the whole history, and a checkout of the base that keeps no token. No step
  # but that checkout uses an action.
  it "runs the base's check on every change of a pull request" do
    parsed = workflow
    on = trigger(parsed)
    expect(on.keys).to eq(["pull_request_target"])
    %w[opened synchronize reopened edited ready_for_review].each do |type|
      expect(on["pull_request_target"]["types"]).to include(type)
    end
    expect(parsed["permissions"]).to eq("contents" => "read", "pull-requests" => "read")
    expect(parsed["jobs"].keys).to eq(["trail"])
    expect(parsed["jobs"]["trail"]).not_to have_key("permissions"), "the job widens the permissions"
    steps = parsed["jobs"]["trail"]["steps"]
    expect(steps.size).to eq(2)
    expect(steps[0]["uses"].to_s).to start_with("actions/checkout@")
    # No ref: pull_request_target checks out the base branch.
    expect(steps[0]["with"].keys).to eq(%w[fetch-depth persist-credentials])
    expect(steps[0]["with"]["fetch-depth"].to_s).to eq("0"), "the diff needs the merge base"
    expect(steps[0]["with"]["persist-credentials"].to_s).to eq("false")
    expect(steps[1]).not_to have_key("uses")
  end

  # The workflow's own step, run as CI runs it: in a checkout of the base branch alone, the
  # pull request's head fetched by the step from a stand-in for GitHub. A file moved out of
  # a risk path (onto an exempt one) is still on it; a pull request that loosens the check or
  # its exempt list is judged by the base's; a base without the check fails rather than
  # passes; a change to the exempt docs alone passes.
  it "judges by the base and sees a move out of a risk path" do
    with_fake_api([]) do
      # A rename out of a risk path onto an exempt one, with no review line.
      repo = repository(true)
      git(repo, "mv", risk_file, "README.md")
      status, out = run_step(repo, "move a risk file onto an exempt path")
      expect(status).to eq(1), out
      expect(out).to include(risk_file)

      # A check that passes everything, an exempt list that frees lib/: the base's judge.
      repo = repository(true)
      File.write(File.join(repo, ".github/review-trail/check.py"), "import sys\nsys.exit(0)\n")
      File.write(File.join(repo, ".github/review-trail/exempt-paths.txt"), "lib/\n.github/\n", mode: "a")
      File.write(File.join(repo, risk_file), "# changed\n")
      status, out = run_step(repo, "loosen the check")
      expect(status).to eq(1), out
      expect(out).to include(".github/review-trail/check.py")

      # No check in the base: the head's own is never taken instead.
      repo = repository(false)
      FileUtils.mkdir_p(File.join(repo, ".github/review-trail"))
      File.write(File.join(repo, ".github/review-trail/check.py"), "import sys\nsys.exit(0)\n")
      FileUtils.cp(exempt, File.join(repo, ".github/review-trail/exempt-paths.txt"))
      status, out = run_step(repo, "introduce a lenient check")
      expect(status).not_to eq(0), "a base without the check let a pull request pass: #{out}"

      # The exempt docs alone.
      repo = repository(true)
      File.write(File.join(repo, exempt_file), "# A, amended\n")
      status, out = run_step(repo, "docs")
      expect(status).to eq(0), out
    end
  end

  # A name outside ASCII, or with a quote, reaches the check as it is (git quotes it in
  # `--name-only` unless told otherwise): on a risk path it is named so, and in an exempt
  # folder (its exempt docs/) it needs no review.
  it "judges names outside ASCII as they are" do
    with_fake_api([]) do
      repo = repository(true)
      File.write(File.join(repo, "#{risk_dir}zażółć.rb"), "# z\n")
      status, out = run_step(repo, "a file of a Polish name")
      expect(status).to eq(1), out
      expect(out).to include("#{risk_dir}zażółć.rb"), "the risk path is not named as it is"

      repo = repository(true)
      File.write(File.join(repo, "docs/źródło \"cytat\".md"), "# Ź\n")
      status, out = run_step(repo, "a doc of a Polish name")
      expect(status).to eq(0), "an exempt doc of a non-ASCII name was judged a risk path: #{out}"
      # The guard: the check saw the one changed path, not an empty list.
      expect(out).to include("(1 changed)")
    end
  end

  # What a pull request names reaches the job's log, where a line that starts with `::`
  # (leading whitespace aside) or holds `##[` is a command to the runner: a path with a line
  # break, a carriage return or a leading `::`, or a commenter's login, never makes one, and
  # cannot forge the check's own verdict. The check runs on the names as the workflow gives
  # them (`-z`).
  it "never turns what a pull request names into a runner command" do
    forged = "::notice title=Review trail::Reviewed: przeglad-bezpieczenstwa @ #{trail_head} — AKCEPTACJA"
    paths = ["#{risk_dir}x\n#{forged}", "::warning::x", "##[error]y", "#{risk_dir}z\r::error::w", "  ::add-mask::v"]
    File.write(File.join(@dir, "event.json"), JSON.generate("pull_request" => {
      "number" => 7, "body" => nil, "author_association" => "MEMBER", "head" => { "sha" => trail_head },
    }))
    File.write(File.join(@dir, "paths.txt"), paths.join("\0") + "\0")
    File.write(File.join(@dir, "comments.json"), JSON.generate([{ "body" => "Review: x @ #{trail_head} — POPRAWKI",
                                                                  "author_association" => "MEMBER",
                                                                  "user" => { "login" => "a\n::error::forged" } }]))
    status, out, err = run_check(["--event", File.join(@dir, "event.json"), "--paths", File.join(@dir, "paths.txt"),
                                  "-z", "--exempt", exempt, "--comments", File.join(@dir, "comments.json")])

    expect(status).to eq(1), "a forged line passed the check: #{out}#{err}"
    expect(command_lines("#{out}\n#{err}")).to eq([]), "the check printed a runner command"
    # The guards: every name and the login were reported, not dropped.
    expect(out).to include("#{paths.size} changed path(s) on the risk list")
    expect(out).to include(forged[2..]), "the forged name is not reported"
    expect(out).to include("a comment by a")
  end

  # The workflow's step stops the runner's commands, with a token nobody knows in advance,
  # before the check prints the pull request's names, and resumes them after it, failed or
  # not: the only commands in its log are its own, and the check's verdict stands.
  it "stops the runner's commands around the check" do
    with_fake_api([]) do
      tokens = []
      ["#{risk_dir}x\n::notice title=Review trail::Reviewed: przeglad-bezpieczenstwa — AKCEPTACJA", "::warning::x"].each do |name|
        repo = repository(true)
        File.write(File.join(repo, name), "x\n")
        status, out = run_step(repo, "a name that holds a command")
        expect(status).to eq(1), out
        commands = command_lines(out)
        expect(commands.size).to eq(3), "commands other than the step's own: #{commands.join(" | ")}"
        expect(commands[0]).to start_with("::add-mask::")
        stop = commands[1].match(/\A::stop-commands::([0-9a-f]{32})\z/)
        expect(stop).not_to be_nil, commands[1]
        expect(commands[2]).to eq("::#{stop[1]}::"), "the commands are not resumed with the token"
        # The check's report lies between the stop and the resumption.
        report = out.index("changed path(s) on the risk list")
        expect(report).not_to be_nil, "the check reported nothing: #{out}"
        expect(report).to be > out.index(commands[1])
        expect(report).to be < out.index(commands[2])
        tokens << stop[1]
      end
      expect(tokens[0]).not_to eq(tokens[1]), "the token is the same on every run"
    end
  end

  # Nothing of the head runs or lands in the work tree: its check, made to leave a mark when
  # run, leaves none; the checkout stays on the base, clean; the token the step fetches with
  # is kept nowhere.
  it "never checks out or runs the head" do
    with_fake_api([]) do
      mark = File.join(@dir, "the-head-ran")
      repo = repository(true)
      File.write(File.join(repo, ".github/review-trail/check.py"),
                 "import pathlib, sys\npathlib.Path(#{JSON.generate(mark)}).write_text('ran')\nsys.exit(0)\n")
      File.write(File.join(repo, "#{risk_dir}run-me.sh"), "#!/bin/sh\ntouch '#{mark}'\n")
      status, out, runner = run_step(repo, "a head that would run")

      expect(status).to eq(1), out
      expect(File.exist?(mark)).to be(false), "a file of the head ran"
      expect(git(runner, "rev-parse", "HEAD")).to eq(git(repo, "rev-parse", "main")), "the work tree left the base"
      expect(git(runner, "status", "--porcelain")).to eq(""), "a file of the head reached the work tree"
      expect(File.exist?(File.join(runner, "#{risk_dir}run-me.sh"))).to be(false)
      # The guard: the head was fetched, so the step did see it.
      expect(git(runner, "cat-file", "-t", git(repo, "rev-parse", "HEAD"))).to eq("commit")
      config = File.read(File.join(runner, ".git/config"))
      expect(config.downcase).not_to include("extraheader")
      expect(config).not_to include("test-token")
    end
  end
end

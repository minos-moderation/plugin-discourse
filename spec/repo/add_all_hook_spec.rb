# frozen_string_literal: true

require "json"
require "open3"

# The PreToolUse hook that refuses staging the whole work tree (`.claude/hooks/no-add-all.sh`
# and `no_add_all.py`), run through the command `.claude/settings.json` registers, as Claude
# Code runs it: what it refuses, what it lets through (a quoted message, a here-document, an
# explicit path), and that unreadable input never stops a session. A port of
# `tests/Repo/AddAllHookTest.php` in the PHP plugins.
#
# Plain Ruby: it runs in the standalone tier and inside Discourse's harness alike, so it
# defines no top-level constant. The hook parses with python3; without it the spec is
# skipped, and CI's standalone tier fails on a skip.
RSpec.describe "The hook that refuses git add -A" do
  let(:root) { File.expand_path("../..", __dir__) }

  let(:command) do
    settings = JSON.parse(File.read(File.join(root, ".claude/settings.json")))
    found = settings.dig("hooks", "PreToolUse").to_a.flat_map { |entry| entry["hooks"].to_a }
                    .map { |hook| hook["command"].to_s }.find { |text| text.include?("no-add-all.sh") }
    expect(found).not_to be_nil, "the hook is not registered in .claude/settings.json"
    found
  end

  before do
    tools = %w[python3 bash].all? { |tool| system("command -v #{tool} > /dev/null 2>&1") }
    skip "python3 and bash are needed: the hook parses with python3" unless tools
  end

  # Runs the hook as Claude Code does: through the shell, in the project, with the input on
  # stdin. Returns the exit code and stderr.
  def run_hook(input)
    _out, err, status = Open3.capture3({ "CLAUDE_PROJECT_DIR" => root, "PATH" => ENV.fetch("PATH", "") },
                                       "bash", "-c", command, stdin_data: input, chdir: root, unsetenv_others: true)
    [status.exitstatus, err]
  end

  def run_bash(bash_command)
    run_hook(JSON.generate("session_id" => "test", "hook_event_name" => "PreToolUse", "tool_name" => "Bash",
                           "tool_input" => { "command" => bash_command, "description" => "test" }))
  end

  [
    "git add -A", "git add --all", "git add .", "git add -Av", "git add --al", "git add --no-ignore-removal",
    "git stage -A", "git add -- .", "git add *", "git add :/", "git -C /tmp/w add .", "git --no-pager add -A",
    "cd /tmp/w && git add -A", "git status\ngit add .", "GIT_DIR=.git git add -A", "sudo -u me git add -A",
    "bash -c 'git add -A'", 'sh -c "cd x && git add ."', "eval git add -A", "(git add -A)", "git add . 2>&1",
    "git add \\\n  -A", "git add -u", "git add --update", "git add -uv", "git stage --up",
    "git commit -a -m x", 'git commit -am "x"', "git commit -qam 'x'", "git commit --all -m x",
    "git commit -C HEAD -a", "git -C /tmp/w commit --al",
  ].each do |bash_command|
    it "refuses #{bash_command.inspect}" do
      status, err = run_bash(bash_command)
      expect(status).to eq(2), err
      expect(err).to include("Stage explicit paths")
    end
  end

  [
    "git add README.md", "git add lib/minos_moderation/signature.rb spec/lib/", "git add -p", "git add *.rb",
    "git log --all", "echo git add -A", "grep -n 'git add .' CLAUDE.md", "git commit -m 'never git add -A'",
    "git commit -q -F - <<'EOF'\nSubject\n\nNever git add -A, never git add .\nEOF",
    "git add docs/x.md # not git add -A", "git add 'unbalanced", "git diff --name-only origin/main...HEAD",
    "git add -u lib/", "git add -u -- lib/x.rb", "git add --update --pathspec-from-file=list.txt",
    'git commit -m "add -a"', "git commit -m -a", "git commit -uall -m x", "git commit -q -F msg.txt",
    "git commit --amend --no-edit", "git commit -- lib/x.rb",
  ].each do |bash_command|
    it "lets #{bash_command.inspect} run" do
      status, err = run_bash(bash_command)
      expect(status).to eq(0), err
      expect(err).to eq("")
    end
  end

  it "never stops a session on input it cannot read" do
    ["", "not json", '{"tool_input": {"command": 7}}', '{"tool_name": "Bash"}'].each do |input|
      expect(run_hook(input)[0]).to eq(0), "input: #{input}"
    end
  end
end

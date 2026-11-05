# frozen_string_literal: true

require "json"
require "open3"

# The rules for Claude Code sessions stay findable and cheap: the root `CLAUDE.md`, read by
# every session, keeps to a size budget and names every scoped file, and every project
# agent pins its model. A Sonnet agent that edits files works from a list of allowed paths,
# so its file must name the paths it may not touch. A registered hook refuses `git add -A`.
#
# A port of `tests/Repo/ClaudeRulesTest.php` in `minos-moderation/client-php`. Plain Ruby
# and RSpec: it runs in the standalone tier and inside Discourse's harness alike, so it
# defines no top-level constant.
RSpec.describe "The rules for Claude Code sessions" do
  # Bytes. Lowering is free; raising needs a sentence in the commit.
  let(:root_limit) { 3100 }

  # Bytes, for every `CLAUDE.md` below the root.
  let(:scoped_limit) { 1600 }

  # Agents allowed to edit files. Every other agent is read-only.
  let(:writers) { %w[programista programista-prosty] }

  # What a Sonnet agent that edits files must name as off limits: the webhook controller,
  # the signature verifier and its vector, the submission job, the NewPostManager handler,
  # the settings that decide publish/hold, key and secret handling, CI and the rules.
  let(:sonnet_risk_markers) do
    %w[
      app/controllers/
      signature.rb
      spec/fixtures/signature.json
      app/jobs/
      submission.rb
      new_post_handler.rb
      config/settings.yml
      decision.rb
      settings.rb
      .github/
      .claude/
      CLAUDE.md
    ]
  end

  let(:models) { %w[opus sonnet haiku fable] }
  let(:efforts) { %w[low medium high xhigh max] }
  let(:root) { File.expand_path("../..", __dir__) }

  def read(path)
    File.binread(File.join(root, path))
  end

  # Every `CLAUDE.md` below the root, as paths relative to it.
  def scoped_files
    skip = %w[.git vendor node_modules tmp]
    found =
      Dir
        .glob("**/CLAUDE.md", base: root)
        .reject { |path| path == "CLAUDE.md" || skip.include?(path.split("/").first) }
        .sort
    expect(found).not_to be_empty, "no scoped CLAUDE.md found: the search is broken"
    found
  end

  # Every project agent by file name: its front matter and its body.
  def agents
    files = Dir.glob(File.join(root, ".claude/agents/*.md")).sort
    expect(files).not_to be_empty, "no agents found in .claude/agents/"
    files.to_h do |file|
      text = File.read(file, encoding: "UTF-8")
      fields = {}
      body = text
      if (match = text.match(/\A---\n(.*?)\n---\n(.*)\z/m))
        body = match[2]
        match[1].each_line do |line|
          key, value = line.split(":", 2)
          fields[key.strip] = value.strip if value
        end
      end
      [File.basename(file, ".md"), { fields: fields, body: body }]
    end
  end

  def writes?(fields)
    tools = fields.fetch("tools", "").split(",").map(&:strip)
    tools.include?("Edit") || tools.include?("Write")
  end

  it "keeps the root file within its budget" do
    expect(read("CLAUDE.md").bytesize).to be <= root_limit,
    "move a rule that one directory needs into that directory's CLAUDE.md"
  end

  it "keeps every scoped file within its budget and names it in the root" do
    root_text = read("CLAUDE.md")
    scoped_files.each do |path|
      expect(read(path).bytesize).to be <= scoped_limit, path
      expect(root_text).to include("`#{path}`"), "the root CLAUDE.md must name #{path}"
    end
  end

  it "has every agent pin a model and an effort" do
    agents.each do |name, agent|
      fields = agent[:fields]
      expect(fields["name"]).to eq(name), "#{name}: the name must match the file"
      expect(models).to include(fields["model"]), "#{name}: no pinned model"
      expect(efforts).to include(fields["effort"]), "#{name}: no pinned effort"
      expect(fields["description"].to_s).not_to be_empty, "#{name}: no description"
    end
  end

  it "lets only an implementing agent write, and never on Fable" do
    agents.each do |name, agent|
      if writers.include?(name)
        expect(agent[:fields]["model"]).not_to eq("fable"), "#{name}: Fable does not implement"
      else
        expect(writes?(agent[:fields])).to be(false),
        "#{name} is read-only and may not list Edit or Write"
      end
    end
  end

  it "has a Sonnet agent that writes name the risk list" do
    checked = 0
    agents.each do |name, agent|
      next if agent[:fields]["model"] != "sonnet" || !writes?(agent[:fields])
      checked += 1
      sonnet_risk_markers.each do |marker|
        expect(agent[:body]).to include(marker), "#{name} must name #{marker} as off limits"
      end
    end
    expect(checked).to be > 0, "no Sonnet agent that writes was found: the check checks nothing"
  end

  # Runs a hook command as Claude Code does: through the shell, in the project, with the
  # Bash call's JSON on stdin. Returns the exit code.
  def run_hook(command, bash_command)
    input = JSON.generate("session_id" => "test", "hook_event_name" => "PreToolUse", "tool_name" => "Bash",
                          "tool_input" => { "command" => bash_command, "description" => "test" })
    _out, _err, status = Open3.capture3({ "CLAUDE_PROJECT_DIR" => root, "PATH" => ENV.fetch("PATH", "") },
                                        "bash", "-c", command, stdin_data: input, chdir: root, unsetenv_others: true)
    status.exitstatus
  end

  # `git add -A` is refused by a hook, not only by the rule's text: `.claude/settings.json`
  # registers a PreToolUse hook on Bash whose command, run as Claude Code runs it (the
  # call's JSON on stdin), refuses it with exit 2 and lets an explicit path through. The
  # hook parses with python3; without it this is skipped, and CI's standalone tier fails on
  # a skip.
  it "registers a hook that refuses git add -A" do
    skip "python3 is needed: the hook parses with it" unless system("command -v python3 > /dev/null 2>&1")
    settings = JSON.parse(read(".claude/settings.json"))
    commands =
      settings.dig("hooks", "PreToolUse").to_a
              .select { |entry| /\A(?:#{entry["matcher"]})\z/.match?("Bash") }
              .flat_map { |entry| entry["hooks"].to_a.select { |hook| hook["type"] == "command" } }
              .map { |hook| hook["command"].to_s }
    expect(commands).not_to be_empty, "no PreToolUse command hook on Bash is registered"
    refusing = commands.select { |command| run_hook(command, "git add -A") == 2 && run_hook(command, "git add README.md").zero? }
    expect(refusing.size).to eq(1), "no registered hook refuses `git add -A` and lets `git add README.md` run"
  end
end

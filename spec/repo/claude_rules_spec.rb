# frozen_string_literal: true

# The rules for Claude Code sessions stay findable and cheap: the root `CLAUDE.md`, read by
# every session, keeps to a size budget and names every scoped file, and every project
# agent pins its model. A Sonnet agent that edits files works from a list of allowed paths,
# so its file must name the paths it may not touch.
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
end

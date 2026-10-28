# frozen_string_literal: true

require_relative "../../lib/minos_moderation/metrics" unless defined?(MinosModeration::Metrics)

# The administrator's numbers: the time from the gateway's acceptance of a post to its
# verdict (P50, P95) and the verdict counts over the last seven days, read from the
# entries the plugin keeps anyway. Entries carry no text: only times and verdicts.
RSpec.describe "MinosModeration::Metrics" do
  subject(:metrics) { MinosModeration::Metrics }

  let(:now) { 2_000_000_000 }
  let(:day) { 24 * 3600 }

  def decided(seconds, qualification = "bezpieczne", at: now - 60, status: "ocenione")
    {
      "status" => "done",
      "submitted_at" => at - seconds,
      "received_at" => at,
      "handled_at" => at,
      "verdict" => { "status" => status, "kwalifikacja" => qualification, "kategorie" => [] },
    }
  end

  it "gives the median and the 95th percentile by nearest rank" do
    summary = metrics.summary([decided(10), decided(40), decided(20)], now: now)
    expect(summary.values_at("p50", "p95", "timed")).to eq([20, 40, 3])

    hundred = (1..100).map { |seconds| decided(seconds) }
    expect(metrics.summary(hundred.shuffle(random: Random.new(7)), now: now).values_at("p50", "p95"))
      .to eq([50, 95])
  end

  it "counts every verdict value, an unknown one as nieocenione" do
    entries = [
      decided(5, "bezpieczne"),
      decided(5, "bezpieczne"),
      decided(5, "ocenzurowane"),
      decided(5, "zablokowane"),
      decided(5, nil, status: "nieocenione"),
      decided(5, "nowa"),
    ]
    summary = metrics.summary(entries, now: now)
    expect(summary.slice(*metrics::VERDICTS)).to eq(
      "bezpieczne" => 2,
      "ocenzurowane" => 1,
      "zablokowane" => 1,
      "nieocenione" => 2,
    )
  end

  it "covers the last seven days only" do
    entries = [decided(30, at: now - (7 * day) + 1), decided(90, at: now - (7 * day))]
    summary = metrics.summary(entries, now: now)
    expect(summary.values_at("p50", "timed", "bezpieczne")).to eq([30, 1, 1])
  end

  it "counts the posts that ended without a verdict, not those a person took over" do
    entries = [
      { "status" => "done", "outcome" => "leave", "reason" => "timeout", "handled_at" => now - 9 },
      { "status" => "auto_published", "outcome" => "approve", "handled_at" => now - 9 },
      { "status" => "done", "outcome" => "resolved_elsewhere", "handled_at" => now - 9 },
      { "status" => "done", "outcome" => "leave", "handled_at" => now - (8 * day) },
      { "status" => "submitted", "submitted_at" => now - 9 },
    ]
    summary = metrics.summary(entries, now: now)
    expect(summary.values_at("no_verdict", "timed", "p50")).to eq([2, 0, nil])
  end

  it "measures a verdict delivered before the plugin noted the 202 as zero, and skips one without a 202" do
    early = decided(5).merge("submitted_at" => now - 50)
    unknown = decided(5).tap { |entry| entry.delete("submitted_at") }
    summary = metrics.summary([early, unknown], now: now)
    expect(summary.values_at("p50", "timed", "bezpieczne")).to eq([0, 1, 2])
  end

  it "has a value for every row it shows, and nothing for an empty week" do
    empty = metrics.summary([], now: now)
    expect(empty.keys).to match_array(metrics::ROWS.map(&:first))
    expect(empty.values_at("p50", "p95")).to eq([nil, nil])
    expect(empty.except("p50", "p95").values).to all(eq(0))
  end

  it "keeps P50 at most P95, both among the measured times, over random weeks" do
    random = Random.new(2026)
    checked = 0
    50.times do
      seconds = Array.new(random.rand(1..60)) { random.rand(0..2000) }
      summary = metrics.summary(seconds.map { |value| decided(value) }, now: now)
      expect(summary["p50"]).to be <= summary["p95"]
      expect(seconds).to include(summary["p50"], summary["p95"])
      expect(summary["p95"]).to be <= seconds.max
      checked += 1
    end
    expect(checked).to eq(50)
  end

  it "reads no text: an entry's text fields never change the numbers" do
    plain = decided(12)
    noisy = plain.merge("text_digest" => "a" * 64, "verdict" => plain["verdict"].merge("ocenzurowany" => "█"))
    expect(metrics.summary([noisy], now: now)).to eq(metrics.summary([plain], now: now))
  end

  it "splits a duration into minutes and seconds" do
    expect(metrics.minutes_and_seconds(59)).to eq([0, 59])
    expect(metrics.minutes_and_seconds(185)).to eq([3, 5])
  end
end

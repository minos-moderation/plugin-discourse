# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "tmpdir"
require "uri"
%w[signature webhook_payload scores text gateway_client].each do |name|
  constant = name.split("_").map(&:capitalize).join
  unless defined?(MinosModeration) && MinosModeration.const_defined?(constant, false)
    require_relative "../../lib/minos_moderation/#{name}"
  end
end

# The plugin's wire code against the mock gateway of `minos-moderation/client-php`, over
# real HTTP: the request body passes the mock's intake, its refusals read as the contract
# says, and its signed deliveries verify and parse in Ruby. No post: the texts carry the
# mock's `[minos:…]` markers only.
#
# Needs a checkout of client-php in MINOS_CLIENT_PHP and `php` with ext-curl (CI provides
# both). Without MINOS_CLIENT_PHP the whole group is skipped: the application is absent,
# unless MINOS_REQUIRE_MOCK_GATEWAY=1 (CI's standalone job) turns the skip into a failure.
RSpec.describe "The plugin against the mock gateway" do
  before(:all) do
    @dir = ENV.fetch("MINOS_CLIENT_PHP", "")
    if @dir.empty?
      # CI's standalone job sets this, so the group can never pass there by skipping.
      raise "MINOS_CLIENT_PHP is required here" if ENV["MINOS_REQUIRE_MOCK_GATEWAY"] == "1"

      skip "MINOS_CLIENT_PHP is not set: no mock gateway to run"
    end

    @secret = "atrapa-minos-sekret-webhooka-tylko-lokalnie"
    @key = "wgb2b_atrapa_minos_0000000000000000"
    @data = Dir.mktmpdir("minos-mock")
    @receiver = TCPServer.new("127.0.0.1", 0)
    probe = TCPServer.new("127.0.0.1", 0)
    @port = probe.addr[1]
    probe.close
    @env = {
      "MINOS_MOCK_WEBHOOK_URL" => "http://127.0.0.1:#{@receiver.addr[1]}/minos/webhook",
      "MINOS_MOCK_DATA_DIR" => @data,
      "MINOS_MOCK_DELAY_S" => "0",
    }
    @api =
      Process.spawn(
        @env,
        "php",
        "-S",
        "127.0.0.1:#{@port}",
        "-t",
        File.join(@dir, "mock-gateway/public"),
        out: File::NULL,
        err: File::NULL,
      )
    deadline = Time.now + 10
    begin
      TCPSocket.new("127.0.0.1", @port).close
    rescue SystemCallError
      raise "the mock gateway did not start" if Time.now > deadline

      sleep(0.1)
      retry
    end
  end

  after(:all) do
    if @api
      Process.kill("TERM", @api)
      Process.wait(@api)
    end
    @receiver&.close
    FileUtils.remove_entry(@data) if @data
  end

  let(:client) { MinosModeration::GatewayClient.new }
  let(:endpoint) { MinosModeration::Scores.endpoint("http://127.0.0.1:#{@port}") }

  def submit(id, raw)
    text = MinosModeration::Text.for_submission(raw)[:text]
    body =
      MinosModeration::Scores.request_body(
        item_id: MinosModeration::Scores.item_id(id, 1),
        text: text,
        profile: "forum_adult",
        meta: {
          "links" => MinosModeration::Text.link_count(raw),
          "author_first_post" => true,
          "link_domains" => ["example.test"],
        },
      )
    response = client.post(endpoint, @key, body)
    [MinosModeration::Scores.classify(response.status, response.body), text]
  end

  # Runs the mock's worker once while this process answers its deliveries, the way the
  # webhook controller does: raw body, signature (401), parse.
  def deliveries
    received = []
    thread =
      Thread.new do
        loop do
          connection = @receiver.accept
          headers = {}
          connection.gets
          while (line = connection.gets) && line != "\r\n"
            name, value = line.split(":", 2)
            headers[name.downcase] = value.strip
          end
          body = connection.read(headers["content-length"].to_i)
          header = headers["x-wergiliusz-podpis"].to_s
          verified = MinosModeration::Signature.verify(@secret, header, body, Time.now.to_i)
          payload = MinosModeration::WebhookPayload.parse(body)
          type = headers["content-type"]
          received << { verified: verified, payload: payload, content_type: type }
          status = verified ? "200 OK" : "401 Unauthorized"
          connection.write("HTTP/1.1 #{status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          connection.close
        end
      rescue IOError, SystemCallError
        nil
      end
    worker = File.join(@dir, "mock-gateway/bin/worker.php")
    ran = system(@env, "php", worker, "--once", out: File::NULL, err: File::NULL)
    expect(ran).to be(true), "the mock's worker failed"
    thread.kill
    received
  end

  def by_id(received, id)
    received.select { |delivery| delivery.dig(:payload, "id") == "discourse:#{id}.1" }
  end

  it "accepts the request body, and delivers verdicts that verify and parse" do
    cases = {
      1 => "Zwykła, spokojna odpowiedź.",
      2 => "Tekst [minos:blokuj] [minos:kategoria=nekanie]",
      3 => "Tekst [minos:cenzuruj] z [[fragmentem]] do zamaskowania",
      4 => "Tekst [minos:nieocenione]",
      5 => "Tekst [minos:kategoria=samookaleczenie]",
      6 => "Tekst [minos:dwa-razy]",
      7 => "**Pogrubiony** tekst z [odnośnikiem](https://example.test) [minos:bez-wersji]",
    }
    sent = {}
    cases.each do |id, raw|
      outcome, text = submit(id, raw)
      expect(outcome.kind).to eq(:accepted), "item #{id}: #{outcome.to_h}"
      sent[id] = text
    end

    # Two passes of the worker: the mock repeats `[minos:dwa-razy]` on the next one.
    received = deliveries + deliveries
    expect(received).to all(include(verified: true))
    types = received.map { |delivery| delivery[:content_type] }
    expect(types).to all(start_with("application/json"))

    expect(by_id(received, 1).first[:payload]["kwalifikacja"]).to eq("bezpieczne")
    blocked = by_id(received, 2).first[:payload]
    expect([blocked["kwalifikacja"], blocked["kategorie"]]).to eq(["zablokowane", ["nekanie"]])
    censored = by_id(received, 3).first[:payload]
    expect(censored["kwalifikacja"]).to eq("ocenzurowane")
    expect(censored["ocenzurowany"]).to include("█")
    expect(censored["ocenzurowany"]).not_to include("fragmentem")
    expect(by_id(received, 4).first[:payload]["status"]).to eq("nieocenione")
    expect(by_id(received, 5).first[:payload]["wsparcie"]).to be(true)
    expect(by_id(received, 6).size).to eq(2)
    expect(by_id(received, 7).first[:payload]["wersja"]).to be_nil

    # The mock masks per character (client-php f85c6ed), so its masks map back exactly.
    expect(censored["ocenzurowany"].length).to eq(sent[3].length)
    masked = MinosModeration::Text.apply_masks(cases[3], sent[3], censored["ocenzurowany"])
    expect(masked).not_to be_nil
    expect(masked[:raw]).to eq(cases[3].sub("fragmentem", "█" * "fragmentem".length))
  end

  it "refuses deliveries signed wrongly or too long ago" do
    submit(20, "Tekst [minos:zly-podpis]")
    submit(21, "Tekst [minos:stary-podpis]")
    received = deliveries
    [20, 21].each do |id|
      mine = by_id(received, id)
      expect(mine).not_to be_empty
      expect(mine).to all(include(verified: false))
    end
  end

  it "reads the mock's refusals as the contract says" do
    refusals = {
      "kolejka_pelna" => :retry,
      "limit_minutowy_klucza" => :retry,
      "kolejka_niedostepna" => :retry,
      "brak_webhooka" => :config_error,
      "profil_niedozwolony" => :config_error,
      "brak_klucza" => :config_error,
    }
    refusals.each do |code, kind|
      request = Net::HTTP::Post.new(endpoint.request_uri)
      request["Content-Type"] = "application/json"
      request["X-Gateway-Key"] = @key
      request["X-Minos-Mock-Error"] = code
      request.body = JSON.generate("elementy" => [{ "id" => "discourse:30.1", "tekst" => "t" }])
      response = Net::HTTP.start(endpoint.host, endpoint.port) { |http| http.request(request) }
      outcome = MinosModeration::Scores.classify(response.code.to_i, response.body)
      expect([outcome.kind, outcome.code]).to eq([kind, code])
    end
  end

  it "is refused without the key, as a configuration error" do
    body = JSON.generate("elementy" => [{ "id" => "discourse:40.1", "tekst" => "t" }])
    response = client.post(endpoint, "wgb2b_zly_klucz", body)
    outcome = MinosModeration::Scores.classify(response.status, response.body)
    expect([outcome.kind, outcome.code]).to eq([:config_error, "brak_klucza"])
  end
end

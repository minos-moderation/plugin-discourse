# frozen_string_literal: true

require "json"
require_relative "../../lib/minos_moderation/scores" unless defined?(MinosModeration::Scores)

# The request for `POST /api/v1/b2b/oceny` and the reading of its answer, against the
# contract (`docs/contract.md` in `minos-moderation/client-php`).
RSpec.describe "MinosModeration::Scores" do
  subject(:scores) { MinosModeration::Scores }

  let(:contract_id) { /\A[A-Za-z0-9._:-]{1,64}\z/ }

  def body_for(text: "tekst posta", meta: { "links" => 1, "author_first_post" => true })
    JSON.parse(
      scores.request_body(item_id: "discourse:7.1", text: text, profile: "forum_teen", meta: meta),
    )
  end

  describe "the item id" do
    it "is the reviewable's id and the attempt behind a prefix, within the contract's rule" do
      [[1, 1], [42, 3], ["42", "7"], [999_999_999_999_999_999, 999_999]].each do |id, attempt|
        item = scores.item_id(id, attempt)
        expect(item).to match(contract_id)
        expect(scores.parse_item_id(item)).to eq([Integer(id), Integer(attempt)])
      end
    end

    it "carries no content, only digits after the prefix" do
      expect(scores.item_id(123, 2)).to eq("discourse:123.2")
    end

    it "gives every attempt of a post its own id" do
      ids = (1..5).map { |attempt| scores.item_id(9, attempt) }
      expect(ids.uniq.size).to eq(5)
    end

    it "refuses what is not a positive integer" do
      [0, -1, "1a", "", nil, 1.5, "0x10"].each do |value|
        expect { scores.item_id(value, 1) }.to raise_error(ArgumentError), value.inspect
        expect { scores.item_id(1, value) }.to raise_error(ArgumentError), value.inspect
      end
      expect { scores.item_id(1, 1_000_000) }.to raise_error(ArgumentError)
    end

    it "reads back only the plugin's own ids with an attempt" do
      [
        "k-1",
        "discourse:1",
        "discourse:",
        "discourse:0.1",
        "discourse:1.0",
        "discourse:01.1",
        "discourse:1.01",
        "discourse:1.x",
        "xdiscourse:1.1",
        nil,
      ].each { |id| expect(scores.parse_item_id(id)).to be_nil, id.inspect }
    end
  end

  describe "the request body" do
    it "has exactly the contract's shape: one item with id, text, profile and two signals" do
      body = body_for
      expect(body.keys).to eq(["elementy"])
      expect(body["elementy"].size).to eq(1)
      item = body["elementy"].first
      expect(item.keys).to contain_exactly("id", "tekst", "profil", "meta")
      expect(item["id"]).to match(contract_id)
      expect(item["tekst"]).to eq("tekst posta")
      expect(item["profil"]).to eq("forum_teen")
      expect(item["meta"]).to eq("links" => 1, "author_first_post" => true)
    end

    it "never carries an author's e-mail, IP address or id" do
      [
        { "email" => "osoba@example.test" },
        { "ip" => "203.0.113.7" },
        { "author_id" => 12 },
        { "user_id" => 12 },
        { "username" => "osoba" },
      ].each do |extra|
        meta = { "links" => 0, "author_first_post" => false }.merge(extra)
        expect { body_for(meta: meta) }.to raise_error(ArgumentError), extra.keys.first
      end
    end

    it "sends only the two signals it has, with the contract's types" do
      [
        { "links" => "1", "author_first_post" => true },
        { "links" => 1, "author_first_post" => "true" },
        { "links" => 1 },
      ].each do |meta|
        expect { body_for(meta: meta) }.to raise_error(ArgumentError), meta.inspect
      end
      expect(body_for(meta: { links: 3, author_first_post: false })["elementy"][0]["meta"]).to eq(
        "links" => 3,
        "author_first_post" => false,
      )
    end

    it "sends link_domains when given, as up to ten distinct registrable domains" do
      domains = %w[example.pl a.co.uk]
      meta = { "links" => 2, "author_first_post" => false, "link_domains" => domains }
      expect(body_for(meta: meta)["elementy"][0]["meta"]["link_domains"]).to eq(
        %w[example.pl a.co.uk],
      )
      [
        (1..11).map { |i| "d#{i}.pl" },
        %w[example.pl example.pl],
        ["1.2.3.4"],
        ["Example.pl"],
        ["localhost"],
        "example.pl",
        [7],
      ].each do |domains|
        bad = { "links" => 0, "author_first_post" => false, "link_domains" => domains }
        expect { body_for(meta: bad) }.to raise_error(ArgumentError), domains.inspect
      end
    end

    it "takes 3000 characters, counted as characters, and refuses one more" do
      expect(body_for(text: "ż" * 3000)["elementy"][0]["tekst"].length).to eq(3000)
      expect { body_for(text: "ż" * 3001) }.to raise_error(ArgumentError)
    end

    it "refuses an empty text, which would refuse the whole request" do
      ["", "  \n"].each { |text| expect { body_for(text: text) }.to raise_error(ArgumentError) }
    end

    it "refuses an id outside the contract's rule" do
      ["", "k 1", "a" * 65, "id/1"].each do |id|
        expect do
          scores.request_body(item_id: id, text: "t", profile: "forum_adult", meta: {
            "links" => 0,
            "author_first_post" => false,
          })
        end.to raise_error(ArgumentError), id
      end
    end

    it "never names a webhook: the gateway takes it from the key's record" do
      expect(JSON.generate(body_for)).not_to match(/webhook|url/i)
    end
  end

  describe "the endpoint" do
    it "appends the route to an https base URL" do
      expect(scores.endpoint("https://gateway.wergiliusz.app").to_s).to eq(
        "https://gateway.wergiliusz.app/api/v1/b2b/oceny",
      )
      expect(scores.endpoint(" https://gw.example.test/base/ ").to_s).to eq(
        "https://gw.example.test/base/api/v1/b2b/oceny",
      )
    end

    it "allows plain http only to this machine, for the mock gateway" do
      expect(scores.endpoint("http://localhost:8100").to_s).to eq(
        "http://localhost:8100/api/v1/b2b/oceny",
      )
      expect(scores.endpoint("http://127.0.0.1:8100")).not_to be_nil
      expect(scores.endpoint("http://gateway.wergiliusz.app")).to be_nil
    end

    it "refuses what the key must not travel to" do
      [
        "",
        nil,
        "gateway.wergiliusz.app",
        "ftp://gateway.wergiliusz.app",
        "https://user:pass@gateway.wergiliusz.app",
        "https://gateway.wergiliusz.app/?x=1",
        "https://gateway.wergiliusz.app/#x",
        "https:///path",
        "https://bad host",
      ].each { |url| expect(scores.endpoint(url)).to be_nil, url.inspect }
    end
  end

  describe "reading the answer" do
    def error(code, extra = {})
      JSON.generate("blad" => { "kod" => code, "komunikat" => "opis" }.merge(extra))
    end

    it "reads 202 as accepted" do
      outcome = scores.classify(202, '{"przyjete":["discourse:7"]}')
      expect(outcome.kind).to eq(:accepted)
    end

    it "retries 429 and 503 after ponow_za_s when the gateway sends it" do
      %w[kolejka_pelna limit_minutowy_klucza limit_dobowy_klucza limit_w_locie_klucza
         limit_globalny_b2b].each do |code|
        outcome = scores.classify(429, error(code, "ponow_za_s" => 37))
        expect([outcome.kind, outcome.code, outcome.retry_in]).to eq([:retry, code, 37])
      end
      outcome = scores.classify(503, error("kolejka_niedostepna"))
      expect([outcome.kind, outcome.retry_in]).to eq([:retry, nil])
    end

    it "retries a timeout and a server error, whose cause is not the request" do
      [408, 500, 502, 504].each do |status|
        expect(scores.classify(status, "<html>").kind).to eq(:retry), status.to_s
      end
    end

    it "reads every other refusal as a configuration error, with the gateway's code" do
      {
        401 => "brak_klucza",
        403 => "brak_webhooka",
        400 => "bledne_wejscie",
        413 => "limit_dlugosci",
        404 => "nie_znaleziono",
      }.each do |status, code|
        outcome = scores.classify(status, error(code, "element" => 0))
        expect([outcome.kind, outcome.http, outcome.code]).to eq([:config_error, status, code])
      end
    end

    it "does not take a redirect or an unexpected success for an acceptance" do
      [200, 201, 204, 301, 302].each do |status|
        expect(scores.classify(status, "").kind).to eq(:config_error), status.to_s
      end
    end

    it "repeats only a code of the contract's shape, never other text from the answer" do
      ["<b>x</b>", "a" * 65, 7, nil].each do |code|
        expect(scores.classify(403, error(code)).code).to be_nil, code.inspect
      end
      expect(scores.classify(403, "nie json").code).to be_nil
    end

    it "ignores a ponow_za_s that is not a positive integer" do
      [0, -5, "30", 1.5, nil].each do |value|
        outcome = scores.classify(429, error("kolejka_pelna", "ponow_za_s" => value))
        expect(outcome.retry_in).to be_nil
      end
    end

    it "keeps a daily limit's ponow_za_s as the gateway gave it, beyond the capped pause" do
      outcome = scores.classify(429, error("limit_dobowy_klucza", "ponow_za_s" => 36_000))
      expect(outcome.retry_in).to eq(36_000)
      expect(scores.backoff(1, outcome.retry_in)).to eq(900)
    end

    it "names the state a refusal for a while puts the gateway in, and no other" do
      states =
        %w[limit_dobowy_klucza limit_globalny_b2b kolejka_pelna limit_minutowy_klucza
           limit_w_locie_klucza].to_h do |code|
          [code, scores.limit_state(scores.classify(429, error(code, "ponow_za_s" => 30)))]
        end
      expect(states).to eq(
        "limit_dobowy_klucza" => "daily_limit",
        "limit_globalny_b2b" => "overloaded",
        "kolejka_pelna" => "overloaded",
        "limit_minutowy_klucza" => nil,
        "limit_w_locie_klucza" => nil,
      )
      # Only a 429 carries a limit: the same code on another status is not one.
      expect(scores.limit_state(scores.classify(503, error("kolejka_pelna")))).to be_nil
      expect(scores.limit_state(scores.classify(202, "{}"))).to be_nil
    end

    it "reads a refused private address as a configuration error and other failures as retries" do
      expect(scores.classify_transport("FinalDestination::SSRFDetector::DisallowedIpError").kind)
        .to eq(:config_error)
      %w[Net::OpenTimeout Errno::ECONNREFUSED SocketError OpenSSL::SSL::SSLError].each do |kind|
        expect(scores.classify_transport(kind).kind).to eq(:retry), kind
      end
    end
  end

  describe "the backoff" do
    it "waits ponow_za_s when the gateway gave it, within bounds" do
      expect(scores.backoff(1, 37)).to eq(37)
      expect(scores.backoff(1, 100_000)).to eq(scores::MAX_BACKOFF_S)
    end

    it "doubles from 60 s per attempt otherwise, up to 15 minutes" do
      expect((1..6).map { |attempt| scores.backoff(attempt) }).to eq([60, 120, 240, 480, 900, 900])
      expect(scores.backoff(1_000)).to eq(900)
    end
  end
end

# frozen_string_literal: true

require "json"
unless defined?(MinosModeration::WebhookPayload)
  require_relative "../../lib/minos_moderation/webhook_payload"
end

# Reading a delivery: what is a verdict, and what must never pass for one. The cases mirror
# `tests/Client/WebhookPayloadTest.php` in `minos-moderation/client-php`.
RSpec.describe "MinosModeration::WebhookPayload" do
  subject(:payload) { MinosModeration::WebhookPayload }

  def assessed(extra)
    JSON.generate({ "id" => "k", "status" => "ocenione" }.merge(extra))
  end

  it "reads the vector's body as its verdict" do
    vector = JSON.parse(File.read(File.expand_path("../fixtures/signature.json", __dir__)))
    expect(payload.parse(vector.fetch("body"))).to eq(
      "id" => "k-1",
      "status" => "ocenione",
      "kwalifikacja" => "ocenzurowane",
      "kategorie" => ["wulgaryzmy"],
      "ocenzurowany" => "no to jest ███████ pomysł",
      "wsparcie" => false,
      "wersja" => "3f0c9a41d2b7e8c5",
    )
  end

  it "gives nieocenione no verdict" do
    read = payload.parse('{"id":"k-2","status":"nieocenione"}')
    expect(read["status"]).to eq("nieocenione")
    expect(read["kwalifikacja"]).to be_nil
    expect(read["kategorie"]).to eq([])
    expect(read["wsparcie"]).to be(false)
  end

  it "reads an unknown status or qualification as no verdict, never as bezpieczne" do
    [
      '{"id":"k","status":"ocenione","kwalifikacja":"przepuszczone","kategorie":[]}',
      '{"id":"k","status":"ocenione","kategorie":[]}',
      '{"id":"k","status":"nowy","kwalifikacja":"zablokowane"}',
      '{"id":"k","kwalifikacja":"bezpieczne"}',
      '{"id":"k","status":"ocenione","kwalifikacja":["bezpieczne"]}',
      '{"id":"k","status":"OCENIONE","kwalifikacja":"bezpieczne"}',
    ].each do |body|
      read = payload.parse(body)
      expect(read["status"]).to eq("nieocenione"), body
      expect(read["kwalifikacja"]).to be_nil, body
      expect(read["ocenzurowany"]).to be_nil, body
    end
  end

  it "reads the masked text only with ocenzurowane" do
    blocked = payload.parse(assessed("kwalifikacja" => "zablokowane", "ocenzurowany" => "x"))
    expect(blocked["ocenzurowany"]).to be_nil
    censored = payload.parse(assessed("kwalifikacja" => "ocenzurowane", "ocenzurowany" => "█"))
    expect(censored["ocenzurowany"]).to eq("█")
    not_text = payload.parse(assessed("kwalifikacja" => "ocenzurowane", "ocenzurowany" => 7))
    expect(not_text["ocenzurowany"]).to be_nil
  end

  it "keeps an unknown category and drops repeats and non-labels" do
    read =
      payload.parse(
        assessed(
          "kwalifikacja" => "zablokowane",
          "kategorie" => ["grozba", "nowa_kategoria", "grozba", 7, "", nil],
        ),
      )
    expect(read["kategorie"]).to eq(%w[grozba nowa_kategoria])
  end

  it "reads the labels of a category object, as the PHP reader does" do
    read = payload.parse(assessed("kwalifikacja" => "zablokowane", "kategorie" => { "a" => "spam" }))
    expect(read["kategorie"]).to eq(["spam"])
  end

  it "sets wsparcie only for the JSON true" do
    { "true" => true, '"true"' => false, "1" => false, "null" => false }.each do |json, expected|
      body =
        '{"id":"k","status":"ocenione","kwalifikacja":"bezpieczne",' \
          "\"kategorie\":[\"samookaleczenie\"],\"wsparcie\":#{json}}"
      expect(payload.parse(body)["wsparcie"]).to be(expected), json
    end
  end

  it "reads a malformed version as none" do
    ['"3F0C9A41D2B7E8C5"', '"3f0c"', "123", "null", '"3f0c9a41d2b7e8c5\n"'].each do |json|
      body =
        '{"id":"k","status":"ocenione","kwalifikacja":"bezpieczne",' \
          "\"kategorie\":[],\"wersja\":#{json}}"
      expect(payload.parse(body)["wersja"]).to be_nil, json
    end
  end

  it "returns nil for a body without a usable id" do
    [
      "",
      "nie json",
      "[]",
      '"k"',
      "null",
      '{"status":"ocenione"}',
      '{"id":""}',
      '{"id":"k 1"}',
      "{\"id\":\"k-1\\n\"}",
      JSON.generate("id" => "a" * 65),
      '{"id":7}',
      "{\"id\":\"k\xFF\"}".b,
      nil,
    ].each { |body| expect(payload.parse(body)).to be_nil, body.inspect }
  end

  it "accepts every character the contract allows in an id, up to 64 of them" do
    id = "discourse:12.a_b-C"
    expect(payload.parse(JSON.generate("id" => id, "status" => "nieocenione"))["id"]).to eq(id)
    long = "a" * 64
    expect(payload.parse(JSON.generate("id" => long, "status" => "nieocenione"))["id"]).to eq(long)
  end
end

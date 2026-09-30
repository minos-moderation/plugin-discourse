# frozen_string_literal: true

require "json"
require_relative "../../lib/minos_moderation/signature" unless defined?(MinosModeration::Signature)

# The webhook signature, proven on the gateway's own vector (`spec/fixtures/signature.json`,
# a byte-for-byte copy of `vectors/signature.json` in `minos-moderation/client-php`).
RSpec.describe "MinosModeration::Signature" do
  subject(:signature) { MinosModeration::Signature }

  let(:vector_path) { File.expand_path("../fixtures/signature.json", __dir__) }
  let(:vector) { JSON.parse(File.read(vector_path, encoding: "UTF-8")) }
  let(:secret) { vector.fetch("secret") }
  let(:header) { vector.fetch("header") }
  let(:body) { vector.fetch("body") }
  let(:timestamp) { vector.fetch("timestamp") }
  let(:mac) { header.split("v1=", 2).last }

  it "accepts the gateway's vector" do
    expect(signature.verify(secret, header, body, timestamp)).to be(true)
  end

  it "accepts the vector's body as raw bytes, the way Rack hands it over" do
    expect(signature.verify(secret, header, body.b, timestamp)).to be(true)
  end

  it "reproduces the vector's header when signing" do
    expect(signature.sign(secret, body, timestamp)).to eq(header)
  end

  it "refuses the body with one more space" do
    expect(signature.verify(secret, header, "#{body} ", timestamp)).to be(false)
  end

  it "refuses a body with one changed value" do
    tampered = body.sub('"wsparcie":false', '"wsparcie":true')
    expect(tampered).not_to eq(body)
    expect(signature.verify(secret, header, tampered, timestamp)).to be(false)
  end

  it "refuses the same JSON re-encoded, because it covers bytes and not meaning" do
    re_encoded = JSON.generate(JSON.parse(body), ascii_only: true)
    expect(re_encoded).not_to eq(body)
    expect(signature.verify(secret, header, re_encoded, timestamp)).to be(false)
  end

  it "refuses another secret, and an empty one" do
    expect(signature.verify("#{secret}x", header, body, timestamp)).to be(false)
    expect(signature.verify("", header, body, timestamp)).to be(false)
  end

  it "accepts a timestamp up to five minutes off and refuses one second more" do
    [-300, 300].each do |offset|
      expect(signature.verify(secret, header, body, timestamp + offset)).to be(true), offset.to_s
    end
    [-301, 301].each do |offset|
      expect(signature.verify(secret, header, body, timestamp + offset)).to be(false), offset.to_s
    end
  end

  it "accepts surrounding whitespace, as the reference verifier trims the header" do
    expect(signature.verify(secret, "  #{header}\r\n", body, timestamp)).to be(true)
  end

  it "refuses a malformed header without raising" do
    malformed = [
      "",
      "v1=#{mac},t=#{timestamp}",
      "t=#{timestamp},v1=#{mac.upcase}",
      "t=#{timestamp},v1=#{mac[1..]}",
      "t=#{timestamp},v1=#{mac},v0=00",
      "t=-#{timestamp},v1=#{mac}",
      "t=#{timestamp}, v1=#{mac}",
      "t=#{timestamp},v1=#{mac}\nx",
      "t=١,v1=#{mac}",
      "t=#{timestamp},v1=#{mac}\xFF".dup.force_encoding(Encoding::UTF_8),
    ]
    malformed.each do |bad|
      expect(signature.verify(secret, bad, body, timestamp)).to be(false), bad.inspect
    end
  end

  it "refuses what is not a string" do
    expect(signature.verify(secret, nil, body, timestamp)).to be(false)
    expect(signature.verify(secret, header, nil, timestamp)).to be(false)
    expect(signature.verify(nil, header, body, timestamp)).to be(false)
  end

  it "reads the clock from a Time as well as from an Integer" do
    expect(signature.verify(secret, header, body, Time.at(timestamp + 60))).to be(true)
    expect(signature.verify(secret, header, body, Time.at(timestamp + 301))).to be(false)
  end
end

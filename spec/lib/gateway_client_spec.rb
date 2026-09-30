# frozen_string_literal: true

require "json"
require "socket"
require "uri"
unless defined?(MinosModeration::GatewayClient)
  require_relative "../../lib/minos_moderation/gateway_client"
end

# One request to the gateway over real HTTP, against a one-shot server on this machine.
RSpec.describe "MinosModeration::GatewayClient" do
  let(:key) { "wgb2b_klucz_testowy_0000000000000000" }
  let(:body) { JSON.generate("elementy" => [{ "id" => "discourse:1", "tekst" => "zażółć" }]) }

  # Starts a server that answers one request, and records what it received.
  def serve_once(status:, answer: "{}", delay: 0)
    server = TCPServer.new("127.0.0.1", 0)
    received = {}
    thread =
      Thread.new do
        client = server.accept
        received[:line] = client.gets
        headers = {}
        while (line = client.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.downcase] = value.strip
        end
        received[:headers] = headers
        received[:body] = client.read(headers["content-length"].to_i)
        sleep(delay) if delay.positive?
        client.write(
          "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
            "Content-Length: #{answer.bytesize}\r\nConnection: close\r\n\r\n#{answer}",
        )
        client.close
      rescue IOError, SystemCallError
        nil
      ensure
        server.close
      end
    [URI("http://127.0.0.1:#{server.addr[1]}/api/v1/b2b/oceny"), received, thread]
  end

  it "POSTs the exact body with the key and JSON headers, and returns the answer" do
    uri, received, thread = serve_once(status: 202, answer: '{"przyjete":["discourse:1"]}')
    response = MinosModeration::GatewayClient.new.post(uri, key, body)
    thread.join(5)
    expect(response.status).to eq(202)
    expect(response.body).to eq('{"przyjete":["discourse:1"]}')
    expect(received[:line]).to eq("POST /api/v1/b2b/oceny HTTP/1.1\r\n")
    expect(received[:headers]["x-gateway-key"]).to eq(key)
    expect(received[:headers]["content-type"]).to eq("application/json")
    expect(received[:body].b).to eq(body.b)
  end

  it "returns a refusal as an answer, not as an error" do
    uri, _received, thread = serve_once(status: 429, answer: '{"blad":{"kod":"kolejka_pelna"}}')
    response = MinosModeration::GatewayClient.new.post(uri, key, body)
    thread.join(5)
    expect(response.status).to eq(429)
  end

  it "keeps only the beginning of a long answer" do
    uri, _received, thread = serve_once(status: 400, answer: "x" * 100_000)
    response = MinosModeration::GatewayClient.new.post(uri, key, body)
    thread.join(5)
    expect(response.body.bytesize).to eq(MinosModeration::GatewayClient::MAX_BODY_BYTES)
  end

  it "reports no answer with the error's class alone, never the key and never a cause" do
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    uri = URI("http://127.0.0.1:#{port}/api/v1/b2b/oceny")
    expect { MinosModeration::GatewayClient.new.post(uri, key, body) }.to raise_error(
      MinosModeration::GatewayClient::TransportError,
    ) { |error|
      expect(error.kind).to eq("Errno::ECONNREFUSED")
      expect(error.message).not_to include(key)
      expect(error.cause).to be_nil
    }
  end

  it "gives up after its timeout" do
    uri, _received, thread = serve_once(status: 202, delay: 3)
    client = MinosModeration::GatewayClient.new(timeout: 1)
    expect { client.post(uri, key, body) }.to raise_error(
      MinosModeration::GatewayClient::TransportError,
    ) { |error| expect(error.kind).to eq("Net::ReadTimeout") }
    thread.join(5)
  end

  it "uses ten seconds per phase by default, as the plugin promises" do
    expect(MinosModeration::GatewayClient::TIMEOUT_S).to eq(10)
  end
end

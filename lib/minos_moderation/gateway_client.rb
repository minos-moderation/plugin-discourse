# frozen_string_literal: true

require "net/http"
require "uri"

module MinosModeration
  # Sends one request to the gateway and returns its answer, nothing more.
  #
  # In Discourse the HTTP class is `FinalDestination::HTTP`, Net::HTTP with Discourse's
  # SSRF protection (every resolved address checked, the connection pinned to it); plain
  # Net::HTTP is the default only so that the standalone tier can run this class.
  #
  # The key travels in `X-Gateway-Key` and nowhere else: a failure raises {TransportError}
  # carrying only the class name of what went wrong, never a message that could quote a
  # header, a URL or a body.
  class GatewayClient
    # Seconds for each phase of a request: connecting, writing, reading.
    TIMEOUT_S = 10

    # The most of an answer's body that is kept: enough for a `blad` object.
    MAX_BODY_BYTES = 65_536

    # An answer: the HTTP status and the (capped) body.
    Response = Struct.new(:status, :body)

    # No answer at all. `kind` is the class name of the underlying error.
    class TransportError < StandardError
      attr_reader :kind

      # @param kind [String] the underlying error's class name.
      def initialize(kind)
        @kind = kind
        super("the gateway could not be reached (#{kind})")
      end
    end

    # @param http_class [Class] Net::HTTP or a subclass of it.
    # @param timeout [Integer] seconds for each phase of the request.
    def initialize(http_class: Net::HTTP, timeout: TIMEOUT_S)
      @http_class = http_class
      @timeout = timeout
    end

    # POSTs a JSON body with the forum's key.
    #
    # @param uri [URI::HTTP] the route's URL (`Scores.endpoint`).
    # @param key [String] the forum's B2B key.
    # @param body [String] the JSON body (`Scores.request_body`).
    # @return [Response] the gateway's answer, whatever its status.
    # @raise [TransportError] when no answer arrived (no connection, a timeout, a refused
    #   address).
    def post(uri, key, body)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["X-Gateway-Key"] = key
      request.body = body

      http = @http_class.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.write_timeout = @timeout
      http.read_timeout = @timeout
      answer = http.start { |connection| connection.request(request) }
      Response.new(answer.code.to_i, answer.body.to_s.byteslice(0, MAX_BODY_BYTES))
    rescue StandardError => e
      # `cause: nil`: the original error stays out of every report of this one.
      raise TransportError.new(e.class.name), cause: nil
    end
  end
end

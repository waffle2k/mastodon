# frozen_string_literal: true

# yttrx patch — pre-emptive signup blocking.
#
# Mastodon decides whether to reject a signup's IP or email domain by looking
# it up in its OWN tables (IpBlock, EmailDomainBlock). Those tables are only
# ever populated after the fact: yttrx's welcomebot watches the account.created
# webhook, classifies the signup's IP and email domain against ipapi.is /
# check-mail.org, and registers a block — by which point the account exists and
# has to be suspended.
#
# This asks welcomebot the same question *before* those lookups run. Welcomebot
# classifies, records, and registers the IpBlock / EmailDomainBlock before it
# answers, so the lookup Mastodon performs on the very next line finds a block
# that did not exist when the request started. A range nobody has ever signed
# up from can be rejected on first contact instead of after the first account
# out of it.
#
# Design constraints, in order of importance:
#
#   1. It must never break a signup. Every failure — unconfigured, timeout,
#      connection refused, 5xx, unparseable body — is swallowed and logged, and
#      Mastodon carries on with exactly the behaviour it has without this
#      patch. A welcomebot outage costs pre-blocking, nothing else.
#   2. It must not make signups slow. The budget is deliberately small
#      (WELCOMEBOT_REPUTATION_TIMEOUT, default 2s). Measured from this host
#      against the live service: ~700ms for a cached answer and ~1.8s on the
#      first sighting of a bad domain, where it also has to register the block.
#      Most of that is TLS setup across the WAN, not welcomebot's own work
#      (locally it answers a cached query in ~70ms).
#
#      That is too much to spend rendering the signup FORM, which is a page
#      real users load, so that call site passes async: true and does not wait
#      for it. The warm-up still installs the block; the submission that
#      follows makes the same query blocking, by which point it is almost
#      always a cache hit. Detached threads are capped
#      (WELCOMEBOT_REPUTATION_MAX_ASYNC) so a crawl of the signup page cannot
#      spawn an unbounded number of them.
#   3. The response is advisory. We do not branch on it — we do not even have
#      to read it. Mastodon's own lookup stays the single source of truth for
#      whether a signup is blocked; this call only ensures that lookup has the
#      freshest data available before it runs.
#
# Configuration (see .env.production.sample):
#
#   WELCOMEBOT_REPUTATION_URL      endpoint; unset disables the patch entirely
#   WELCOMEBOT_REPUTATION_KEY      shared secret, sent as X-Reputation-Key
#   WELCOMEBOT_REPUTATION_TIMEOUT  total seconds to wait (default 2)
#   WELCOMEBOT_REPUTATION_MAX_ASYNC  concurrent warm-up threads (default 8)
module WelcomebotReputation
  DEFAULT_TIMEOUT = 2.0
  DEFAULT_MAX_ASYNC = 8

  class << self
    def enabled?
      endpoint.present? && api_key.present?
    end

    # Ask welcomebot about an IP and/or email address. Returns the parsed
    # response for callers that want it, nil if the call was skipped, failed,
    # or was made asynchronously. No caller branches on the return value.
    #
    # async: true fires the query without waiting for it — for call sites that
    # want the block installed but must not pay for the round trip, i.e.
    # rendering the signup form. Always returns nil.
    def check(ip: nil, email: nil, source: nil, async: false)
      return unless enabled?

      payload = { ip: ip.to_s, email: email.to_s, source: source.to_s }
      return if payload[:ip].blank? && payload[:email].blank?

      async ? perform_async(payload) : perform(payload)
    rescue StandardError => e
      # Belt and braces. Whatever else happens, a signup must not 500 because
      # a reputation service misbehaved.
      Rails.logger.warn { "WelcomebotReputation: unexpected #{e.class}: #{e.message}" }
      nil
    end

    private

    # Fire the query in a detached thread and return immediately.
    #
    # Bounded on purpose: this runs when the signup form is merely rendered,
    # so it is reachable by anyone crawling the page. Past the cap we simply
    # skip the warm-up — the submission path still makes the same query
    # blocking, so nothing is missed, it just isn't pre-warmed.
    #
    # Safe to run outside the request cycle: no ActiveRecord is touched (so no
    # connection is checked out) and production eager-loads, so there is no
    # autoload happening off the main thread either.
    def perform_async(payload)
      return if inflight.value >= max_async

      inflight.increment
      Thread.new do
        perform(payload)
      rescue StandardError => e
        Rails.logger.warn { "WelcomebotReputation: async lookup failed (#{e.class}): #{e.message}" }
      ensure
        inflight.decrement
      end

      nil
    end

    def inflight
      @inflight ||= Concurrent::AtomicFixnum.new(0)
    end

    def max_async
      count = ENV['WELCOMEBOT_REPUTATION_MAX_ASYNC'].presence&.to_i
      count.nil? || count.negative? ? DEFAULT_MAX_ASYNC : count
    end

    def perform(payload)
      response = HTTP
                 .timeout(timeout)
                 .headers('X-Reputation-Key' => api_key, 'Accept' => 'application/json')
                 .post(endpoint, json: payload)

      unless response.status.success?
        Rails.logger.warn { "WelcomebotReputation: #{endpoint} returned #{response.status}" }
        return nil
      end

      body = JSON.parse(response.body.to_s)
      log_block(payload, body)
      body
    rescue HTTP::Error, OpenSSL::SSL::SSLError, SystemCallError, JSON::ParserError, EncodingError => e
      # The expected failure modes: welcomebot slow, down, or answering with
      # something unparseable. Pre-blocking is best-effort by design.
      Rails.logger.warn { "WelcomebotReputation: lookup failed (#{e.class}): #{e.message}" }
      nil
    ensure
      response&.flush
    end

    # Worth a log line: this is the moment a signup is stopped by a block that
    # did not exist a moment ago, which is otherwise invisible from here (the
    # rejection itself looks like any other IpBlock hit).
    def log_block(payload, body)
      return unless body.is_a?(Hash) && body['blocked']

      Rails.logger.info do
        "WelcomebotReputation: pre-blocked signup attempt (source=#{payload[:source].presence || '-'})"
      end
    end

    def endpoint
      ENV['WELCOMEBOT_REPUTATION_URL'].presence
    end

    def api_key
      ENV['WELCOMEBOT_REPUTATION_KEY'].presence
    end

    def timeout
      seconds = ENV['WELCOMEBOT_REPUTATION_TIMEOUT'].presence&.to_f
      seconds.nil? || seconds <= 0 ? DEFAULT_TIMEOUT : seconds
    end
  end
end

# frozen_string_literal: true

require 'socket'
require 'resolv'

# Caches DNS lookups so rubichiver does not query the resolver for every
# HTTP connection. The archiver opens a fresh Net::HTTP object for each API
# search page, each tag-type lookup, and every media download, all against the
# same host. Net::HTTP resolves the hostname anew on every connection, which
# produces a storm of identical DNS queries. DnsCache resolves each host once
# per TTL window and serves the cached IP thereafter.
module DnsCache
  DEFAULT_TTL = 300

  @cache = {}
  @mutex = Mutex.new
  @ttl = DEFAULT_TTL

  class << self
    attr_accessor :ttl

    def resolve(host)
      # IP literals need no resolver; pass them straight through.
      return host if ip_literal?(host)

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = @mutex.synchronize { @cache[host] }
      return cached[:ip] if cached && (now - cached[:time]) < @ttl

      ip = lookup(host)
      if ip
        @mutex.synchronize { @cache[host] = { ip: ip, time: now } }
        ip
      elsif cached
        # Stale cache beats a hard failure; keep serving the last known IP.
        cached[:ip]
      else
        host
      end
    end

    def lookup(host)
      Addrinfo.getaddrinfo(host, nil, :INET, :STREAM).first&.ip_address
    rescue SocketError, Resolv::ResolvError, IOError, SystemCallError
      nil
    end

    def clear
      @mutex.synchronize { @cache.clear }
    end

    def ip_literal?(host)
      host.match?(/\A(\d{1,3}\.){3}\d{1,3}\z/) || host.include?(':')
    end
  end
end

# Net::HTTP resolves the hostname through TCPSocket.open whenever it opens a
# connection. Patch it once so the resolved IP is taken from the cache. SNI and
# TLS certificate validation still use the original hostname (Net::HTTP keeps
# that separately), so HTTPS is unaffected.
module DnsCachePatch
  def open(host, *args, **kwargs, &block)
    super(DnsCache.resolve(host), *args, **kwargs, &block)
  end
end

unless TCPSocket.singleton_class.ancestors.include?(DnsCachePatch)
  TCPSocket.singleton_class.prepend(DnsCachePatch)

  # Skip reverse PTR lookups on accepted/peer sockets to avoid yet more DNS traffic.
  Socket.do_not_reverse_lookup = true
end

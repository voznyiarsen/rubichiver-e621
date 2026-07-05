# frozen_string_literal: true

# Thread-safe rate limiter using mutex + sleep
class RateLimiter
  attr_reader :request_count

  def initialize(requests_per_second: 2)
    @mutex = Mutex.new
    @min_interval = 1.0 / requests_per_second
    @last_request_time = Time.now - @min_interval
    @request_count = 0
  end

  def throttle!
    @mutex.synchronize do
      elapsed = Time.now - @last_request_time
      sleep(@min_interval - elapsed) if elapsed < @min_interval
      @last_request_time = Time.now
      @request_count += 1
    end
  end
end

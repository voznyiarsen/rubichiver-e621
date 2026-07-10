# frozen_string_literal: true

class RateLimiter
  attr_reader :request_count

  def initialize(requests_per_second: 2)
    @mutex = Mutex.new
    @min_interval = 1.0 / requests_per_second
    @next_allowed = Time.now - @min_interval
    @request_count = 0
  end

  def throttle!
    target = @mutex.synchronize do
      now = Time.now
      target = [@next_allowed, now].max
      @next_allowed = target + @min_interval
      target
    end

    sleep_time = target - Time.now
    sleep(sleep_time) if sleep_time > 0

    @mutex.synchronize { @request_count += 1 }
  end
end

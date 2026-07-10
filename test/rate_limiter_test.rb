# frozen_string_literal: true

require_relative 'test_helper'

class RateLimiterTest < Minitest::Test
  def test_counts_requests
    rl = RateLimiter.new(requests_per_second: 1000)
    assert_equal 0, rl.request_count
    3.times { rl.throttle! }
    assert_equal 3, rl.request_count
  end

  def test_enforces_minimum_interval
    rl = RateLimiter.new(requests_per_second: 20)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    3.times { rl.throttle! }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert_operator elapsed, :>=, 0.08
  end

  def test_allows_immediate_first_call
    rl = RateLimiter.new(requests_per_second: 1)
    start = Time.now
    rl.throttle!
    assert (Time.now - start) < 0.1
    assert_equal 1, rl.request_count
  end

  def test_thread_safety
    rl = RateLimiter.new(requests_per_second: 1000)
    threads = 10.times.map do
      Thread.new { 100.times { rl.throttle! } }
    end
    threads.each(&:join)
    assert_equal 1000, rl.request_count
  end
end

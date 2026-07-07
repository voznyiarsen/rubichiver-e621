test 'rate limiter enforces minimum interval sequentially' do
  rl = RateLimiter.new(requests_per_second: 10) # 0.1s between calls
  start = Time.now
  5.times { rl.throttle! }
  elapsed = Time.now - start
  assert elapsed >= 0.4, "expected >=0.4s for 5 calls at 10/s, got #{elapsed.round(3)}s"
  assert_equal 5, rl.request_count
end

test 'rate limiter enforces rate under concurrency (no burst)' do
  rl = RateLimiter.new(requests_per_second: 20) # 0.05s between calls
  threads = 10.times.map { Thread.new { rl.throttle! } }
  start = Time.now
  threads.each(&:join)
  elapsed = Time.now - start
  # 10 calls at 20/s need at least 9 intervals = 0.45s.
  assert elapsed >= 0.4, "concurrent requests bursted the limiter: #{elapsed.round(3)}s"
  assert_equal 10, rl.request_count
end

test 'rate limiter allows immediate first call' do
  rl = RateLimiter.new(requests_per_second: 1)
  start = Time.now
  rl.throttle!
  assert (Time.now - start) < 0.1, 'first call should not wait'
  assert_equal 1, rl.request_count
end

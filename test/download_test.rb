require 'digest'

ORIG_SLEEP = Kernel.instance_method(:sleep)
FAST_SLEEP = proc { |*| }

# Stub Net::HTTP so downloads run deterministically without the network.
module Net
  class HTTP
    def request(_req)
      raise $raise_network if $raise_network

      body = $fake_body
      resp = Object.new
      resp.define_singleton_method(:is_a?) { |k| k == Net::HTTPSuccess }
      resp.define_singleton_method(:read_body) { |&b| b.call(body) }
      block_given? ? yield(resp) : resp
    end
  end
end

archiver = Archiver.new(
  username: 'tester',
  output_dir: Dir.pwd,
  interrupted: false,
  rate_limiter: RateLimiter.new(requests_per_second: 1_000_000)
)

test 'download_media streams, verifies MD5, and atomically renames' do
  $raise_network = nil
  body = "binary-content-#{rand(10_000)}"
  $fake_body = body
  expected = Digest::MD5.hexdigest(body)
  out = File.join(archiver.output_dir, '100.webp')
  File.delete(out) if File.exist?(out)

  res = archiver.download_media('http://cdn/100.webp', out, 100, expected, thread_idx: 0)

  assert_equal true, res
  assert File.exist?(out), 'output file should exist'
  assert_equal body, File.read(out), 'content should match streamed body'
  assert !File.exist?("#{out}.part"), 'temp part file should be removed'
end

test 'download_media fails and cleans up on MD5 mismatch' do
  $raise_network = nil
  $fake_body = 'real-body-bytes'
  out = File.join(archiver.output_dir, '101.webp')
  File.delete(out) if File.exist?(out)

  res = archiver.download_media('http://cdn/101.webp', out, 101, 'deadbeef', thread_idx: 0)

  assert_equal false, res
  assert !File.exist?(out), 'no output file on mismatch'
  assert !File.exist?("#{out}.part"), 'temp part cleaned up'
end

test 'download_media retries on network errors then fails' do
  Kernel.send(:define_method, :sleep, FAST_SLEEP)
  begin
    $raise_network = SocketError.new('boom')
    out = File.join(archiver.output_dir, '102.webp')
    File.delete(out) if File.exist?(out)

    res = archiver.download_media('http://cdn/102.webp', out, 102, 'x', thread_idx: 0)

    assert_equal false, res
    assert !File.exist?(out), 'no output on repeated network failure'
    assert !File.exist?("#{out}.part"), 'temp part cleaned up after retries'
  ensure
    Kernel.send(:define_method, :sleep, ORIG_SLEEP)
  end
end

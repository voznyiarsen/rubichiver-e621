archiver = Archiver.new(output_dir: Dir.pwd, username: 'tester', notify_url: 'http://localhost/notify')

test 'notify is a no-op when notify_url is unset' do
  a = Archiver.new(output_dir: Dir.pwd, username: 'tester')
  a.notify(event: 'x', success: true) # must not raise
  assert true
end

test 'notify POSTs a JSON report when notify_url is set' do
  orig = Net::HTTP.instance_method(:request)
  captured = nil
  Net::HTTP.send(:define_method, :request) do |req|
    captured = req.body if req.is_a?(Net::HTTP::Post)
    r = Object.new
    r.define_singleton_method(:is_a?) { |k| k == Net::HTTPSuccess }
    r
  end
  begin
    archiver.notify(event: 'x', success: true, failed: 0, total_posts: 5)
    assert captured, 'a POST body should be sent'
    parsed = JSON.parse(captured)
    assert_equal true, parsed['success']
    assert_equal 0, parsed['failed']
    assert_equal 5, parsed['total_posts']
  ensure
    Net::HTTP.send(:define_method, :request, orig)
  end
end

test 'notify tolerates network failure without raising' do
  orig = Net::HTTP.instance_method(:request)
  Net::HTTP.send(:define_method, :request) { |_req| raise SocketError, 'boom' }
  begin
    archiver.notify(event: 'x', success: false, failed: 3) # must not raise
    assert true
  ensure
    Net::HTTP.send(:define_method, :request, orig)
  end
end

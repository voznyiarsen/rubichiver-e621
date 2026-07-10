# frozen_string_literal: true

require_relative 'test_helper'

class HttpGetTest < Minitest::Test
  class FakeResponse
    def is_a?(klass)
      klass == Net::HTTPSuccess
    end
  end

  class FakeHTTP
    Get = Class.new { def initialize(*_args); end; def []=(*_a); end }
    @@calls = 0

    attr_accessor :read_timeout, :open_timeout, :use_ssl

    def initialize(*_args); end

    def request(_req)
      @@calls += 1
      FakeResponse.new
    end

    def self.reset!
      @@calls = 0
    end

    def self.calls
      @@calls
    end
  end

  def setup
    @archiver = GelbooruArchiver.new(
      output_dir: Dir.mktmpdir,
      api_key: 'key',
      user_id: '1'
    )
  end

  def teardown
    FileUtils.remove_entry(@archiver.output_dir)
  end

  def test_http_get_returns_without_looping_on_success
    real = Net.send(:remove_const, :HTTP)
    Net.send(:const_set, :HTTP, FakeHTTP)
    FakeHTTP.reset!
    begin
      res = @archiver.http_get(URI('http://example.com/path'), read_timeout: 5)
      assert_instance_of FakeResponse, res
      assert_equal 1, FakeHTTP.calls
    ensure
      Net.send(:remove_const, :HTTP)
      Net.send(:const_set, :HTTP, real)
    end
  end
end

class FakeHTTPRedirect
  Get = Class.new { def initialize(*_args); end; def []=(*_a); end }
  @@calls = 0
  @@first = true

  attr_accessor :read_timeout, :open_timeout, :use_ssl

  def initialize(*_args); end

  def request(req)
    @@calls += 1
    if @@first
      @@first = false
      RedirResponse.new
    else
      FinalResponse.new
    end
  end

  def self.reset!
    @@calls = 0
    @@first = true
  end

  def self.calls
    @@calls
  end
end

class RedirResponse
  def is_a?(klass)
    klass == Net::HTTPRedirection
  end

  def [](_key)
    '/final'
  end
end

class FinalResponse
  def is_a?(klass)
    klass == Net::HTTPSuccess
  end
end

class HttpGetRedirectTest < Minitest::Test
  def setup
    @archiver = GelbooruArchiver.new(
      output_dir: Dir.mktmpdir,
      api_key: 'key',
      user_id: '1'
    )
  end

  def teardown
    FileUtils.remove_entry(@archiver.output_dir)
  end

  def test_http_get_follows_redirect_then_stops
    real = Net.send(:remove_const, :HTTP)
    Net.send(:const_set, :HTTP, FakeHTTPRedirect)
    FakeHTTPRedirect.reset!
    begin
      res = @archiver.http_get(URI('http://example.com/start'), read_timeout: 5)
      assert_instance_of FinalResponse, res
      assert_equal 2, FakeHTTPRedirect.calls
    ensure
      Net.send(:remove_const, :HTTP)
      Net.send(:const_set, :HTTP, real)
    end
  end
end

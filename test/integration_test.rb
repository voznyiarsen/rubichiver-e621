# frozen_string_literal: true

require_relative 'test_helper'

class E621FetchIntegrationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @tags_file = File.join(@dir, 'tags.txt')
    File.write(@tags_file, "solo\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_e621_archiver_scan_existing_posts
    creds = File.join(@dir, 'creds.txt')
    File.write(creds, "USERNAME=tester\nAPI_KEY=key\n")
    File.write(File.join(@dir, '100.jpg'), 'fake')
    File.write(File.join(@dir, '101.png'), 'fake')

    archiver = E621Archiver.new(
      output_dir: @dir,
      credentials_file: creds,
      username: 'tester',
      api_key: 'key',
      tags_file: @tags_file
    )

    archiver.run

    # The run should fail because API key is fake, but we just test it doesn't crash
    # in unexpected ways. This is a smoke test.
  rescue SystemExit
    # expected - API call will fail with invalid credentials
  end
end

class GelbooruIntegrationTest < Minitest::Test
  PAGES = {
    1 => { '@attributes' => { 'count' => '3' }, 'post' => [
      { 'id' => '1', 'file_url' => 'https://x/1.jpg', 'md5' => 'a', 'tags' => 'cat dog', 'rating' => 'safe' },
      { 'id' => '2', 'file_url' => 'https://x/2.jpg', 'md5' => 'b', 'tags' => 'bird', 'rating' => 'questionable' }
    ]},
    2 => { '@attributes' => { 'count' => '3' }, 'post' => [
      { 'id' => '3', 'file_url' => 'https://x/3.jpg', 'md5' => 'c', 'tags' => 'fish', 'rating' => 'explicit' }
    ]},
    3 => { '@attributes' => { 'count' => '3' }, 'post' => [] }
  }.freeze

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def build_archiver(blacklist_body, tags: ['solo'])
    bl_path = File.join(@dir, 'bl.txt')
    File.write(bl_path, blacklist_body)
    tags_file = File.join(@dir, 'tags.txt')
    File.write(tags_file, tags.join(' '))

    GelbooruArchiver.new(
      output_dir: @dir,
      api_key: 'k',
      user_id: '1',
      tags_file: tags_file,
      blacklist_file: bl_path,
      rate_limit: 1000
    )
  end

  def setup_stubbed_http(archiver)
    def archiver.http_get(uri, read_timeout: 60, headers: {})
      m = uri.query.match(/pid=(\d+)/)
      page = (m ? m[1].to_i : 0) + 1
      data = GelbooruIntegrationTest::PAGES[page] || { '@attributes' => { 'count' => '3' }, 'post' => [] }
      body = JSON.generate(data)
      res = Net::HTTPResponse.new('1.1', 200, 'OK')
      res.instance_variable_set(:@body, body)
      def res.body; @body; end
      def res.read_body; @body; end
      def res.is_a?(k); k == Net::HTTPSuccess || super; end
      res
    end

    def archiver.download_media(url, output_file, post_id, md5, thread_idx: nil)
      File.write(output_file, 'fake')
      true
    end

    def archiver.sidecar_valid?(post)
      false
    end

    def archiver.write_sidecar(media_file, post)
      true
    end
  end

  def test_gelbooru_fetch_collects_all_posts_across_pages
    archiver = build_archiver('')
    setup_stubbed_http(archiver)

    stats = Stats.new
    posts = archiver.fetch_all_posts_for_query(['solo'], Set.new, stats)
    assert_equal %w[1 2 3], posts.map { |p| p['id'] }.sort
    assert_equal 3, stats.total_posts
  end

  def test_gelbooru_fetch_applies_blacklist
    archiver = build_archiver("rating:explicit\n")
    setup_stubbed_http(archiver)

    stats = Stats.new
    posts = archiver.fetch_all_posts_for_query(['solo'], Set.new, stats)
    assert_equal %w[1 2], posts.map { |p| p['id'] }.sort
    assert_equal 1, stats.blacklisted_files
  end

  def test_gelbooru_fetch_dedups_across_calls
    archiver = build_archiver('')
    setup_stubbed_http(archiver)

    stats = Stats.new
    seen = Set.new
    archiver.fetch_all_posts_for_query(['solo'], seen, stats)
    second = archiver.fetch_all_posts_for_query(['solo'], seen, Stats.new)
    assert_empty second
  end
end

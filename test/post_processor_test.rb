# frozen_string_literal: true

require_relative 'test_helper'

class PostProcessorUnitTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @stats = Stats.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  class TestArchiver
    attr_accessor :interrupted, :existing_posts

    def initialize
      @interrupted = false
      @existing_posts = {}
    end

    def post_file_url(post)
      post['file_url']
    end

    def post_file_ext(post)
      ext = File.extname(post['image'] || '').delete('.').downcase
      ext.empty? ? 'unknown' : ext
    end

    def post_md5(post)
      post['md5']
    end

    def resolve_served_extension(post, orig_ext, file_url)
      url_ext = File.extname(URI.parse(file_url || '').path).delete('.').downcase rescue ''
      if url_ext && !url_ext.empty? && url_ext != 'unknown'
        url_ext
      else
        orig_ext
      end
    end

    def sidecar_valid?(post)
      true
    end

    def download_media(url, output_file, post_id, md5, thread_idx: nil)
      File.write(output_file, 'fake')
      true
    end

    def write_sidecar(media_file, post)
      true
    end
  end

  def test_output_file_uses_served_extension
    archiver = TestArchiver.new
    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    post = {
      'id' => 42,
      'image' => 'orig.webm',
      'file_url' => 'https://gelbooru.com/images/42/abc123.mp4',
      'md5' => 'deadbeef',
      'tags' => 'cat',
      'rating' => 'safe'
    }

    archiver.existing_posts = {}
    pp.send(:process_post, post, 0)

    assert File.exist?(File.join(@dir, '42.mp4'))
  end

  def test_output_file_falls_back_to_original_extension
    archiver = TestArchiver.new
    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    post = {
      'id' => 7,
      'image' => 'orig.png',
      'file_url' => 'https://gelbooru.com/images/7/abc.png',
      'md5' => 'feedface',
      'tags' => 'dog',
      'rating' => 'safe'
    }

    archiver.existing_posts = {}
    pp.send(:process_post, post, 0)

    assert File.exist?(File.join(@dir, '7.png'))
  end

  def test_unsupported_extension_skips_download
    archiver = TestArchiver.new
    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    post = {
      'id' => 9,
      'image' => 'orig.swf',
      'file_url' => 'https://x/9.swf',
      'md5' => 'x',
      'tags' => 'a',
      'rating' => 'safe'
    }

    archiver.existing_posts = {}
    pp.send(:process_post, post, 0)

    refute File.exist?(File.join(@dir, '9.swf'))
    assert_equal 1, @stats.skipped_files
  end

  def test_existing_valid_sidecar_skips_download
    post = {
      'id' => 55,
      'image' => '55.jpeg',
      'file_url' => 'https://x/55.jpeg',
      'md5' => 'y',
      'tags' => 'cat',
      'rating' => 'safe'
    }

    File.write(File.join(@dir, '55.jpeg'), 'x')

    archiver = TestArchiver.new
    archiver.existing_posts = { 55 => File.join(@dir, '55.jpeg') }

    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.skipped_files
  end

  def test_existing_file_with_invalid_sidecar_regenerates
    post = {
      'id' => 56,
      'image' => '56.jpeg',
      'file_url' => 'https://x/56.jpeg',
      'md5' => 'y',
      'tags' => 'cat',
      'rating' => 'safe'
    }

    File.write(File.join(@dir, '56.jpeg'), 'x')

    archiver = TestArchiver.new
    def archiver.sidecar_valid?(post)
      false
    end
    archiver.existing_posts = { 56 => File.join(@dir, '56.jpeg') }

    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.autotagged_files
  end
end

class E621PostProcessorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @stats = Stats.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_process_e621_post
    post = {
      'id' => 100,
      'rating' => 's',
      'tags' => { 'general' => ['cat'], 'artist' => ['bob'] },
      'files' => {
        'original' => { 'url' => 'https://cdn.e621.net/data/abc.jpg' },
        'meta' => { 'ext' => 'jpg', 'md5' => 'deadbeef' }
      }
    }

    archiver = E621Archiver.new(
      output_dir: @dir,
      username: 'tester',
      api_key: 'key',
      rate_limiter: RateLimiter.new(requests_per_second: 1000)
    )
    archiver.existing_posts = {}

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

    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.downloaded_files
    assert File.exist?(File.join(@dir, '100.jpg'))
  end
end

class GelbooruPostProcessorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @stats = Stats.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_process_gelbooru_post
    post = {
      'id' => 200,
      'image' => '200.png',
      'file_url' => 'https://gelbooru.com/images/200/abc.png',
      'md5' => 'feedface',
      'tags' => 'cat dog',
      'rating' => 'safe'
    }

    archiver = GelbooruArchiver.new(
      output_dir: @dir,
      api_key: 'key',
      user_id: '1',
      rate_limiter: RateLimiter.new(requests_per_second: 1000)
    )
    archiver.existing_posts = {}

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

    pp = PostProcessor.new(
      rate_limiter: RateLimiter.new(requests_per_second: 1000),
      output_dir: @dir,
      stats: @stats,
      thread_count: 0,
      archiver: archiver
    )
    pp.send(:process_post, post, 0)

    assert_equal 1, @stats.downloaded_files
    assert File.exist?(File.join(@dir, '200.png'))
  end

  def test_categorize_tags
    archiver = GelbooruArchiver.new(
      output_dir: @dir,
      api_key: 'key',
      user_id: '1'
    )
    cats = archiver.categorize_tags('artist:alice character:bob copyright:series_x plain_tag')
    assert_equal ['alice'], cats['artist']
    assert_equal ['bob'], cats['character']
    assert_equal ['series_x'], cats['copyright']
    assert_equal ['plain_tag'], cats['general']
    cats2 = archiver.categorize_tags('rating:safe')
    assert_empty cats2['general']
  end
end

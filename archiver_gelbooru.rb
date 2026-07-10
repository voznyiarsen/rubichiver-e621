# frozen_string_literal: true

require 'json'
require 'uri'
require 'net/http'
require 'open3'
require 'digest'
require 'zlib'

GELBOORU_API_BASE = 'https://gelbooru.com'
GELBOORU_API_PATH = '/index.php'
GELBOORU_PAGE_LIMIT = 100
GELBOORU_USER_AGENT = 'rubichiver-gelbooru/1.0'

RATING_MAP_GELBOORU = {
  'safe' => '1', 's' => '1', 'g' => '1',
  'questionable' => '2', 'q' => '2',
  'explicit' => '3', 'e' => '3',
  'sensitive' => '2'
}.freeze

RATING_LABELS_GELBOORU = {
  'safe' => 'safe', 's' => 'safe', 'g' => 'safe',
  'questionable' => 'questionable', 'q' => 'questionable',
  'explicit' => 'explicit', 'e' => 'explicit',
  'sensitive' => 'sensitive'
}.freeze

TAG_PREFIX_MAP = {
  'artist' => 'artist',
  'character' => 'character',
  'copyright' => 'copyright',
  'series' => 'copyright',
  'circle' => 'contributor',
  'studio' => 'contributor',
  'metadata' => 'metadata',
  'style' => 'metadata',
  'species' => 'species',
  'lore' => 'lore',
  'rating' => 'rating'
}.freeze

class GelbooruArchiver < Archiver
  def default_output_dir
    './gelbooru-archive'
  end

  def site_name
    'gelbooru'
  end

  def load_credentials_from_file
    username = nil
    api_key = nil
    user_id = nil

    File.foreach(@credentials_file) do |line|
      line = line.strip
      if line.start_with?('USERNAME=')
        username = line.split('=', 2).last
      elsif line.start_with?('API_KEY=')
        api_key = line.split('=', 2).last
      elsif line.start_with?('USER_ID=')
        user_id = line.split('=', 2).last
      end
    end

    [username, api_key, user_id]
  end

  def post_file_url(post)
    post['file_url']
  end

  def post_file_ext(post)
    image_name = post['image'] || ''
    ext = File.extname(image_name).delete('.').downcase
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

  def http_get(uri, read_timeout: 60, headers: {})
    redirects = 0
    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = 30
      http.read_timeout = read_timeout

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = GELBOORU_USER_AGENT
      request['Accept-Encoding'] = 'identity'
      headers.each { |k, v| request[k] = v }

      response = http.request(request)

      if response.is_a?(Net::HTTPRedirection) && redirects < 5
        location = response['location']
        loc_uri = URI.parse(location)
        loc_uri = URI.join(uri, location) unless loc_uri.absolute?
        uri = loc_uri
        redirects += 1
        next
      end

      return response
    end
  end

  def query_cache_hash(tags)
    Digest::SHA256.hexdigest("gelbooru:" + tags.join(' '))
  end

  def normalize_posts(data)
    return nil unless data.is_a?(Hash)

    posts = data['post']
    return [] if posts.nil?
    return [posts] unless posts.is_a?(Array)

    posts
  end

  def api_search_posts(tags, page, force: false)
    ensure_rate_limiter
    FileUtils.mkdir_p(@cache_dir)
    query_hash = query_cache_hash(tags)
    cache_path = File.join(@cache_dir, "api_posts_#{query_hash}_p#{page}.json")

    if !force && File.exist?(cache_path)
      data = JSON.parse(File.read(cache_path))
      if data.is_a?(Hash) && data['@attributes']
        posts = normalize_posts(data)
        if posts
          count = data.dig('@attributes', 'count') || posts.size
          log_debug "Using cached API response for: #{tags.join(' ')} (page #{page}, #{posts.size} posts, total=#{count})", api: true
          return [posts, count]
        end
      end
      log_debug "Cached data is invalid for: #{tags.join(' ')} (page #{page}), re-fetching", api: true
    end

    @rate_limiter.throttle!
    uri = URI("#{GELBOORU_API_BASE}#{GELBOORU_API_PATH}")
    params = {
      page: 'dapi', s: 'post', q: 'index',
      tags: tags.join(' '), pid: page - 1, limit: GELBOORU_PAGE_LIMIT, json: 1,
      api_key: @api_key, user_id: @user_id
    }
    uri.query = URI.encode_www_form(params)

    response = http_get(uri, read_timeout: 60)
    unless response.is_a?(Net::HTTPSuccess)
      log_error "API search failed", tags: tags.join(' '), page: page, status: response.code, api: true
      return [nil, 0]
    end

    data = JSON.parse(response.body)

    unless data.is_a?(Hash) && data['@attributes']
      log_error "API response missing @attributes metadata", tags: tags.join(' '), page: page, api: true
      return [nil, 0]
    end

    posts = normalize_posts(data)
    unless posts
      log_error "API returned no post data", tags: tags.join(' '), page: page, api: true
      return [nil, 0]
    end

    count = data['@attributes']['count'] || posts.size
    File.write(cache_path, JSON.pretty_generate(data))
    log_debug "Cached API response: #{tags.join(' ')} (page #{page}, #{posts.size} posts, total=#{count})", api: true
    [posts, count]
  rescue JSON::ParserError, Zlib::BufError, IOError, SystemCallError => e
    log_error "Failed to parse API response", error: e.message, api: true
    [nil, 0]
  end

  def cache_needs_update?(query_tags)
    query_hash = query_cache_hash(query_tags)
    cached_p1 = File.join(@cache_dir, "api_posts_#{query_hash}_p1.json")

    if File.exist?(cached_p1)
      begin
        data = JSON.parse(File.read(cached_p1))
        posts = normalize_posts(data) || []
        return [true, nil, 0] if posts.empty?
        cached_ids = posts.map { |p| p['id'] }.to_set
      rescue JSON::ParserError, IOError, SystemCallError, StandardError => e
        return [true, nil, 0]
      end
    else
      return [true, nil, 0]
    end

    fresh_p1, fresh_count = api_search_posts(query_tags, 1, force: true)
    return [false, nil, 0] unless fresh_p1

    fresh_ids = fresh_p1.map { |p| p['id'] }.to_set

    [cached_ids != fresh_ids, fresh_p1, fresh_count]
  end

  def clear_tag_cache(tags)
    query_hash = query_cache_hash(tags)
    Dir.glob(File.join(@cache_dir, "api_posts_#{query_hash}_p*.json")).each do |f|
      File.delete(f)
      log_debug "Deleted cache file: #{File.basename(f)}", api: true
    end
  end

  def fetch_all_posts_for_query(query_tags, seen_ids, stats)
    query_str = query_tags.join(' ')
    log_info "Fetching posts for: #{query_str}", query: query_str, api: true

    needs_update, fresh_p1, fresh_count = cache_needs_update?(query_tags)
    if needs_update
      log_info "Cache update needed for: #{query_str}, refreshing...", query: query_str, api: true
      clear_tag_cache(query_tags)
      fresh_p1 = nil
    else
      log_info "Cache is up to date for: #{query_str}", query: query_str, api: true
    end

    all_posts = []
    page = 1
    total_count = nil

    loop do
      if page == 1 && fresh_p1
        posts = fresh_p1
        count = fresh_count
      else
        posts, count = api_search_posts(query_tags, page)
      end
      total_count = count.to_i if count.to_i.positive?
      break unless posts
      break if posts.empty?

      log_debug "Page #{page}: #{posts.size} posts, total=#{total_count || '?'}", api: true

      posts.each do |post|
        next if seen_ids.include?(post['id'])

        tag_string = post['tags'] || ''
        tag_set = tag_string.split
        rating = post['rating']
        post_id = post['id']

        if blacklist.any? && blacklist.blacklisted?(tag_set, rating, post_id)
          log_debug "Post #{post_id}: Blacklisted, skipping", post_id: post_id, api: true
          stats.increment(:blacklisted_files)
          seen_ids.add(post_id)
          next
        end

        file_url = post['file_url']
        unless file_url
          log_debug "Post #{post_id}: No file URL, skipping", post_id: post_id, api: true
          next
        end

        seen_ids.add(post_id)
        stats.increment(:total_posts)
        all_posts << post
      end

      log_debug "Page #{page}: #{all_posts.size}/#{total_count || '?'} unique posts collected so far", api: true
      break if total_count && all_posts.size >= total_count
      page += 1
    end

    all_posts
  end

  def download_media(url, output_file, post_id, expected_md5, thread_idx: nil)
    ensure_rate_limiter
    tmp_file = "#{output_file}.part"
    retries = 0

    while retries < MAX_RETRIES
      break if @interrupted

      @rate_limiter.throttle!

      response = http_get(
        URI(url),
        read_timeout: 30,
        headers: { 'Accept-Encoding' => 'identity', 'Referer' => "#{GELBOORU_API_BASE}/" }
      )

      begin
        if response.is_a?(Net::HTTPSuccess)
          File.open(tmp_file, 'wb') { |f| f.write(response.body) }

          if expected_md5 && !expected_md5.empty?
            if Digest::MD5.file(tmp_file).hexdigest == expected_md5
              File.rename(tmp_file, output_file)
              return true
            else
              log_error "Post #{post_id}: MD5 mismatch (expected #{expected_md5})", post_id: post_id, thread: thread_idx, api: true
              File.delete(tmp_file) if File.exist?(tmp_file)
            end
          else
            File.rename(tmp_file, output_file)
            log_debug "Post #{post_id}: No MD5 provided, skipping verification", post_id: post_id, thread: thread_idx, api: true
            return true
          end
        else
          log_warn "Post #{post_id}: HTTP #{response.code} during download", post_id: post_id, thread: thread_idx, status: response.code, api: true
        end
      rescue Zlib::BufError => e
        log_debug "Post #{post_id}: Download corrupted, retrying...", post_id: post_id, error: e.message, thread: thread_idx, api: true
      rescue => e
        log_warn "Post #{post_id}: Download error: #{e.message}", post_id: post_id, thread: thread_idx, error: e.message, api: true
      end

      File.delete(tmp_file) if File.exist?(tmp_file)
      retries += 1
      if retries < MAX_RETRIES
        delay = RETRY_BACKOFF * (2 ** retries) + rand * 0.5
        log_info "Post #{post_id}: Retrying in #{format('%.1f', delay)}s (attempt #{retries + 1}/#{MAX_RETRIES})", post_id: post_id, retry_count: retries, delay: delay.round(1), thread: thread_idx, api: true
        sleep(delay)
        break if @interrupted
      end
    end

    false
  end

  def categorize_tags(tag_string)
    categories = Hash.new { |h, k| h[k] = [] }

    tag_string.split.each do |tag|
      if tag.include?(':')
        prefix, name = tag.split(':', 2)
        next if prefix == 'rating'
        category = TAG_PREFIX_MAP[prefix] || 'general'
        categories[category] << name
      else
        categories['general'] << tag
      end
    end

    categories
  end

  def extract_post_tags(post)
    tags = []
    tag_string = post['tags'] || ''
    categorized = categorize_tags(tag_string)
    self.class::TAG_CATEGORIES.each do |category|
      (categorized[category] || []).each { |tag| tags << "#{category}:#{tag}" }
    end
    tags
  end

  def rating_value(rating)
    RATING_MAP_GELBOORU[rating]
  end

  def rating_label(post)
    RATING_LABELS_GELBOORU[post['rating']]
  end
end

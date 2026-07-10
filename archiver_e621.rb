# frozen_string_literal: true

require 'json'
require 'uri'
require 'net/http'
require 'open3'
require 'digest'

API_BASE = 'https://e621.net'
MAX_PAGES = 2000

RATING_MAP_E621 = {
  's' => '1',
  'q' => '2',
  'e' => '3'
}.freeze

RATING_LABELS_E621 = {
  's' => 'safe',
  'q' => 'questionable',
  'e' => 'explicit'
}.freeze

class E621Archiver < Archiver
  def default_output_dir
    './e621-archive'
  end

  def site_name
    'e621'
  end

  def load_credentials_from_file
    username = nil
    api_key = nil

    File.foreach(@credentials_file) do |line|
      line = line.strip
      if line.start_with?('USERNAME=')
        username = line.split('=', 2).last
      elsif line.start_with?('API_KEY=')
        api_key = line.split('=', 2).last
      end
    end

    [username, api_key, nil]
  end

  def post_file_url(post)
    post.dig('files', 'original', 'url')
  end

  def post_file_ext(post)
    post.dig('files', 'meta', 'ext') || 'unknown'
  end

  def post_md5(post)
    post.dig('files', 'meta', 'md5')
  end

  def api_search_posts(tags, page, force: false)
    ensure_rate_limiter
    FileUtils.mkdir_p(@cache_dir)
    query_hash = Digest::SHA256.hexdigest("v2:" + tags.sort.join(' '))
    cache_path = File.join(@cache_dir, "api_posts_#{query_hash}_p#{page}.json")

    unless force
      if File.exist?(cache_path)
        data = JSON.parse(File.read(cache_path))
        log_debug "Using cached API response for: #{tags.join(' ')} (page #{page}, #{data&.size || 0} posts)", api: true
        return data
      end
    end

    posts = nil
    retries = 0
    while retries < MAX_RETRIES
      break if @interrupted

      @rate_limiter.throttle!
      uri = URI("#{API_BASE}/posts.json")
      uri.query = URI.encode_www_form(tags: tags.join(' '), page: page, limit: 320, v2: true, mode: 'extended')

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 60
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = "rubichiver-e621/1.0 (used by #{@username} on e621)"
      request['Accept-Encoding'] = 'identity'
      request.basic_auth(@username, @api_key)

      response =
        begin
          http.request(request)
        rescue *NETWORK_ERRORS => e
          log_warn "API request error (attempt #{retries + 1}/#{MAX_RETRIES})",
                   error: e.message, tags: tags.join(' '), page: page, api: true
          nil
        end

      if response.nil?
        retries += 1
        if retries < MAX_RETRIES
          delay = RETRY_BACKOFF * (2 ** retries) + rand * 0.5
          sleep(delay)
          break if @interrupted
        end
        next
      end

      if response.is_a?(Net::HTTPSuccess)
        begin
          parsed = JSON.parse(response.body)
          posts = parsed.is_a?(Array) ? parsed : []
          break
        rescue JSON::ParserError => e
          log_error "Failed to parse API response", error: e.message, api: true
          return nil
        end
      elsif [429, 503].include?(response.code.to_i)
        log_warn "API rate limited (#{response.code}), retrying...", tags: tags.join(' '), page: page, api: true
        retries += 1
        if retries < MAX_RETRIES
          delay = RETRY_BACKOFF * (2 ** retries) + rand * 0.5
          sleep(delay)
          break if @interrupted
        end
        next
      else
        log_error "API search failed", tags: tags.join(' '), page: page, status: response.code, api: true
        return nil
      end
    end

    return nil unless posts

    File.write(cache_path, JSON.pretty_generate(posts))
    log_debug "Cached API response: #{tags.join(' ')} (page #{page}, #{posts.size} posts)", api: true
    posts
  end

  def fetch_all_posts_for_query(query_tags, seen_ids, stats)
    query_str = query_tags.join(' ')
    log_info "Fetching posts for: #{query_str}", query: query_str, api: true

    fresh_p1 = api_search_posts(query_tags, 1, force: true)
    return [] unless fresh_p1

    query_hash = Digest::SHA256.hexdigest("v2:" + query_tags.sort.join(' '))
    cache_p1_path = File.join(@cache_dir, "api_posts_#{query_hash}_p1.json")

    needs_update = false
    if File.exist?(cache_p1_path)
      cached_p1 = JSON.parse(File.read(cache_p1_path))
      fresh_ids = fresh_p1.map { |p| p['id'] }
      cached_ids = cached_p1.map { |p| p['id'] }
      new_ids = fresh_ids - cached_ids
      if new_ids.any?
        log_info "New posts detected for: #{query_str} (#{new_ids.size} new), updating cache...", api: true
        needs_update = true
      else
        log_debug "No new posts for: #{query_str}, using cached pages", api: true
      end
    else
      log_debug "No existing cache for: #{query_str}, performing full fetch", api: true
      needs_update = true
    end

    all_posts = []
    page = 1

    loop do
      break if page > MAX_PAGES

      posts = if page == 1
                fresh_p1
              else
                cached = api_search_posts(query_tags, page, force: needs_update)
                if cached.nil? && !needs_update
                  log_debug "Cache miss for page #{page}, fetching live", query: query_str, api: true
                  cached = api_search_posts(query_tags, page, force: true)
                end
                cached
              end
      break unless posts
      break if posts.empty?

      posts.each do |post|
        next if seen_ids.include?(post['id'])

        post_tags = post['tags'] || {}
        tag_set = post_tags.values.flatten
        rating = post['rating']
        post_id = post['id']

        if blacklist.any? && blacklist.blacklisted?(tag_set, rating, post_id)
          stats.increment(:blacklisted_files)
          seen_ids.add(post_id)
          next
        end

        file_url = post.dig('files', 'original', 'url')
        next unless file_url

        seen_ids.add(post_id)
        stats.increment(:total_posts)
        all_posts << post
      end

      break if posts.size < 320
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

      success = false
      @rate_limiter.throttle!

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 300

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = "rubichiver-e621/1.0 (used by #{@username} on e621)"
      request['Accept-Encoding'] = 'identity'

      digest = Digest::MD5.new

      begin
        http.request(request) do |res|
          if res.is_a?(Net::HTTPSuccess)
            File.open(tmp_file, 'wb') do |f|
              res.read_body { |chunk| f.write(chunk); digest.update(chunk) }
            end

            if digest.hexdigest == expected_md5
              File.rename(tmp_file, output_file)
              success = true
            else
              log_error "MD5 mismatch for post #{post_id}", post_id: post_id, thread: thread_idx, api: true
            end
          else
            log_error "Download failed", post_id: post_id, status: res.code, thread: thread_idx, api: true
          end
        end
      rescue *NETWORK_ERRORS => e
        log_warn "Network error downloading post #{post_id} (attempt #{retries + 1}/#{MAX_RETRIES}): #{e.message}",
                 post_id: post_id, thread: thread_idx, api: true
      end

      return true if success

      File.delete(tmp_file) if File.exist?(tmp_file)
      retries += 1
      if retries < MAX_RETRIES
        delay = RETRY_BACKOFF * (2 ** retries) + rand * 0.5
        log_debug "Retrying in #{format('%.1f', delay)}s...", post_id: post_id, retry_count: retries, api: true
        sleep(delay)
        break if @interrupted
      end
    end

    false
  end

  def extract_post_tags(post)
    tags = []
    self.class::TAG_CATEGORIES.each do |category|
      (post.dig('tags', category) || []).each { |tag| tags << "#{category}:#{tag}" }
    end
    tags
  end

  def rating_value(rating)
    RATING_MAP_E621[rating]
  end

  def rating_label(post)
    RATING_LABELS_E621[post['rating']]
  end
end

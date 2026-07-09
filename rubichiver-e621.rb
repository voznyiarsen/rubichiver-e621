#!/usr/bin/env ruby
# frozen_string_literal: true

# rubichiver-e621 - e621 Media Archiver
# Downloads media from e621 and writes XMP sidecar metadata

require 'optparse'
require 'fileutils'
require 'json'
require 'digest'
require 'set'
require 'net/http'
require 'uri'
require 'open3'
require_relative 'logger'
require_relative 'rate_limiter'
require_relative 'post_processor'
require_relative 'blacklist'

# Constants
API_BASE = 'https://e621.net'
MAX_RETRIES = 3
RETRY_BACKOFF = 1

# Rating mapping for XMP (XMP:Rating uses numeric 1-3)
RATING_MAP = {
  's' => '1',
  'q' => '2',
  'e' => '3'
}.freeze

RATING_LABELS = {
  's' => 'safe',
  'q' => 'questionable',
  'e' => 'explicit'
}.freeze

# Tag categories for XMP
TAG_CATEGORIES = %w[general artist contributor copyright character species invalid meta lore].freeze

# File extensions that are not supported and should be skipped
UNSUPPORTED_EXTENSIONS = %w[swf].freeze

# Safety cap to prevent an infinite pagination loop if the API misbehaves.
MAX_PAGES = 2000

# Transient errors that should be retried rather than aborting the run.
NETWORK_ERRORS = [
  SocketError,
  Net::OpenTimeout,
  Net::ReadTimeout,
  Errno::ECONNRESET,
  Errno::ECONNREFUSED,
  OpenSSL::SSL::SSLError,
  Zlib::BufError,
  Zlib::DataError
].freeze

# Encapsulates the entire archiver: configuration, API discovery, downloading,
# and XMP sidecar writing. Replaces the previous global-mutable-state design.
class Archiver
  attr_accessor :username, :api_key, :output_dir, :cache_dir, :tags_file, :credentials_file,
                :blacklist_file, :dry_run, :thread_count, :rate_limit,
                :rate_limiter, :blacklist, :existing_posts, :interrupted, :verbose,
                :notify_url

  def initialize(username: nil, api_key: nil, output_dir: './e621-archive',
                 cache_dir: nil,
                 tags_file: './tags.txt', credentials_file: './api_credentials.txt',
                 blacklist_file: './blacklist.txt', dry_run: false,
                 thread_count: 2, rate_limit: 1, verbose: false,
                 interrupted: false, rate_limiter: nil, notify_url: nil,
                 recheck_sidecars: false)
    @username = username
    @api_key = api_key
    @output_dir = output_dir
    @cache_dir = cache_dir || File.join(@output_dir, 'cache')
    @tags_file = tags_file
    @credentials_file = credentials_file
    @blacklist_file = blacklist_file
    @dry_run = dry_run
    @thread_count = thread_count
    @rate_limit = rate_limit
    @verbose = verbose
    @interrupted = interrupted
    @rate_limiter = rate_limiter
    @blacklist = nil
    @existing_posts = {}
    @notify_url = notify_url
    @recheck_sidecars = recheck_sidecars
  end

  # --- Bootstrap / entry point -------------------------------------------

  def run
    @username, @api_key = load_credentials
    unless @username && @api_key
      missing = []
      missing << 'USERNAME' if @username.nil?
      missing << 'API_KEY' if @api_key.nil?
      if File.exist?(@credentials_file)
        log_fatal "Incomplete API credentials (missing: #{missing.join(', ')})", credentials_file: @credentials_file
      else
        log_fatal "API credentials file not found", credentials_file: @credentials_file
      end
      exit 1
    end

    unless @dry_run
      FileUtils.mkdir_p(@output_dir) unless Dir.exist?(@output_dir)
    end

    @rate_limiter = RateLimiter.new(requests_per_second: @rate_limit)
    @blacklist = Blacklist.new(@blacklist_file)
    @existing_posts = {}
    if Dir.exist?(@output_dir)
      Dir.children(@output_dir).each do |file|
        next if file.start_with?('.')
        next if file.end_with?('.xmp')
        full = File.join(@output_dir, file)
        next unless File.file?(full)
        if file =~ /\A(\d+)\./
          @existing_posts[$1.to_i] = full
        end
      end
      log_info "Found #{@existing_posts.size} existing files in output directory"
    end

    log_info "e621 Archiver starting..."
    log_info "Output directory: #{@output_dir}", output_dir: @output_dir
    log_info "Tags file: #{@tags_file}", tags_file: @tags_file
    log_info "API username: #{@username}", username: @username
    log_info "Max retries: #{MAX_RETRIES}", max_retries: MAX_RETRIES
    log_info "Worker threads: #{@thread_count}", threads: @thread_count
    if @blacklist&.any?
      log_info "Blacklist: #{@blacklist_file}", blacklist: @blacklist_file
    end
    log_info ""

    start_time = Time.now

    stats = Stats.new
    processor = PostProcessor.new(
      rate_limiter: @rate_limiter,
      output_dir: @output_dir,
      stats: stats,
      thread_count: @thread_count,
      dry_run: @dry_run,
      archiver: self
    )

    if @recheck_sidecars
      log_info "Sidecar recheck mode — scanning existing files and validating sidecars"
      recheck_all_sidecars(processor, stats)
    else
      unless File.exist?(@tags_file)
        log_error "Cannot open tags file", tags_file: @tags_file
        exit 1
      end

      if @dry_run
        log_info "Dry run mode — discovering posts that would be archived (no files written)"
      end

      process_tag_queries(processor, stats)
    end

    processor.finish
    processor.wait

    if @interrupted
      log_warn "Interrupted — partial results below"
    end

    end_time = Time.now
    elapsed = end_time - start_time
    total_requests = @rate_limiter.request_count
    requests_per_sec = total_requests / elapsed if elapsed.positive?

    logger.separator
    logger.info 'SUMMARY'
    logger.separator
    logger.info "Total posts processed: #{stats.total_posts}", total_posts: stats.total_posts
    logger.info "Files downloaded: #{stats.downloaded_files}", downloaded: stats.downloaded_files
    if stats.autotagged_files > 0
      logger.info "Existing files auto-tagged: #{stats.autotagged_files}", autotagged: stats.autotagged_files
    end
    logger.info "Files skipped (already exist): #{stats.skipped_files}", skipped: stats.skipped_files
    logger.info "Files failed: #{stats.failed_files}", failed: stats.failed_files
    if stats.blacklisted_files > 0
      logger.info "Files blacklisted: #{stats.blacklisted_files}", blacklisted: stats.blacklisted_files
    end
    if @dry_run
      logger.info "DRY RUN — no files were written", dry_run: true
    end
    logger.info "Throttled requests (API + downloads): #{total_requests}", request_count: total_requests
    logger.info "Time elapsed: #{format('%.2f', elapsed)}s", elapsed_seconds: elapsed.round(2)
    if requests_per_sec
      logger.info "Requests per second: #{format('%.2f', requests_per_sec)}", requests_per_sec: requests_per_sec.round(2)
    end
    logger.separator

    report = {
      event: 'rubichiver-e621.run-complete',
      success: stats.failed_files.zero? && !@interrupted,
      interrupted: @interrupted,
      dry_run: @dry_run,
      output_dir: @output_dir,
      total_posts: stats.total_posts,
      downloaded: stats.downloaded_files,
      autotagged: stats.autotagged_files,
      skipped: stats.skipped_files,
      failed: stats.failed_files,
      blacklisted: stats.blacklisted_files,
      timestamp: Time.now.utc.iso8601
    }
    notify(report)

    exit(@interrupted || stats.failed_files > 0 ? 1 : 0)
  end

  def install_signal_handlers
    # NOTE: signal handlers run in Ruby's "trap context", where locking a Mutex
    # (and thus the logger, which synchronizes writes) is forbidden and raises
    # ThreadError. We write directly to $stderr for immediate feedback — it is
    # safe in trap context (uses internal IO locks, not Thread::Mutex).
    trap('INT') do
      if @interrupted
        $stderr.puts "[Interrupt] Force exiting..."
        trap('INT', 'DEFAULT')
        Process.kill('INT', Process.pid)
      else
        @interrupted = true
        $stderr.puts "[Interrupt] Graceful shutdown initiated, finishing in-progress work... (press Ctrl+C again to force exit)"
      end
    end

    trap('TERM') do
      if @interrupted
        $stderr.puts "[Interrupt] Force exiting..."
        trap('TERM', 'DEFAULT')
        Process.kill('TERM', Process.pid)
      else
        @interrupted = true
        $stderr.puts "[Interrupt] Graceful shutdown initiated... (send again to force exit)"
      end
    end
  end

  # --- Credentials --------------------------------------------------------

  def load_credentials
    return [nil, nil] unless File.exist?(@credentials_file)

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

    [username, api_key]
  end

  # --- API discovery ------------------------------------------------------

  # Fetch a single page of posts from the e621 API, with file-based caching.
  # Retries on transient network errors and on rate-limit responses (429/503)
  # with exponential backoff before giving up.
  def api_search_posts(tags, page, force: false)
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

  # Fetch all pages of posts for a single tag query from the API.
  def fetch_all_posts_for_query(query_tags, seen_ids, stats)
    query_str = query_tags.join(' ')
    log_info "Fetching posts for: #{query_str}", query: query_str, api: true

    # Always fetch page 1 fresh to check for new posts.
    fresh_p1 = api_search_posts(query_tags, 1, force: true)
    return [] unless fresh_p1

    # Check if there are new posts by comparing fresh page 1 with cached page 1.
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
                # If we decided the cache was still valid but the deeper page is
                # missing/stale, fall back to a live fetch rather than silently
                # dropping posts.
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

        if @blacklist&.any? && @blacklist.blacklisted?(tag_set, rating, post_id)
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

  # Process all tag queries from the tags file via API.
  def process_tag_queries(processor, stats)
    queries = []
    File.foreach(@tags_file) do |line|
      line = line.chomp
      next if line.strip.empty?
      queries << line.split
    end

    if queries.empty?
      log_warn "No tag queries found in tags file", tags_file: @tags_file
      return
    end

    seen_ids = Set.new
    queries.each do |query_tags|
      break if @interrupted
      posts = fetch_all_posts_for_query(query_tags, seen_ids, stats)
      posts.each { |post| processor.enqueue(post) }
    end
  end

  # Recheck all existing sidecars in the output directory.
  #
  # Scans for media files (non-.xmp, non-.part), batches their post IDs into
  # groups of up to BATCH_SIZE, fetches post metadata from e621 via a single
  # API call per batch, and enqueues each post so the worker pool validates
  # its sidecar and regenerates if missing or invalid.
  BATCH_SIZE = 300
  def recheck_all_sidecars(processor, stats)
    media_files = Dir.children(@output_dir).select do |f|
      next if f.start_with?('.') || f.end_with?('.xmp') || f.end_with?('.part')
      File.file?(File.join(@output_dir, f))
    end

    if media_files.empty?
      log_info "No media files found in output directory"
      return
    end

    post_ids = Set.new
    media_files.each do |file|
      next unless file =~ /\A(\d+)\./
      post_ids << $1.to_i
    end

    log_info "Found #{post_ids.size} unique posts to recheck"

    unless @dry_run
      FileUtils.mkdir_p(@cache_dir)
    end

    ids = post_ids.to_a
    total_batches = (ids.size.to_f / BATCH_SIZE).ceil

    ids.each_slice(BATCH_SIZE).with_index do |id_batch, idx|
      break if @interrupted

      log_info "Recheck batch #{idx + 1}/#{total_batches} (#{id_batch.size} IDs)", batch: idx + 1, total_batches: total_batches, api: true
      tag = "id:#{id_batch.join(',')}"
      posts = api_search_posts([tag], 1, force: true)
      next unless posts

      posts.each do |post|
        break if @interrupted
        stats.increment(:total_posts)
        processor.enqueue(post)
      end
    end
  end

  # --- Download + sidecar -------------------------------------------------

  # Download media file with retries.
  # - Streams the response body to disk (no full-file buffering in memory).
  # - Computes the MD5 incrementally in a single pass (no second file read).
  # - Writes to a ".part" temp file and atomically renames on success, so an
  #   interrupted/crashed download never leaves a corrupt final file behind.
  # - Does NOT send API credentials to the static file CDN.
  # - Retries on transient network errors before giving up.
  def download_media(url, output_file, post_id, expected_md5, thread_idx: nil)
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
      # Intentionally no basic_auth: the file CDN does not require it and we
      # avoid transmitting API credentials to a second host.

      digest = Digest::MD5.new

      begin
        # Pass a block to request so the body is streamed (read exactly once).
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

  # Validate an existing sidecar. It must parse, carry the expected XMP:Rating,
  # and contain every expected XMP:Subject keyword. Returns false (which triggers
  # a rewrite) when the sidecar is missing, unparseable, or incomplete.
  def sidecar_valid?(post)
    post_id = post['id']
    sidecar = File.join(@output_dir, "#{post_id}.xmp")
    return false unless File.exist?(sidecar)

    rating_label = RATING_LABELS[post['rating']]
    return false unless rating_label
    expected_rating = RATING_MAP[post['rating']]

    stdout, _stderr, status = Open3.capture3('exiftool', '-json', '-XMP:Rating', '-XMP:Subject', sidecar)
    return false unless status.success?

    data = JSON.parse(stdout) rescue nil
    data = data.first if data.is_a?(Array)
    return false unless data.is_a?(Hash)

    return false unless data['Rating'].to_s == expected_rating

    subjects = data['Subject']
    subjects = [subjects] if subjects.is_a?(String)
    return false unless subjects.is_a?(Array)

    expected = ["rating:#{rating_label}"]
    TAG_CATEGORIES.each do |category|
      (post.dig('tags', category) || []).each { |tag| expected << "#{category}:#{tag}" }
    end

    expected.all? { |kw| subjects.include?(kw) }
  end

  # Write XMP sidecar with keyword + rating metadata.
  #
  # Tags are written as XMP:Subject (dc:subject) — the canonical IPTC Core
  # "Keywords" field, which is the correct XMP representation of keywords.
  # IPTC-IIM (IPTC:Keywords) cannot be stored in a standalone XMP sidecar, so
  # it is intentionally omitted.
  def write_sidecar(media_file, post)
    post_id = post['id']
    sidecar = File.join(@output_dir, "#{post_id}.xmp")

    rating_label = RATING_LABELS[post['rating']]
    return false unless rating_label

    rating_value = RATING_MAP[post['rating']]

    File.delete(sidecar) if File.exist?(sidecar)

    args = ['-o', sidecar]
    args << "-XMP:Rating=#{rating_value}"
    args << "-XMP:Subject+=rating:#{rating_label}"

    TAG_CATEGORIES.each do |category|
      tags = post.dig('tags', category) || []
      tags.each do |tag|
        args << "-XMP:Subject+=#{category}:#{tag}"
      end
    end

    args << media_file

    _stdout, stderr, status = Open3.capture3('exiftool', *args)

    if status.success? && File.exist?(sidecar)
      true
    else
      log_error "exiftool sidecar write failed: #{stderr}", sidecar: sidecar, post_id: post_id, stderr: stderr
      false
    end
  end

  # POST a JSON run report to the configured webhook (if any). Network or
  # HTTP errors are logged but never abort the run.
  def notify(report)
    return unless @notify_url

    uri = URI(@notify_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true if uri.scheme == 'https'
    http.open_timeout = 30
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(report)

    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      log_warn "Alert notification failed", status: response&.code, api: true
    end
  rescue *NETWORK_ERRORS => e
    log_warn "Alert notification failed: #{e.message}", api: true
  end
end

# --- Script entry point ---------------------------------------------------

if __FILE__ == $PROGRAM_NAME
  options = {
    output: './e621-archive',
    tags: './tags.txt',
    credentials: './api_credentials.txt',
    blacklist: './blacklist.txt',
    dry_run: false,
    verbose: false,
    json: false,
    threads: 2,
    rate_limit: 1
  }

  OptionParser.new do |opts|
    opts.banner = <<~USAGE
      Usage: rubichiver-e621.rb [OPTIONS]

      Modes:
        default   Read tags from tags file, fetch matching posts, download media,
                  and write XMP sidecars with XMP:Subject keywords + XMP:Rating.
        --recheck-sidecars  Scan the output directory, fetch post metadata, and
                  regenerate any missing or invalid XMP sidecars.

      The tool will:
        1. Read tags from the tags file (whitespace-separated tags per line)
        2. For each line, fetch matching posts from the e621 API (paginated, 320 per page)
        3. Filter posts against a blacklist file (e621 blacklist syntax)
        4. Download media files (images/videos)
        5. Write XMP sidecar files with XMP:Subject (tags by category + rating)
        6. No transcoding — media files are kept in their original format
    USAGE

    opts.on('-o', '--output DIR', 'Output directory') { |v| options[:output] = v }
    opts.on('-t', '--tags FILE', 'Tags file') { |v| options[:tags] = v }
    opts.on('-c', '--credentials FILE', 'API credentials file') { |v| options[:credentials] = v }
    opts.on('--dry-run', 'Show what would be done without downloading') { options[:dry_run] = true }
    opts.on('-v', '--verbose', 'Verbose output') { options[:verbose] = true }
    opts.on('--json', 'JSON log output (machine-parseable)') { options[:json] = true }
    opts.on('-j', '--threads N', Integer, 'Number of worker threads (default: 2)') { |v| options[:threads] = v }
    opts.on('--rate-limit N', Float, 'API requests per second (default: 1)') { |v| options[:rate_limit] = v }
    opts.on('-b', '--blacklist FILE', 'Blacklist file (e621 syntax, default: ./blacklist.txt)') { |v| options[:blacklist] = v }
    opts.on('--notify URL', 'POST a JSON run report to URL on completion (e.g. ntfy/Slack/Discord webhook)') { |v| options[:notify] = v }
    opts.on('--recheck-sidecars', 'Recheck all existing sidecars and regenerate missing/invalid ones') { options[:recheck_sidecars] = true }
    opts.on('-C', '--cache-dir DIR', 'Cache directory for API responses (default: $output_dir/cache)') { |v| options[:cache_dir] = v }
    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit 0
    end
  end.parse!

  E621Archiver::Logger.configure(
    level: options[:verbose] ? :debug : :info,
    format: options[:json] ? :json : :human
  )

  archiver = Archiver.new(
    output_dir: options[:output],
    tags_file: options[:tags],
    credentials_file: options[:credentials],
    blacklist_file: options[:blacklist],
    dry_run: options[:dry_run],
    thread_count: options[:threads],
    rate_limit: options[:rate_limit],
    verbose: options[:verbose],
    notify_url: options[:notify],
    cache_dir: options[:cache_dir],
    recheck_sidecars: options[:recheck_sidecars]
  )
  archiver.install_signal_handlers
  archiver.run
end

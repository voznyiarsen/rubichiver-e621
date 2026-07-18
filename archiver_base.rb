# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'set'
require 'net/http'
require 'uri'
require 'open3'
require_relative 'dns_cache'

MAX_RETRIES = 3
RETRY_BACKOFF = 1

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

class Archiver
  TAG_CATEGORIES = %w[general artist contributor copyright character species invalid meta lore].freeze
  BATCH_SIZE = 300

  attr_accessor :username, :api_key, :output_dir, :cache_dir, :tags_file, :credentials_file,
                :blacklist_file, :dry_run, :thread_count, :rate_limit,
                :rate_limiter, :blacklist, :existing_posts, :interrupted, :verbose,
                :notify_url, :user_id

  def initialize(username: nil, api_key: nil, user_id: nil, output_dir: nil,
                 cache_dir: nil,
                 tags_file: './tags.txt', credentials_file: nil,
                 blacklist_file: './blacklist.txt', dry_run: false,
                 thread_count: 2, rate_limit: 1, verbose: false,
                 interrupted: false, rate_limiter: nil, notify_url: nil,
                 recache_post_tags: false)
    @username = username
    @api_key = api_key
    @user_id = user_id
    @output_dir = output_dir || default_output_dir
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
    @recache_post_tags = recache_post_tags
  end

  def ensure_rate_limiter
    @rate_limiter ||= RateLimiter.new(requests_per_second: @rate_limit)
  end

  def blacklist
    @blacklist ||= Blacklist.new(@blacklist_file)
  end

  def default_output_dir
    raise NotImplementedError
  end

  def site_name
    raise NotImplementedError
  end

  def run
    @username, @api_key, @user_id = load_credentials
    validate_credentials

    unless @dry_run
      FileUtils.mkdir_p(@output_dir) unless Dir.exist?(@output_dir)
    end

    ensure_rate_limiter
    blacklist
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

    log_info "#{site_name} Archiver starting..."
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

    if @recache_post_tags
      log_info "Recache mode — refreshing tag cache for all existing posts"
      recache_all_post_tags(processor, stats)
    else
      unless File.exist?(@tags_file)
        log_error "Cannot open tags file", tags_file: @tags_file
        exit 1
      end

    if @dry_run
      log_info "Dry run mode — discovering posts that would be archived"
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
      logger.info "DRY RUN — preview mode", dry_run: true
    end
    logger.info "Throttled requests (API + downloads): #{total_requests}", request_count: total_requests
    logger.info "Time elapsed: #{format('%.2f', elapsed)}s", elapsed_seconds: elapsed.round(2)
    if requests_per_sec
      logger.info "Requests per second: #{format('%.2f', requests_per_sec)}", requests_per_sec: requests_per_sec.round(2)
    end
    logger.separator

    report = {
      event: "rubichiver.#{site_name}.run-complete",
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

  def load_credentials_from_file
    raise NotImplementedError
  end

  def load_credentials
    unless File.exist?(@credentials_file)
      return [@username, @api_key, @user_id]
    end
    load_credentials_from_file
  end

  def validate_credentials
    missing = []
    if site_name == 'gelbooru'
      missing << 'API_KEY' if @api_key.nil?
      missing << 'USER_ID' if @user_id.nil?
    else
      missing << 'USERNAME' if @username.nil?
      missing << 'API_KEY' if @api_key.nil?
    end
    if missing.any?
      if File.exist?(@credentials_file)
        log_fatal "Incomplete API credentials (missing: #{missing.join(', ')})", credentials_file: @credentials_file
      else
        log_fatal "API credentials file not found", credentials_file: @credentials_file
      end
      exit 1
    end
  end

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
      posts.each do |post|
        save_tag_cache(post)
        processor.enqueue(post)
      end
    end
  end

  def recache_all_post_tags(processor, stats)
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

    log_info "Found #{post_ids.size} unique posts to recache"

    ids = post_ids.to_a
    total_batches = (ids.size.to_f / BATCH_SIZE).ceil

    ids.each_slice(BATCH_SIZE).with_index do |id_batch, idx|
      break if @interrupted

      log_info "Recache batch #{idx + 1}/#{total_batches} (#{id_batch.size} IDs)", batch: idx + 1, total_batches: total_batches, api: true
      result = api_search_posts(["id:#{id_batch.join(',')}"], 1, force: true)
      posts = result
      if result.is_a?(Array) && result.size == 2 && (result.last.is_a?(Integer) || result.last.nil?)
        posts = result.first
      end
      next unless posts

      posts.each do |post|
        break if @interrupted
        save_tag_cache(post)
      end
    end

    log_info "Recache complete for #{post_ids.size} posts"
  end

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

  def post_file_url(post)
    raise NotImplementedError
  end

  def post_file_ext(post)
    raise NotImplementedError
  end

  def post_md5(post)
    raise NotImplementedError
  end

  def resolve_served_extension(post, orig_ext, file_url)
    orig_ext
  end

  def api_search_posts(tags, page, force: false)
    raise NotImplementedError
  end

  def fetch_all_posts_for_query(query_tags, seen_ids, stats)
    raise NotImplementedError
  end

  def download_media(url, output_file, post_id, expected_md5, thread_idx: nil)
    raise NotImplementedError
  end

  def tag_cache_path(post_id)
    File.join(@cache_dir, "tags_#{post_id}.json")
  end

  def save_tag_cache(post)
    FileUtils.mkdir_p(@cache_dir)
    post_id = post['id']
    tags = extract_post_tags(post)
    rating = post['rating']
    data = { 'id' => post_id, 'rating' => rating, 'tags' => tags }
    File.write(tag_cache_path(post_id), JSON.generate(data))
  end

  def load_tag_cache(post_id)
    path = tag_cache_path(post_id)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue
    nil
  end

  def sidecar_valid?(post)
    post_id = post['id']
    sidecar = File.join(@output_dir, "#{post_id}.xmp")
    return false unless File.exist?(sidecar)

    rlabel = rating_label(post)
    return false unless rlabel
    expected_rating = rating_value(post['rating'])

    cached = load_tag_cache(post_id)
    expected_tags = if cached
                      cached['tags']
                    else
                      extract_post_tags(post)
                    end

    stdout, _stderr, status = Open3.capture3('exiftool', '-json', '-XMP:Rating', '-xmp-dc:subject', sidecar)
    return false unless status.success?

    data = JSON.parse(stdout) rescue nil
    data = data.first if data.is_a?(Array)
    return false unless data.is_a?(Hash)

    return false unless data['Rating'].to_s == expected_rating.to_s

    subjects = data['Subject']
    subjects = [subjects] if subjects.is_a?(String)
    return false unless subjects.is_a?(Array)

    expected = ["rating:#{rlabel}"] + expected_tags
    expected.all? { |kw| subjects.include?(kw) }
  end

  def write_sidecar(media_file, post)
    post_id = post['id']
    sidecar = File.join(@output_dir, "#{post_id}.xmp")

    rlabel = rating_label(post)
    return :skipped unless rlabel

    rvalue = rating_value(post['rating'])

    save_tag_cache(post)

    tmp_sidecar = "#{sidecar}.#{Process.pid}.write.xmp"
    File.delete(tmp_sidecar) if File.exist?(tmp_sidecar)

    args = ['-o', tmp_sidecar]
    args << "-XMP:Rating=#{rvalue}"
    args << "-xmp-dc:subject+=rating:#{rlabel}"

    extract_post_tags(post).each do |tag|
      args << "-xmp-dc:subject+=#{tag}"
    end

    args << media_file

    _stdout, stderr, status = Open3.capture3('exiftool', *args)

    if status.success? && File.exist?(tmp_sidecar)
      File.rename(tmp_sidecar, sidecar)
      true
    else
      File.delete(tmp_sidecar) if File.exist?(tmp_sidecar)
      log_error "exiftool sidecar write failed: #{stderr}", sidecar: sidecar, post_id: post_id, stderr: stderr
      false
    end
  end

  def extract_post_tags(post)
    raise NotImplementedError
  end

  def rating_value(rating)
    raise NotImplementedError
  end

  def rating_label(post)
    raise NotImplementedError
  end
end

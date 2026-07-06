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

# Rating mapping for XMP (XMP:Rating uses numeric 1-5)
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

# Global state
$verbose = false

# Parse command line options
options = {
  output: './e6archive',
  tags: './tags.txt',
  credentials: './api_credentials.txt',
  blacklist: './blacklist.txt',
  dry_run: false,
  verbose: false,
  json: false,
  threads: 12,
  rate_limit: 24
}

OptionParser.new do |opts|
  opts.banner = <<~USAGE
    Usage: rubichiver-e621.rb [OPTIONS]

    Options:
      -o, --output DIR      Output directory (default: ./e6archive)
      -t, --tags FILE       Tags file (default: ./tags.txt)
      -c, --credentials FILE  API credentials file (default: ./api_credentials.txt)
      --dry-run             Show what would be done without downloading
      -v, --verbose         Verbose output
      --json                JSON log output (machine-parseable)
      -h, --help            Show this help message

    The tool will:
      1. Read tags from the tags file (whitespace-separated tags per line)
      2. For each line, fetch matching posts from the e621 API (paginated, 320 per page)
      3. Filter posts against a blacklist file (e621 blacklist syntax)
      4. Download media files (images/videos)
      5. Write XMP sidecar files with IPTC:Keywords (tags by category + rating)
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
  opts.on('-h', '--help', 'Show this help message') do
    puts opts
    exit 0
  end
end.parse!

output_dir = options[:output]
tags_file = options[:tags]
credentials_file = options[:credentials]
blacklist_file = options[:blacklist]
dry_run = options[:dry_run]
$verbose = options[:verbose]

# Configure logger
E621Archiver::Logger.configure(
  level: $verbose ? :debug : :info,
  format: options[:json] ? :json : :human
)

# Load API credentials
def load_credentials(file)
  return [nil, nil] unless File.exist?(file)

  username = nil
  api_key = nil

  File.foreach(file) do |line|
    line = line.strip
    if line.start_with?('USERNAME=')
      username = line.split('=', 2).last
    elsif line.start_with?('API_KEY=')
      api_key = line.split('=', 2).last
    end
  end

  [username, api_key]
end

$username, $api_key = load_credentials(credentials_file)
unless $username && $api_key
  log_fatal "Failed to load API credentials", credentials_file: credentials_file
  exit 1
end

# Store config in globals for main()
$output_dir = output_dir
$tags_file = tags_file
$dry_run = dry_run
$thread_count = options[:threads]
$blacklist_file = blacklist_file

# Create output directory
unless dry_run
  FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)
end

# Initialize thread-safe rate limiter (shared across all threads)
$rate_limiter = RateLimiter.new(requests_per_second: options[:rate_limit])

# Initialize blacklist
$blacklist = Blacklist.new($blacklist_file)

# Build post_id -> file_path map from existing files in output directory
$existing_posts = {}
if Dir.exist?(output_dir)
  Dir.children(output_dir).each do |file|
    next if file.start_with?('.')
    next if file.end_with?('.xmp')
    full = File.join(output_dir, file)
    next unless File.file?(full)
    if file =~ /\A(\d+)\./
      $existing_posts[$1.to_i] = full
    end
  end
  log_info "Found #{$existing_posts.size} existing files in output directory"
end

# Signal handling for graceful shutdown
$interrupted = false

trap('INT') do
  if $interrupted
    log_warn "Force exiting..."
    trap('INT', 'DEFAULT')
    Process.kill('INT', Process.pid)
  else
    $interrupted = true
    log_warn "Interrupt received, finishing in-progress work... (press Ctrl+C again to force exit)"
  end
end

trap('TERM') do
  if $interrupted
    log_warn "Force exiting..."
    trap('TERM', 'DEFAULT')
    Process.kill('TERM', Process.pid)
  else
    $interrupted = true
    log_warn "Terminate received, finishing in-progress work... (send again to force exit)"
  end
end

# Fetch a single page of posts from the e621 API, with file-based caching
def api_search_posts(username, api_key, tags, page)
  cache_dir = File.join($output_dir, 'cache')
  FileUtils.mkdir_p(cache_dir)
  query_hash = Digest::SHA256.hexdigest("v2:" + tags.join(' '))
  cache_path = File.join(cache_dir, "api_posts_#{query_hash}_p#{page}.json")

  if File.exist?(cache_path)
    data = JSON.parse(File.read(cache_path))
    log_debug "Using cached API response for: #{tags.join(' ')} (page #{page}, #{data&.size || 0} posts)"
    return data
  end

  $rate_limiter.throttle!
  uri = URI("#{API_BASE}/posts.json")
  uri.query = URI.encode_www_form(tags: tags.join(' '), page: page, limit: 320, v2: true, mode: 'extended')

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 30
  http.read_timeout = 60
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = "rubichiver-e621/1.0 (used by #{username} on e621)"
  request['Accept-Encoding'] = 'identity'

  response = http.request(request)
  unless response.is_a?(Net::HTTPSuccess)
    log_error "API search failed", tags: tags.join(' '), page: page, status: response.code
    return nil
  end

  posts = JSON.parse(response.body)
  posts = [] unless posts.is_a?(Array)
  File.write(cache_path, JSON.pretty_generate(posts))
  log_debug "Cached API response: #{tags.join(' ')} (page #{page}, #{posts.size} posts)"
  posts
rescue JSON::ParserError, Zlib::BufError => e
  log_error "Failed to parse API response", error: e.message
  nil
end

# Fetch all pages of posts for a single tag query from the API
def fetch_all_posts_for_query(username, api_key, query_tags, seen_ids, stats)
  query_str = query_tags.join(' ')
  log_info "Fetching posts for: #{query_str}", query: query_str

  all_posts = []
  page = 1

  loop do
    posts = api_search_posts(username, api_key, query_tags, page)
    break unless posts

    break if posts.empty?

    posts.each do |post|
      next if seen_ids.include?(post['id'])

      post_tags = post['tags'] || {}
      tag_set = post_tags.values.flatten
      rating = post['rating']
      post_id = post['id']

      if $blacklist&.any? && $blacklist.blacklisted?(tag_set, rating, post_id)
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

# Process all tag queries from the tags file via API
def process_tag_queries(tags_file, processor, stats)
  queries = []
  File.foreach(tags_file) do |line|
    line = line.chomp
    next if line.strip.empty?
    queries << line.split
  end

  if queries.empty?
    log_warn "No tag queries found in tags file", tags_file: tags_file
    return
  end

  seen_ids = Set.new
  queries.each do |query_tags|
    break if $interrupted
    posts = fetch_all_posts_for_query($username, $api_key, query_tags, seen_ids, stats)
    posts.each { |post| processor.enqueue(post) }
  end
end

# Download media file with retries
def download_media(url, output_file, post_id, expected_md5, thread_idx: nil)
  retries = 0

  while retries < MAX_RETRIES
    break if $interrupted

    $rate_limiter.throttle!

    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 30
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)
    request['User-Agent'] = "rubichiver-e621/1.0"
    request['Accept-Encoding'] = 'identity'

    begin
      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        File.open(output_file, 'wb') { |f| f.write(response.body) }
        if verify_md5(output_file, expected_md5)
          return true
        else
          log_error "MD5 mismatch for post #{post_id}", post_id: post_id, thread: thread_idx
          File.delete(output_file) if File.exist?(output_file)
        end
      end
    rescue Zlib::BufError => e
      log_debug "Download corrupted, retrying...", post_id: post_id, error: e.message, thread: thread_idx
    end

    retries += 1
    if retries < MAX_RETRIES
      delay = RETRY_BACKOFF * (2 ** retries) + rand * 0.5
      log_debug "Retrying in #{format('%.1f', delay)}s...", post_id: post_id, retry_count: retries
      sleep(delay)
      break if $interrupted
    end
  end

  false
end

# Verify MD5 hash of file
def verify_md5(file, expected)
  return false unless File.exist?(file)

  Digest::MD5.file(file).hexdigest == expected
end

# Check if a post already has an XMP sidecar
def sidecar_exists?(post_id)
  File.exist?(File.join($output_dir, "#{post_id}.xmp"))
end

# Write XMP sidecar file with IPTC:Keywords and XMP:Rating tags
def write_sidecar(media_file, post)
  post_id = post['id']
  sidecar = File.join($output_dir, "#{post_id}.xmp")

  rating_label = RATING_LABELS[post['rating']]
  return false unless rating_label

  rating_value = RATING_MAP[post['rating']]

  File.delete(sidecar) if File.exist?(sidecar)

  args = ['-o', sidecar]
  args << "-XMP:Rating=#{rating_value}"
  args << "-IPTC:Keywords+=rating:#{rating_label}"

  TAG_CATEGORIES.each do |category|
    tags = post.dig('tags', category) || []
    tags.each do |tag|
      args << "-IPTC:Keywords+=#{category}:#{tag}"
    end
  end

  args << media_file

  stdout, stderr, status = Open3.capture3('exiftool', *args)

  if status.success? && File.exist?(sidecar)
    true
  else
    log_error "exiftool sidecar write failed: #{stderr}", sidecar: sidecar, post_id: post_id, stderr: stderr
    false
  end
end





# Main execution
def main
  log_info "e621 Archiver starting..."
    log_info "Output directory: #{$output_dir}", output_dir: $output_dir
    log_info "Tags file: #{$tags_file}", tags_file: $tags_file
    log_info "API username: #{$username}", username: $username
    log_info "Max retries: #{MAX_RETRIES}", max_retries: MAX_RETRIES
    log_info "Worker threads: #{$thread_count}", threads: $thread_count
    if $blacklist&.any?
      log_info "Blacklist: #{$blacklist_file}", blacklist: $blacklist_file
    end
    log_info ""

    start_time = Time.now

    unless File.exist?($tags_file)
      log_error "Cannot open tags file", tags_file: $tags_file
      exit 1
    end

    stats = Stats.new
    processor = PostProcessor.new(
      rate_limiter: $rate_limiter,
      output_dir: $output_dir,
      stats: stats,
      thread_count: $thread_count
    )

    if $dry_run
      log_info "Dry run mode — would fetch and process posts"
      exit 0
    end

    process_tag_queries($tags_file, processor, stats)

    processor.finish
    processor.wait

    if $interrupted
      log_warn "Interrupted — partial results below"
    end

  end_time = Time.now
  elapsed = end_time - start_time
  total_requests = $rate_limiter.request_count
  requests_per_sec = total_requests / elapsed if elapsed.positive?

  logger.separator
  logger.info 'SUMMARY'
  logger.separator
  logger.info "Total posts processed: #{stats.total_posts}", total_posts: stats.total_posts
  logger.info "Files downloaded: #{stats.downloaded_files}", downloaded: stats.downloaded_files
  logger.info "Files skipped (already exist): #{stats.skipped_files}", skipped: stats.skipped_files
  logger.info "Files failed: #{stats.failed_files}", failed: stats.failed_files
  if stats.blacklisted_files > 0
    logger.info "Files blacklisted: #{stats.blacklisted_files}", blacklisted: stats.blacklisted_files
  end
  logger.info "API requests made: #{total_requests}", request_count: total_requests
  logger.info "Time elapsed: #{format('%.2f', elapsed)}s", elapsed_seconds: elapsed.round(2)
  if requests_per_sec
    logger.info "Requests per second: #{format('%.2f', requests_per_sec)}", requests_per_sec: requests_per_sec.round(2)
  end
  logger.separator

  exit 0
end

main()

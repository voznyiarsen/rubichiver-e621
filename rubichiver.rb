#!/usr/bin/env ruby
# frozen_string_literal: true

# rubichiver - Unified Media Archiver
# Downloads media from booru sites and writes XMP sidecar metadata.
# Supports e621.net and Gelbooru via --site flag.

require 'optparse'
require_relative 'logger'
require_relative 'rate_limiter'
require_relative 'post_processor'
require_relative 'blacklist'
require_relative 'archiver_base'
require_relative 'archiver_e621'
require_relative 'archiver_gelbooru'

if __FILE__ == $PROGRAM_NAME
  site = nil
  remaining = []
  iter = ARGV.each
  begin
    loop do
      arg = iter.next
      case arg
      when '-s', '--site'
        site = iter.next
      when /\A--site=(.+)\z/
        site = $1
      else
        remaining << arg
      end
    end
  rescue StopIteration
  end

  unless site
    puts "Usage: ruby rubichiver.rb --site e621|gelbooru [OPTIONS]"
    puts ""
    puts "  -s, --site SITE              Target site (e621 or gelbooru)"
    puts "  -o, --output DIR             Output directory"
    puts "  -t, --tags FILE              Tags file (default: ./tags.txt)"
    puts "  -c, --credentials FILE       API credentials file"
    puts "      --dry-run                Preview posts that would be archived"
    puts "  -v, --verbose                Verbose output"
    puts "      --json                   JSON log output (machine-parseable)"
    puts "  -j, --threads N              Number of worker threads (default: 2)"
    puts "      --rate-limit N           API requests per second (default: 1)"
    puts "  -b, --blacklist FILE         Blacklist file (e621 syntax, default: ./blacklist.txt)"
    puts "      --notify URL             POST a JSON run report to URL on completion"
    puts "      --recache-post-tags      Refresh local tag cache for all existing posts from API"
    puts "  -C, --cache-dir DIR          Cache directory for API responses (default: $output_dir/cache)"
    puts "  -h, --help                   Show this help message"
    exit 0
  end

  unless %w[e621 gelbooru].include?(site)
    puts "Error: --site must be 'e621' or 'gelbooru', got '#{site}'"
    exit 1
  end

  options = {
    output: nil,
    tags: './tags.txt',
    credentials: nil,
    blacklist: './blacklist.txt',
    dry_run: false,
    verbose: false,
    json: false,
    threads: 2,
    rate_limit: 1
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby rubichiver.rb --site #{site} [OPTIONS]"

    opts.separator ""
    opts.separator "Options for #{site}:"

    opts.on('-o', '--output DIR', 'Output directory') { |v| options[:output] = v }
    opts.on('-t', '--tags FILE', 'Tags file (default: ./tags.txt)') { |v| options[:tags] = v }
    opts.on('-c', '--credentials FILE', "API credentials file (default: ./e621-api-credentials.txt for e621, ./gelbooru-api-credentials.txt for gelbooru)") { |v| options[:credentials] = v }
    opts.on('--dry-run', 'Preview posts that would be archived') { options[:dry_run] = true }
    opts.on('-v', '--verbose', 'Verbose output') { options[:verbose] = true }
    opts.on('--json', 'JSON log output (machine-parseable)') { options[:json] = true }
    opts.on('-j', '--threads N', Integer, 'Number of worker threads (default: 2)') { |v| options[:threads] = v }
    opts.on('--rate-limit N', Float, 'API requests per second (default: 1)') { |v| options[:rate_limit] = v }
    opts.on('-b', '--blacklist FILE', 'Blacklist file (e621 syntax, default: ./blacklist.txt)') { |v| options[:blacklist] = v }
    opts.on('--notify URL', 'POST a JSON run report to URL on completion (e.g. ntfy/Slack/Discord webhook)') { |v| options[:notify] = v }
    opts.on('--recache-post-tags', 'Refresh local tag cache for all existing posts from API') { options[:recache_post_tags] = true }
    opts.on('-C', '--cache-dir DIR', 'Cache directory for API responses (default: $output_dir/cache)') { |v| options[:cache_dir] = v }

    opts.on('-h', '--help', 'Show this help message') do
      puts opts
      exit 0
    end
  end

  parser.parse!(remaining)

  unless options[:credentials]
    options[:credentials] = site == 'gelbooru' ? './gelbooru-api-credentials.txt' : './e621-api-credentials.txt'
  end

  Rubichiver::Logger.configure(
    level: options[:verbose] ? :debug : :info,
    format: options[:json] ? :json : :human
  )

  archiver = case site
  when 'e621'
    E621Archiver.new(
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
      recache_post_tags: options[:recache_post_tags]
    )
  when 'gelbooru'
    GelbooruArchiver.new(
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
      recache_post_tags: options[:recache_post_tags]
    )
  end

  archiver.install_signal_handlers
  archiver.run
end

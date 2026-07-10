# frozen_string_literal: true

require 'uri'
require 'open3'

class Stats
  attr_reader :total_posts, :downloaded_files, :autotagged_files, :skipped_files, :failed_files, :blacklisted_files

  def initialize
    @mutex = Mutex.new
    @total_posts = 0
    @downloaded_files = 0
    @autotagged_files = 0
    @skipped_files = 0
    @failed_files = 0
    @blacklisted_files = 0
  end

  def increment(stat)
    @mutex.synchronize do
      case stat
      when :total_posts then @total_posts += 1
      when :downloaded_files then @downloaded_files += 1
      when :autotagged_files then @autotagged_files += 1
      when :skipped_files then @skipped_files += 1
      when :failed_files then @failed_files += 1
      when :blacklisted_files then @blacklisted_files += 1
      end
    end
  end
end

UNSUPPORTED_EXTENSIONS = %w[swf].freeze

class PostProcessor
  def initialize(rate_limiter:, output_dir:, stats:, thread_count: 4, dry_run: false, archiver: nil)
    @queue = Queue.new
    @rate_limiter = rate_limiter
    @output_dir = output_dir
    @stats = stats
    @dry_run = dry_run
    @archiver = archiver
    @workers = []
    @interrupt_skipped = 0
    @interrupt_mutex = Mutex.new

    thread_count.times do |i|
      @workers << Thread.new { worker_loop(i) }
    end
  end

  def enqueue(post)
    @queue << post
  end

  def finish
    @workers.size.times { @queue << :done }
  end

  def wait
    @workers.each(&:join)
    log_info "Skipped #{@interrupt_skipped} posts due to interrupt" if @interrupt_skipped > 0
  end

  private

  def worker_loop(idx)
    loop do
      post = @queue.pop
      break if post == :done
      process_post(post, idx)
    rescue => e
      log_error "Worker thread error: #{e.message}", thread: idx, error: e.message
    end
  end

  def process_post(post, thread_idx)
    post_id = post['id']
    file_url = @archiver.post_file_url(post)
    file_ext = @archiver.post_file_ext(post)
    md5 = @archiver.post_md5(post)

    log_info "Thread #{thread_idx}: Processing post #{post_id}", post_id: post_id, thread: thread_idx

    if @archiver.interrupted
      @interrupt_mutex.synchronize { @interrupt_skipped += 1 }
      @stats.increment(:skipped_files)
      return
    end

    unless file_url
      log_debug "Thread #{thread_idx}: Post #{post_id} has no file URL, skipping", thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    served_ext = @archiver.resolve_served_extension(post, file_ext, file_url)

    if UNSUPPORTED_EXTENSIONS.include?(served_ext.downcase)
      log_info "Thread #{thread_idx}: Skipping post #{post_id} (unsupported format: #{served_ext})", thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    if served_ext != file_ext
      md5 = nil
    end

    if @dry_run
      log_info "Thread #{thread_idx}: Would archive post #{post_id} (#{served_ext})", post_id: post_id, url: file_url, thread: thread_idx
      return
    end

    existing_file = @archiver.existing_posts[post_id]
    if existing_file
      unless @archiver.sidecar_valid?(post)
        log_info "Thread #{thread_idx}: Post #{post_id} sidecar missing or invalid, regenerating", post_id: post_id, thread: thread_idx
        result = @archiver.write_sidecar(existing_file, post)
        if result == :skipped
          log_info "Thread #{thread_idx}: Post #{post_id} sidecar skipped (no rating)", post_id: post_id, thread: thread_idx
          @stats.increment(:skipped_files)
        elsif result
          log_info "Thread #{thread_idx}: Post #{post_id} sidecar regenerated successfully", post_id: post_id, thread: thread_idx
          @stats.increment(:autotagged_files)
        else
          log_error "Thread #{thread_idx}: Post #{post_id} sidecar regeneration failed", post_id: post_id, thread: thread_idx
          @stats.increment(:failed_files)
        end
        return
      end

      log_info "Thread #{thread_idx}: Post #{post_id} sidecar valid, skipping", post_id: post_id, thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    output_file = File.join(@output_dir, "#{post_id}.#{served_ext}")

    success = @archiver.download_media(file_url, output_file, post_id, md5, thread_idx: thread_idx)

    if success
      log_info "Thread #{thread_idx}: Writing XMP sidecar for post #{post_id}", post_id: post_id, thread: thread_idx
      result = @archiver.write_sidecar(output_file, post)
      if result == :skipped
        log_info "Thread #{thread_idx}: Post #{post_id} sidecar write skipped (no rating)", post_id: post_id, thread: thread_idx
        @stats.increment(:skipped_files)
      elsif result
        log_info "Thread #{thread_idx}: Post #{post_id} archived successfully", post_id: post_id, thread: thread_idx
        @stats.increment(:downloaded_files)
      else
        log_error "Thread #{thread_idx}: Post #{post_id} sidecar write failed", post_id: post_id, thread: thread_idx
        @stats.increment(:failed_files)
      end
    else
      log_error "Thread #{thread_idx}: Post #{post_id} download failed", post_id: post_id, thread: thread_idx
      @stats.increment(:failed_files)
    end
  end
end

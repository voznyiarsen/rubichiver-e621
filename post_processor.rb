# frozen_string_literal: true

# Thread-safe statistics counters
class Stats
  attr_reader :total_posts, :downloaded_files, :skipped_files, :failed_files, :blacklisted_files

  def initialize
    @mutex = Mutex.new
    @total_posts = 0
    @downloaded_files = 0
    @skipped_files = 0
    @failed_files = 0
    @blacklisted_files = 0
  end

  def increment(stat)
    @mutex.synchronize do
      case stat
      when :total_posts then @total_posts += 1
      when :downloaded_files then @downloaded_files += 1
      when :skipped_files then @skipped_files += 1
      when :failed_files then @failed_files += 1
      when :blacklisted_files then @blacklisted_files += 1
      end
    end
  end
end

# Thread pool for processing posts (download, transcode, tag)
class PostProcessor
  def initialize(rate_limiter:, output_dir:, stats:, thread_count: 4)
    @queue = Queue.new
    @rate_limiter = rate_limiter
    @output_dir = output_dir
    @stats = stats
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
    file_ext = post.dig('file', 'ext') || 'unknown'
    file_url = post.dig('file', 'url')
    md5 = post.dig('file', 'md5')

    if $interrupted
      @interrupt_mutex.synchronize { @interrupt_skipped += 1 }
      @stats.increment(:skipped_files)
      return
    end

    unless file_url
      log_debug "Post #{post_id}: No file URL, skipping", thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    if UNSUPPORTED_EXTENSIONS.include?(file_ext.downcase)
      log_info "Post #{post_id}: Skipping unsupported format (#{file_ext})", thread: thread_idx
      @stats.increment(:skipped_files)
      return
    end

    existing_file = $existing_posts[post_id]
    if existing_file
      existing_ext = File.extname(existing_file).delete('.').downcase

      if VIDEO_EXTENSIONS.include?(existing_ext) && existing_ext != 'mp4'
        log_info "Post #{post_id}: Found untagged video, transcoding to MP4", post_id: post_id, thread: thread_idx
        mp4_file = File.join(@output_dir, "#{post_id}.mp4")
        transcode_success = transcode_video(existing_file, mp4_file)
        if transcode_success
          existing_file = mp4_file
        else
          log_error "Post #{post_id}: Transcoding failed", post_id: post_id, thread: thread_idx
          @stats.increment(:failed_files)
          return
        end
      elsif file_has_xmp?(existing_file)
        log_debug "Post #{post_id}: Already exists and tagged (Post ID: #{post_id})", post_id: post_id, thread: thread_idx
        @stats.increment(:skipped_files)
        return
      end

      log_info "Post #{post_id}: Adding XMP metadata", post_id: post_id, thread: thread_idx
      if add_xmp_tags(existing_file, post)
        log_info "Post #{post_id}: Successfully archived (auto-tagged)", post_id: post_id, thread: thread_idx
        @stats.increment(:downloaded_files)
        return
      end

      log_warn "Post #{post_id}: Corrupt file, removing and re-downloading", post_id: post_id, thread: thread_idx
      File.delete(existing_file) if File.exist?(existing_file)
      $existing_posts.delete(post_id)
    end

    output_file = File.join(@output_dir, "#{post_id}.#{file_ext}")

    success = download_media(file_url, output_file, post_id, md5, thread_idx: thread_idx)

    if success
      if VIDEO_EXTENSIONS.include?(file_ext.downcase)
        log_info "Post #{post_id}: Converting to MP4", post_id: post_id, thread: thread_idx
        mp4_file = File.join(@output_dir, "#{post_id}.mp4")
        transcode_success = transcode_video(output_file, mp4_file)

        if transcode_success
          File.delete(output_file) if File.exist?(output_file)
          output_file = mp4_file
          file_ext = 'mp4'
        else
          log_error "Post #{post_id}: Transcoding failed", post_id: post_id, thread: thread_idx
          @stats.increment(:failed_files)
          return
        end
      end

      log_info "Post #{post_id}: Adding XMP metadata", post_id: post_id, thread: thread_idx
      tag_success = add_xmp_tags(output_file, post)

      if tag_success
        log_info "Post #{post_id}: Successfully archived", post_id: post_id, thread: thread_idx
        @stats.increment(:downloaded_files)
      else
        log_error "Post #{post_id}: Failed to add XMP tags", post_id: post_id, thread: thread_idx
        @stats.increment(:failed_files)
      end
    else
      log_error "Post #{post_id}: Download failed", post_id: post_id, thread: thread_idx
      @stats.increment(:failed_files)
    end
  end
end

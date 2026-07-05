#!/usr/bin/env ruby
# frozen_string_literal: true

# Canonical Logger for e621archiver
# Provides structured, leveled logging with consistent formatting
# and optional JSON output for machine parsing.

require 'time'
require 'json'

module E621Archiver
  module Logger
    LEVELS = {
      debug: 0,
      info: 1,
      warn: 2,
      error: 3,
      fatal: 4
    }.freeze

    DEFAULT_LEVEL = :info

    COLORS = {
      debug: "\e[36m",
      info:  "\e[32m",
      warn:  "\e[33m",
      error: "\e[31m",
      fatal: "\e[35m",
      reset: "\e[0m"
    }.freeze

    PREFIXES = {
      debug: 'DEBUG',
      info:  'INFO',
      warn:  'WARN',
      error: 'ERROR',
      fatal: 'FATAL'
    }.freeze

    class << self
      attr_accessor :level, :output, :use_colors, :include_timestamp, :include_context, :format

      def configure(level: nil, output: $stdout, colors: nil, timestamp: true, context: true, format: :human)
        self.level = level || resolve_level
        self.output = output
        self.use_colors = colors.nil? ? output.tty? : colors
        self.include_timestamp = timestamp
        self.include_context = context
        self.format = format
      end

      def resolve_level
        return $log_level if defined?($log_level) && $log_level
        return ENV['LOG_LEVEL'].downcase.to_sym if ENV['LOG_LEVEL'] && LEVELS.key?(ENV['LOG_LEVEL'].downcase.to_sym)
        DEFAULT_LEVEL
      end

      def level=(lvl)
        @level = LEVELS.key?(lvl) ? lvl : DEFAULT_LEVEL
      end

      def log(level, message, context = {})
        return unless enabled?(level)

        if format == :json
          entry = {
            timestamp: Time.now.utc.iso8601(3),
            level: level.to_s.upcase,
            message: message
          }.merge(context)

          output.puts(JSON.generate(entry))
        else
          formatted = format_message(level, message, context)
          output.puts(formatted)
        end

        output.flush
      end

      def enabled?(level)
        LEVELS[level] >= LEVELS[@level]
      end

      def debug(msg, ctx = {})  log(:debug, msg, ctx)  end
      def info(msg, ctx = {})   log(:info, msg, ctx)   end
      def warn(msg, ctx = {})   log(:warn, msg, ctx)   end
      def error(msg, ctx = {})  log(:error, msg, ctx)  end
      def fatal(msg, ctx = {})  log(:fatal, msg, ctx)  end

      def separator(char: '=', length: 50)
        log(:info, char * length) if enabled?(:info)
      end

      private

      def format_message(level, message, context)
        parts = []

        if include_timestamp
          parts << "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N')}]"
        end

        level_str = PREFIXES[level]
        if use_colors
          parts << "#{COLORS[level]}#{level_str.ljust(5)}#{COLORS[:reset]}"
        else
          parts << level_str.ljust(5)
        end

        if include_context && !context.empty?
          ctx_str = context.map { |k, v| "#{k}=#{format_value(v)}" }.join(' ')
          parts << "[#{ctx_str}]"
        end

        parts << message

        parts.join(' ')
      end

      def format_value(value)
        case value
        when String
          value.include?(' ') ? "\"#{value}\"" : value
        when Array
          "[#{value.map { |v| format_value(v) }.join(', ')}]"
        when Hash
          "{#{value.map { |k, v| "#{k}=#{format_value(v)}" }.join(', ')}}"
        else
          value.to_s
        end
      end
    end

    configure
  end
end

def logger
  E621Archiver::Logger
end

def log_debug(msg, ctx = {})  logger.debug(msg, ctx)  end
def log_info(msg, ctx = {})   logger.info(msg, ctx)   end
def log_warn(msg, ctx = {})   logger.warn(msg, ctx)   end
def log_error(msg, ctx = {})  logger.error(msg, ctx)  end
def log_fatal(msg, ctx = {})  logger.fatal(msg, ctx)  end

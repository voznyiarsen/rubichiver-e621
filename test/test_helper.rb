# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('..', __dir__))

require 'logger'
require 'rate_limiter'
require 'post_processor'
require 'blacklist'
require 'archiver_base'
require 'archiver_e621'
require 'archiver_gelbooru'

require 'tmpdir'
require 'fileutils'

# Run all tests from a throwaway directory so the script's bootstrap side
# effects (creating ./e6archive, etc.) never touch the repo.
tmp = Dir.mktmpdir
at_exit { FileUtils.remove_entry(tmp) rescue nil }
Dir.chdir(tmp)

lib = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(lib)

require 'test/test_helper'
require 'blacklist'
require 'rate_limiter'
require 'logger'
require 'post_processor'
require 'rubichiver-e621'

require_relative 'blacklist_test'
require_relative 'rate_limiter_test'
require_relative 'download_test'
require_relative 'sidecar_test'
require_relative 'notify_test'

run_tests

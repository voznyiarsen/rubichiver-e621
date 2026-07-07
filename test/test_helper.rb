# Minimal stdlib-only test harness (no gems available in this environment).
$tests = []

def test(name, &block)
  $tests << [name, block]
end

def assert(cond, msg = 'assertion failed')
  raise "FAIL: #{msg}" unless cond
end

def assert_equal(expected, actual, msg = nil)
  return if expected == actual
  raise "FAIL: #{msg || 'assert_equal'}: expected #{expected.inspect}, got #{actual.inspect}"
end

def assert_raises(klass, msg = nil)
  yield
  raise "FAIL: #{msg || 'assert_raises'}: expected #{klass} but nothing was raised"
rescue => e
  raise "FAIL: expected #{klass} but got #{e.class}" unless e.is_a?(klass)
end

def run_tests
  passed = 0
  $tests.each do |name, block|
    begin
      block.call
      puts "PASS #{name}"
      passed += 1
    rescue => e
      puts "FAIL #{name}: #{e.message}"
    end
  end
  puts "#{passed}/#{$tests.size} passed"
  exit 1 if passed != $tests.size
end

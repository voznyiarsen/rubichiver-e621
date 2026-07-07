require 'tmpdir'

def make_blacklist(contents)
  path = File.join(Dir.pwd, "bl_#{rand(1_000_000)}.txt")
  File.write(path, contents)
  Blacklist.new(path)
end

test 'AND rule requires all tags present' do
  bl = make_blacklist("female fox nude\n")
  assert bl.blacklisted?(%w[female fox nude], 's', 1)
  assert !bl.blacklisted?(%w[female fox], 's', 1)
end

test 'OR group matches if any member present' do
  bl = make_blacklist("~wolf ~lion\n")
  assert bl.blacklisted?(%w[wolf], 's', 1)
  assert bl.blacklisted?(%w[lion], 's', 1)
  assert !bl.blacklisted?(%w[cat], 's', 1)
end

test 'negation excludes when forbidden tag present' do
  bl = make_blacklist("pokemon -pikachu\n")
  assert bl.blacklisted?(%w[pokemon], 's', 1)
  assert !bl.blacklisted?(%w[pokemon pikachu], 's', 1)
end

test 'rating rule matches by rating' do
  bl = make_blacklist("rating:e\n")
  assert bl.blacklisted?(%w[x], 'e', 1)
  assert !bl.blacklisted?(%w[x], 's', 1)
  assert !bl.blacklisted?(%w[x], 'questionable', 1)
end

test 'id rule matches a specific post' do
  bl = make_blacklist("id:42\n")
  assert bl.blacklisted?(%w[x], 's', 42)
  assert !bl.blacklisted?(%w[x], 's', 43)
end

test 'unsupported userid-only rule is ignored, not a catch-all' do
  bl = make_blacklist("userid:123\n")
  assert !bl.any?, 'unsupported-only rule should not be added'
  assert !bl.blacklisted?(%w[anything], 's', 999), 'must not blacklist everything'
end

test 'mixed rule keeps supported component' do
  bl = make_blacklist("gore userid:123\n")
  assert bl.blacklisted?(%w[gore], 's', 1)
  assert !bl.blacklisted?(%w[scat], 's', 1)
end

test 'comments and blank lines are ignored' do
  bl = make_blacklist("# comment\n\n  \ngore\n")
  assert bl.any?
  assert bl.blacklisted?(%w[gore], 's', 1)
end

test 'empty-rule is skipped (would otherwise blacklist all)' do
  bl = make_blacklist("uploader:55\n")
  assert !bl.any?
end

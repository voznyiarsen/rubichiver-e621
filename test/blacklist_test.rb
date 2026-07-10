# frozen_string_literal: true

require_relative 'test_helper'

class BlacklistTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_bl(path, body)
    File.write(path, body)
    Blacklist.new(path)
  end

  def test_empty_blacklist_is_inert
    bl = write_bl(File.join(@dir, 'b.txt'), "# just a comment\n\n")
    refute bl.any?
    refute bl.blacklisted?(%w[cat dog], 'safe', 1)
  end

  def test_required_tag_must_all_be_present
    bl = write_bl(File.join(@dir, 'b.txt'), "cat dog\n")
    assert bl.blacklisted?(%w[cat dog bird], 'safe', 1)
    refute bl.blacklisted?(%w[cat], 'safe', 1)
  end

  def test_forbidden_tag_excludes
    bl = write_bl(File.join(@dir, 'b.txt'), "-scat\n")
    assert bl.blacklisted?(%w[cat], 'safe', 1)
    refute bl.blacklisted?(%w[dog scat], 'safe', 1)
  end

  def test_optional_or_group
    bl = write_bl(File.join(@dir, 'b.txt'), "~cat ~dog\n")
    assert bl.blacklisted?(%w[cat], 'safe', 1)
    assert bl.blacklisted?(%w[dog], 'safe', 1)
    refute bl.blacklisted?(%w[bird], 'safe', 1)
  end

  def test_rating_rule_full_word
    bl = write_bl(File.join(@dir, 'b.txt'), "rating:explicit\n")
    assert bl.blacklisted?(%w[anything], 'explicit', 1)
    refute bl.blacklisted?(%w[anything], 'safe', 1)
  end

  def test_rating_rule_abbreviation
    bl = write_bl(File.join(@dir, 'b.txt'), "rating:e\n")
    assert bl.blacklisted?(%w[anything], 'explicit', 1)
    assert bl.blacklisted?(%w[anything], 'e', 1)
    refute bl.blacklisted?(%w[anything], 'safe', 1)
  end

  def test_id_rule
    bl = write_bl(File.join(@dir, 'b.txt'), "id:12345\n")
    assert bl.blacklisted?(%w[anything], 'safe', 12_345)
    refute bl.blacklisted?(%w[anything], 'safe', 999)
  end

  def test_combined_rule
    bl = write_bl(File.join(@dir, 'b.txt'), "artist:foo rating:explicit\n")
    assert bl.blacklisted?(%w[artist:foo bar], 'explicit', 1)
    refute bl.blacklisted?(%w[artist:foo bar], 'safe', 1)
    refute bl.blacklisted?(%w[bar], 'explicit', 1)
  end

  def test_sensitive_rating
    bl = write_bl(File.join(@dir, 'b.txt'), "rating:sensitive\n")
    assert bl.blacklisted?(%w[anything], 'sensitive', 1)
    refute bl.blacklisted?(%w[anything], 'safe', 1)
  end

  def test_bare_tags_in_filter
    bl = write_bl(File.join(@dir, 'b.txt'), "pokemon -pikachu\n")
    assert bl.blacklisted?(%w[pokemon], 's', 1)
    refute bl.blacklisted?(%w[pokemon pikachu], 's', 1)
  end

  def test_comments_and_blank_lines_are_ignored
    bl = write_bl(File.join(@dir, 'b.txt'), "# comment\n\n  \ngore\n")
    assert bl.any?
    assert bl.blacklisted?(%w[gore], 's', 1)
  end

  def test_unsupported_userid_rule_is_ignored
    bl = write_bl(File.join(@dir, 'b.txt'), "userid:123\n")
    refute bl.any?
    refute bl.blacklisted?(%w[anything], 's', 999)
  end

  def test_mixed_rule_keeps_supported_component
    bl = write_bl(File.join(@dir, 'b.txt'), "gore userid:123\n")
    assert bl.blacklisted?(%w[gore], 's', 1)
    refute bl.blacklisted?(%w[scat], 's', 1)
  end

  def test_empty_rule_is_skipped
    bl = write_bl(File.join(@dir, 'b.txt'), "uploader:55\n")
    refute bl.any?
  end
end

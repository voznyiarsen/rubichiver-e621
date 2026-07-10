# frozen_string_literal: true

require_relative 'test_helper'

class SidecarValidationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @archiver = E621Archiver.new(
      output_dir: @dir,
      username: 'tester',
      api_key: 'key'
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  POST = { 'id' => 123, 'rating' => 'e',
           'tags' => { 'general' => ['anthro'], 'artist' => ['bob'] } }.freeze

  def write_sidecar_file(path, body)
    File.write(path, body)
  end

  VALID_XMP = <<~XMP
    <?xpacket begin=' ' id='W5M0MpCehiHzreSzNTczkc9d'?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"><xmp:Rating>3</xmp:Rating></rdf:Description>
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:subject><rdf:Bag><rdf:li>rating:explicit</rdf:li><rdf:li>general:anthro</rdf:li><rdf:li>artist:bob</rdf:li></rdf:Bag></dc:subject></rdf:Description>
    </rdf:RDF></x:xmpmeta>
    <?xpacket end='w'?>
  XMP

  WRONG_RATING_XMP = VALID_XMP.sub('<xmp:Rating>3</xmp:Rating>', '<xmp:Rating>2</xmp:Rating>')

  def test_sidecar_valid_checks_exiftool
    write_sidecar_file(File.join(@dir, '123.xmp'), VALID_XMP)
    # Without exiftool, the validation will fail to parse
    result = @archiver.sidecar_valid?(POST)
    if system('exiftool -ver >/dev/null 2>&1')
      assert result
    else
      refute result
    end
  end

  def test_missing_sidecar_is_invalid
    File.delete(File.join(@dir, '123.xmp')) if File.exist?(File.join(@dir, '123.xmp'))
    refute @archiver.sidecar_valid?(POST)
  end

  def test_sidecar_with_wrong_rating_is_invalid
    write_sidecar_file(File.join(@dir, '123.xmp'), WRONG_RATING_XMP)
    if system('exiftool -ver >/dev/null 2>&1')
      refute @archiver.sidecar_valid?(POST)
    else
      refute @archiver.sidecar_valid?(POST)
    end
  end

  def test_malformed_sidecar_is_invalid
    write_sidecar_file(File.join(@dir, '123.xmp'), "this is not xmp at all \x00\x01")
    refute @archiver.sidecar_valid?(POST)
  end
end

class WriteSidecarTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_e621_write_sidecar_skips_unrated
    archiver = E621Archiver.new(output_dir: @dir, username: 'tester', api_key: 'key')
    result = archiver.write_sidecar(File.join(@dir, '1.jpg'),
                                    'id' => 1, 'rating' => nil, 'tags' => {})
    assert_equal :skipped, result
    refute File.exist?(File.join(@dir, '1.xmp'))
  end

  def test_gelbooru_write_sidecar_skips_unrated
    archiver = GelbooruArchiver.new(output_dir: @dir, api_key: 'key', user_id: '1')
    result = archiver.write_sidecar(File.join(@dir, '2.jpg'),
                                    'id' => 2, 'rating' => nil, 'tags' => '')
    assert_equal :skipped, result
    refute File.exist?(File.join(@dir, '2.xmp'))
  end
end

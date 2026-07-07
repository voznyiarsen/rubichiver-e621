require 'json'

# These tests exercise the real `exiftool` sidecar round-trip, so skip if it
# is not installed in the environment.
exiftool_available = system('exiftool -ver >/dev/null 2>&1')

unless exiftool_available
  test 'sidecar validation tests skipped (exiftool not installed)' do
    assert true
  end
  return
end

archiver = Archiver.new(output_dir: Dir.pwd, username: 'tester')

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
MISSING_TAG_XMP = VALID_XMP.sub('<rdf:li>artist:bob</rdf:li>', '')

test 'valid sidecar is recognized as valid' do
  write_sidecar_file(File.join(archiver.output_dir, '123.xmp'), VALID_XMP)
  assert archiver.sidecar_valid?(POST), 'well-formed sidecar with correct rating+tags should be valid'
end

test 'missing sidecar is invalid' do
  File.delete(File.join(archiver.output_dir, '123.xmp')) if File.exist?(File.join(archiver.output_dir, '123.xmp'))
  assert !archiver.sidecar_valid?(POST), 'absent sidecar should be invalid'
end

test 'malformed (garbage) sidecar is invalid' do
  write_sidecar_file(File.join(archiver.output_dir, '123.xmp'), "this is not xmp at all \x00\x01")
  assert !archiver.sidecar_valid?(POST), 'unparseable sidecar should be invalid'
end

test 'sidecar with wrong rating is invalid' do
  write_sidecar_file(File.join(archiver.output_dir, '123.xmp'), WRONG_RATING_XMP)
  assert !archiver.sidecar_valid?(POST), 'rating mismatch should be invalid'
end

test 'sidecar missing an expected tag is invalid' do
  write_sidecar_file(File.join(archiver.output_dir, '123.xmp'), MISSING_TAG_XMP)
  assert !archiver.sidecar_valid?(POST), 'missing keyword should be invalid'
end

test 'write_sidecar regenerates a valid sidecar (repair path)' do
  # Start from a corrupt sidecar; write_sidecar must replace it with a valid one.
  write_sidecar_file(File.join(archiver.output_dir, '123.xmp'), 'corrupt')
  media = File.join(archiver.output_dir, '123.png')
  File.write(media, 'fake-media-bytes')
  assert archiver.write_sidecar(media, POST), 'sidecar write should succeed'
  assert archiver.sidecar_valid?(POST), 'regenerated sidecar should validate'
end

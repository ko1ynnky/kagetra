# -*- coding: utf-8 -*-

require "RMagick"
require "fileutils"
require "stringio"
require "tmpdir"
require "zip"
require_relative "../inits/album_image_security"

RSpec.describe Kagetra::AlbumImageSecurity do
  around do |example|
    Dir.mktmpdir("album-image-security") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def path_for(name)
    File.join(@tmpdir,name)
  end

  def create_image(format,name)
    path = path_for(name)
    image = Magick::Image.new(2,2)
    begin
      image.write("#{format}:#{path}")
    ensure
      image.destroy!
    end
    path
  end

  def write_valid_xbm(path)
    File.open(path,"wb") do |file|
      file.write("#define harmless_width 8\n")
      file.write("#define harmless_height 8\n")
      file.write("static char harmless_bits[] = {\n")
      file.write("  0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, };\n")
    end
  end

  it "detects and safely reads JPEG, PNG, and GIF images" do
    {"JPEG"=>"image.jpg","PNG"=>"image.png","GIF"=>"image.gif"}.each do |format,name|
      path = create_image(format,name)
      expect(described_class.detect_format(path)).to eq(format)
      image,detected_format = described_class.read_image(path,format)
      begin
        expect(detected_format).to eq(format)
        expect(image.format).to eq(format)
      ensure
        image.destroy!
      end
    end
  end

  it "keeps image reads working after the worker has been idle" do
    path = create_image("JPEG","idle-worker.jpg")
    first, = described_class.read_image(path,"JPEG")
    first.destroy!

    sleep Float(ENV.fetch("KAGETRA_ALBUM_IDLE_REGRESSION_SECONDS","1"))

    second,detected_format = described_class.read_image(path,"JPEG")
    begin
      expect(detected_format).to eq("JPEG")
      expect(second.format).to eq("JPEG")
    ensure
      second.destroy!
    end
  end

  it "does not apply a process-lifetime ImageMagick time resource" do
    policy_path = File.expand_path("../config/imagemagick/policy.xml",__dir__)
    policy = File.read(policy_path)
    expect(policy).not_to match(/<policy\s+domain="resource"\s+name="time"/)
  end

  it "rejects an XBM file renamed as a JPEG before invoking ImageMagick" do
    path = path_for("disguised.jpg")
    write_valid_xbm(path)

    expect(Magick::Image).not_to receive(:read)
    expect {
      described_class.read_image(path)
    }.to raise_error(Kagetra::AlbumImageSecurity::InvalidImage)
  end

  it "rejects a mismatch between the stored format and the file signature" do
    path = create_image("PNG","mismatch.dat")
    expect(Magick::Image).not_to receive(:read)
    expect {
      described_class.read_image(path,"JPEG")
    }.to raise_error(Kagetra::AlbumImageSecurity::InvalidImage)
  end

  it "blocks the XBM coder through the ImageMagick policy" do
    path = path_for("harmless.xbm")
    write_valid_xbm(path)

    expect {
      Magick::Image.read("XBM:#{path}")
    }.to raise_error(Magick::ImageMagickError,/security policy/)
  end

  it "streams data without exceeding the configured expansion limit" do
    input = StringIO.new("a" * 1024)
    output = StringIO.new
    expect(described_class.copy_with_limit(input,output,1024)).to eq(1024)
    expect(output.string.bytesize).to eq(1024)
  end

  it "stops streaming when expanded data exceeds the configured limit" do
    input = StringIO.new("a" * 1025)
    output = StringIO.new
    expect {
      described_class.copy_with_limit(input,output,1024)
    }.to raise_error(Kagetra::AlbumImageSecurity::LimitExceeded)
  end

  it "streams an image entry with the production rubyzip API" do
    source_path = create_image("PNG","source.png")
    zip_path = path_for("images.zip")
    Zip::File.open(zip_path,Zip::File::CREATE) do |archive|
      archive.add("source.png",source_path)
    end

    extracted_path = path_for("extracted.dat")
    File.open(zip_path,"rb") do |zip_file|
      Zip::File.open(zip_file) do |archive|
        input = archive.first.get_input_stream
        begin
          File.open(extracted_path,"wb") do |output|
            described_class.copy_with_limit(input,output,1024 * 1024)
          end
        ensure
          input.close
        end
      end
    end
    expect(described_class.detect_format(extracted_path)).to eq("PNG")
  end
end

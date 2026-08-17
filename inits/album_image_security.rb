# -*- coding: utf-8 -*-

module Kagetra
  module AlbumImageSecurity
    class InvalidImage < StandardError; end
    class LimitExceeded < InvalidImage; end

    JPEG_SIGNATURE = [0xff, 0xd8, 0xff].pack("C*").freeze
    PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].pack("C*").freeze
    GIF87A_SIGNATURE = "GIF87a".freeze
    GIF89A_SIGNATURE = "GIF89a".freeze
    ALLOWED_FORMATS = ["JPEG", "PNG", "GIF"].freeze
    COPY_CHUNK_BYTES = 64 * 1024

    DEFAULT_MAX_IMAGE_BYTES = 64 * 1024 * 1024
    DEFAULT_MAX_ZIP_BYTES = 512 * 1024 * 1024
    DEFAULT_MAX_ZIP_EXPANDED_BYTES = 1024 * 1024 * 1024
    DEFAULT_MAX_ZIP_ENTRIES = 1000

    def self.configuration_value(name, default)
      Object.const_defined?(name) ? Integer(Object.const_get(name)) : default
    end

    MAX_IMAGE_BYTES = configuration_value(:CONF_ALBUM_MAX_IMAGE_BYTES, DEFAULT_MAX_IMAGE_BYTES)
    MAX_ZIP_BYTES = configuration_value(:CONF_ALBUM_MAX_ZIP_BYTES, DEFAULT_MAX_ZIP_BYTES)
    MAX_ZIP_EXPANDED_BYTES = configuration_value(:CONF_ALBUM_MAX_ZIP_EXPANDED_BYTES, DEFAULT_MAX_ZIP_EXPANDED_BYTES)
    MAX_ZIP_ENTRIES = configuration_value(:CONF_ALBUM_MAX_ZIP_ENTRIES, DEFAULT_MAX_ZIP_ENTRIES)

    def self.detect_format(path)
      header = File.open(path, "rb") { |file| file.read(PNG_SIGNATURE.bytesize) }.to_s
      return "JPEG" if header.start_with?(JPEG_SIGNATURE)
      return "PNG" if header.start_with?(PNG_SIGNATURE)
      return "GIF" if header.start_with?(GIF87A_SIGNATURE) || header.start_with?(GIF89A_SIGNATURE)
      raise InvalidImage, "JPEG・PNG・GIF以外の画像形式です"
    end

    def self.validate_size!(path, max_bytes)
      size = File.size(path)
      if size > max_bytes
        raise LimitExceeded, "ファイルサイズが上限（#{max_bytes} bytes）を超えています"
      end
      size
    end

    def self.read_image(path, expected_format=nil, max_bytes=MAX_IMAGE_BYTES)
      validate_size!(path, max_bytes)
      format = detect_format(path)
      if expected_format && format != expected_format.to_s.upcase
        raise InvalidImage, "保存された画像形式と実データが一致しません"
      end

      # The format prefix prevents ImageMagick from dispatching the input to a
      # different decoder. Reading scene zero also avoids decoding unused frames.
      images = Magick::Image.read("#{format}:#{File.realpath(path)}[0]")
      image = images.shift
      images.each { |other| other.destroy! }
      if image.nil? || image.format.to_s.upcase != format
        image.destroy! if image
        raise InvalidImage, "画像を安全に読み込めませんでした"
      end
      [image, format]
    end

    def self.copy_with_limit(input, output, max_bytes)
      total = 0
      while chunk = input.read(COPY_CHUNK_BYTES)
        break if chunk.empty?
        total += chunk.bytesize
        if total > max_bytes
          raise LimitExceeded, "展開後のファイルサイズが上限（#{max_bytes} bytes）を超えています"
        end
        output.write(chunk)
      end
      total
    end
  end
end

# -*- coding: utf-8 -*-

ENV["RACK_ENV"] = "production"

require "fileutils"
require "json"
require "rack"
require "rack/test"
require "tmpdir"
require "zip"

INTEGRATION_APP = Rack::Builder.parse_file(File.expand_path("../config.ru",__dir__)).first

RSpec.describe "album upload HTTP integration" do
  include Rack::Test::Methods

  def app
    INTEGRATION_APP
  end

  def parse_upload_response
    match = last_response.body.match(/<div id='response'>(.*)<\/div>/m)
    raise "upload response wrapper was missing: #{last_response.body}" unless match
    JSON.parse(match[1])
  end

  def log_in
    get "/"
    expect(last_response.status).to eq(200)

    user = User.first(name: "admin")
    message = "album-integration-login"
    payload = {
      user_id: user.id,
      msg: message,
      hash: Kagetra::Utils.hmac_password(user.password_hash,message)
    }
    post "/api/user/auth/user",JSON.generate(payload),"CONTENT_TYPE"=>"application/json"
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["result"]).to eq("OK")
  end

  def image_path(format,filename,columns=12,rows=8)
    path = File.join(@fixture_dir,filename)
    image = Magick::Image.new(columns,rows)
    begin
      image.write("#{format}:#{path}")
    ensure
      image.destroy!
    end
    path
  end

  def disguised_xbm_path(filename="disguised.jpg")
    path = File.join(@fixture_dir,filename)
    File.open(path,"wb") do |file|
      file.write("#define harmless_width 8\n")
      file.write("#define harmless_height 8\n")
      file.write("static char harmless_bits[] = {\n")
      file.write("  0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, };\n")
    end
    path
  end

  def upload(path,mime_type="application/octet-stream",attributes={})
    params = {
      "name" => "integration album",
      "start_at" => "2026-08-09",
      "file" => Rack::Test::UploadedFile.new(path,mime_type,true)
    }.merge(attributes)
    post "/album/upload", params
    result = parse_upload_response
    if result["result"] == "OK"
      expect(last_response.status).to eq(200)
    else
      expect([200,400]).to include(last_response.status)
    end
    result
  end

  def error_message(result)
    result["_error_"] || result["error_message"]
  end

  def stored_files
    Dir.glob(File.join(CONF_STORAGE_DIR,"album","**","*"),File::FNM_DOTMATCH).select{|path|File.file?(path)}
  end

  def response_image_format(body)
    return "JPEG" if body.start_with?(Kagetra::AlbumImageSecurity::JPEG_SIGNATURE)
    return "PNG" if body.start_with?(Kagetra::AlbumImageSecurity::PNG_SIGNATURE)
    return "GIF" if body.start_with?(Kagetra::AlbumImageSecurity::GIF87A_SIGNATURE) ||
                    body.start_with?(Kagetra::AlbumImageSecurity::GIF89A_SIGNATURE)
  end

  before do
    AlbumGroup.dataset.delete
    FileUtils.rm_rf(File.join(CONF_STORAGE_DIR,"album"))
    FileUtils.mkdir_p(File.join(CONF_STORAGE_DIR,"album"))
    @fixture_dir = Dir.mktmpdir("album-http-integration")
    log_in
  end

  after do
    FileUtils.rm_rf(@fixture_dir) if @fixture_dir
  end

  it "uploads JPEG, PNG, and GIF and serves their thumbnails" do
    {"JPEG"=>"image.jpg","PNG"=>"image.png","GIF"=>"image.gif"}.each do |format,filename|
      result = upload(image_path(format,filename),"image/#{format.downcase}")
      expect(result["result"]).to eq("OK")

      item = AlbumGroup[result["group_id"]].items_dataset.first
      expect(item.photo.format).to eq(format)
      expect(item.thumb.format).to eq(format)

      get "/static/album/thumb/#{item.thumb.id}.0"
      expect(last_response.status).to eq(200)
      expect(response_image_format(last_response.body)).to eq(format)
    end
  end

  it "serves a rotated photo through the protected decode path" do
    result = upload(image_path("JPEG","rotate.jpg",12,8),"image/jpeg")
    item = AlbumGroup[result["group_id"]].items_dataset.first

    get "/static/album/photo/#{item.photo.id}.90"
    expect(last_response.status).to eq(200)
    expect(response_image_format(last_response.body)).to eq("JPEG")
  end

  it "rejects an XBM renamed as JPEG without database or file orphans" do
    before_counts = [AlbumGroup.count,AlbumItem.count,stored_files.size]
    result = upload(disguised_xbm_path,"image/jpeg")

    expect(error_message(result)).to match(/JPEG|PNG|GIF/)
    expect([AlbumGroup.count,AlbumItem.count,stored_files.size]).to eq(before_counts)
  end

  it "applies the same validation to the beta API upload route" do
    group = AlbumGroup.create(
      name:"integration API album",
      start_at:Date.new(2026,8,9),
      owner_id:User.first(name:"admin").id
    )
    post "/api/album/upload", {
      "group_id" => group.id,
      "file" => Rack::Test::UploadedFile.new(disguised_xbm_path,"image/jpeg",true)
    }

    expect(last_response.status).to eq(400)
    expect(error_message(JSON.parse(last_response.body))).to match(/JPEG|PNG|GIF/)
    expect(group.items_dataset.count).to eq(0)
    expect(stored_files).to be_empty

    post "/api/album/upload", {
      "group_id" => group.id,
      "file" => Rack::Test::UploadedFile.new(image_path("JPEG","api-valid.jpg"),"image/jpeg",true)
    }
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["result"]).to eq("OK")
    expect(group.items_dataset.count).to eq(1)
    expect(stored_files.size).to eq(2)
  end

  it "accepts valid images from a ZIP and reports rejected disguised entries" do
    png = image_path("PNG","valid.png")
    disguised = disguised_xbm_path
    zip_path = File.join(@fixture_dir,"mixed.zip")
    Zip::File.open(zip_path,Zip::File::CREATE) do |archive|
      archive.add("valid.png",png)
      archive.add("disguised.jpg",disguised)
    end

    result = upload(zip_path,"application/zip")
    expect(result["result"]).to eq("OK")
    expect(result["rejected_files"].join(" ")).to include("disguised.jpg")
    expect(AlbumGroup[result["group_id"]].items_dataset.count).to eq(1)
    expect(stored_files.size).to eq(2)
  end

  it "rejects a direct image above the configured limit without orphans" do
    path = File.join(@fixture_dir,"oversized.jpg")
    File.open(path,"wb") do |file|
      file.write("\xFF\xD8\xFF".force_encoding("BINARY"))
      file.write("a" * Kagetra::AlbumImageSecurity::MAX_IMAGE_BYTES)
    end

    result = upload(path,"image/jpeg")
    expect(error_message(result)).to match(/上限/)
    expect(AlbumGroup.count).to eq(0)
    expect(AlbumItem.count).to eq(0)
    expect(stored_files).to be_empty
  end

  it "rolls back a ZIP when its aggregate expanded size exceeds the limit" do
    first = image_path("PNG","first.png")
    second = image_path("PNG","second.png")
    [first,second].each do |path|
      File.open(path,"ab"){|file|file.write("padding" * 30000)}
    end
    zip_path = File.join(@fixture_dir,"expanded-limit.zip")
    Zip::File.open(zip_path,Zip::File::CREATE) do |archive|
      archive.add("first.png",first)
      archive.add("second.png",second)
    end

    result = upload(zip_path,"application/zip")
    expect(error_message(result)).to match(/展開後サイズ/)
    expect(AlbumGroup.count).to eq(0)
    expect(AlbumItem.count).to eq(0)
    expect(stored_files).to be_empty
  end
end

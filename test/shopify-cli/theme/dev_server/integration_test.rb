# frozen_string_literal: true
require "test_helper"
require "shopify-cli/theme/dev_server"

class IntegrationTest < Minitest::Test
  @@port = 9292 # rubocop:disable Style/ClassVars

  ASSETS_API_URL = "https://dev-theme-server-store.myshopify.com/admin/api/2021-01/themes/123456789/assets.json"

  def setup
    super
    WebMock.disable_net_connect!(allow: "localhost:#{@@port}")
  end

  def teardown
    if @server_thread
      ShopifyCli::Theme::DevServer.stop
      @server_thread.join
    end
    @@port += 1 # rubocop:disable Style/ClassVars
  end

  def test_proxy_to_sfr
    stub_request(:any, ASSETS_API_URL)
      .to_return(status: 200, body: "{}")
    stub_request(:get, "https://dev-theme-server-store.myshopify.com/?_fd=0&preview_theme_id=123456789")
    stub_sfr = stub_request(:get, "https://dev-theme-server-store.myshopify.com/?_fd=0")

    start_server
    response = get("/")

    refute_server_errors(response)
    assert_requested(stub_sfr)
  end

  def test_uploads_files
    # Get the checksums
    stub_request(:any, ASSETS_API_URL)
      .to_return(status: 200, body: "{}")

    start_server
    # Wait for server to start & sync the files
    get("/assets/theme.css")

    # Should upload all theme files except the ignored files
    ignored_files = [
      "config.yml",
      "super_secret.json",
      "settings_data.json",
      "ignores_file",
    ]
    Pathname.new("#{__dir__}/theme").glob("**/*").each do |file|
      next unless file.file? && !ignored_files.include?(file.basename.to_s)
      assert_requested(:put, ASSETS_API_URL,
        body: JSON.generate(
          asset: {
            key: file.relative_path_from("#{__dir__}/theme").to_s,
            attachment: Base64.encode64(file.read),
          }
        ),
        at_least_times: 1,)
    end

    # Modify a file. Should upload on the fly.
    file = Pathname.new("#{ShopifyCli::ROOT}/test/fixtures/theme/assets/theme.css")
    begin
      file.write("modified")
      with_retries(Minitest::Assertion) do
        assert_requested(:put, ASSETS_API_URL,
          body: JSON.generate(
            asset: {
              key: "assets/theme.css",
              attachment: Base64.encode64("modified"),
            }
          ),
          at_least_times: 1,)
      end
    ensure
      file.write("")
    end
  end

  def test_serve_assets_locally
    stub_request(:any, ASSETS_API_URL)
      .to_return(status: 200, body: "{}")

    start_server
    response = get("/assets/theme.css")

    refute_server_errors(response)
  end

  def test_streams_hot_reload_events
    stub_request(:any, ASSETS_API_URL)
      .to_return(status: 200, body: "{}")

    start_server
    # Wait for server to start
    get("/assets/theme.css")

    # Send the SSE request
    socket = TCPSocket.new("localhost", @@port)
    socket.write("GET /hot-reload HTTP/1.1\r\n")
    socket.write("Host: localhost\r\n")
    socket.write("\r\n")
    socket.flush
    # Read the head
    assert_includes(socket.readpartial(1024), "HTTP/1.1 200 OK")
    # Add a file
    file = Pathname.new("#{ShopifyCli::ROOT}/test/fixtures/theme/assets/theme.css")
    file.write("modified")
    begin
      assert_equal("2a\r\ndata: {\"modified\":[\"assets/theme.css\"]}\n\n\n\r\n", socket.readpartial(1024))
    ensure
      file.write("")
    end
    socket.close
  end

  private

  def start_server
    @server_thread = Thread.new do
      ShopifyCli::Theme::DevServer.start("#{ShopifyCli::ROOT}/test/fixtures/theme", silent: true, port: @@port)
    end
  end

  def refute_server_errors(response)
    refute_includes(response, "error", response)
  end

  def get(path)
    with_retries(Errno::ECONNREFUSED) do
      Net::HTTP.get(URI("http://localhost:#{@@port}#{path}"))
    end
  end

  def with_retries(*exceptions, retries: 5)
    yield
  rescue *exceptions
    retries -= 1
    if retries > 0
      sleep(0.1)
      retry
    else
      raise
    end
  end
end
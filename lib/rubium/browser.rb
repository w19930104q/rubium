# frozen_string_literal: true

require 'chrome_remote'
require 'nokogiri'
require 'random-port'
require 'cliver'
require 'timeout'
require 'securerandom'
require 'logger'
require 'fileutils'

at_exit do
  Rubium::Browser.running_pids.each { |pid| Process.kill('HUP', pid) }
end

module Rubium
  class Browser
    class ConfigurationError < StandardError; end

    # Base class for every failure that can be located back to a selector.
    class SelectorError < StandardError; end

    # Raised when a selector does not match any element on the page.
    class ElementNotFound < SelectorError
      def initialize(selector, type:)
        super("Unable to find #{type} selector #{selector.inspect}")
      end
    end

    # Raised when an element exists but cannot receive a value
    # (disabled/readonly, not an input/textarea/select/contenteditable,
    # or a <select> has no matching option).
    class ElementNotEditable < SelectorError
      def initialize(selector, reason:)
        super("Element matched by #{selector.inspect} is not editable: #{reason}")
      end
    end

    MAX_CONNECT_WAIT_TIME = 6
    MAX_DEFAULT_TIMEOUT = 60

    # Selectors and values are never interpolated into the JavaScript source:
    # they are passed to Runtime.callFunctionOn as structured arguments.
    # The shared prefix only composes source code constants together.
    RESOLVE_ELEMENT_JS = <<~JS
      let isXPath = arguments[0];
      let selector = arguments[1];
      let el = null;
      try {
        if (isXPath) {
          el = document.evaluate(selector, document, null,
            XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
        } else {
          el = document.querySelector(selector);
        }
      } catch (err) {
        return {status: 'invalid_selector', reason: err.message};
      }
    JS

    CLICK_JS = "(function () {\n#{RESOLVE_ELEMENT_JS}\n  if (!el) return {status: 'not_found'};\n  el.click();\n  return {status: 'ok'};\n})"

    SEND_KEY_JS = <<~JS
      (function () {
      #{RESOLVE_ELEMENT_JS}
        if (!el) return {status: 'not_found'};
        el.dispatchEvent(new KeyboardEvent('keydown', {
          bubbles: true, cancelable: true, keyCode: arguments[2]
        }));
        return {status: 'ok'};
      })
    JS

    FILL_IN_JS = <<~JS
      (function () {
      #{RESOLVE_ELEMENT_JS}
        if (!el) return {status: 'not_found'};
        let value = arguments[2];

        if (el.tagName === 'SELECT') {
          let wanted = String(value);
          let match = null;
          for (let option of el.options) {
            if (option.value === wanted || option.text === wanted) { match = option; break; }
          }
          if (!match) return {status: 'not_editable', reason: "no option with value or text " + JSON.stringify(wanted)};
          el.value = match.value;
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return {status: 'ok'};
        }

        if (el.disabled || el.readOnly) {
          return {status: 'not_editable', reason: 'element is disabled or readonly'};
        }

        let isTextInput = el.tagName === 'INPUT' &&
          ['text','search','email','password','tel','url',
           'number','date','datetime-local','month','week','time','color',
           'hidden',''].includes((el.getAttribute('type') || 'text').toLowerCase());

        if (el.tagName === 'TEXTAREA' || isTextInput) {
          // Go through the prototype setter so frameworks (React/Vue/...)
          // observe the value change instead of their tracked value overriding it.
          let descriptor = Object.getOwnPropertyDescriptor(
            Object.getPrototypeOf(el), 'value');
          let stringValue = value == null ? '' : String(value);
          if (descriptor && descriptor.set) {
            descriptor.set.call(el, stringValue);
          } else {
            el.value = stringValue;
          }
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return {status: 'ok'};
        }

        if (el.isContentEditable) {
          el.focus();
          el.textContent = value == null ? '' : String(value);
          el.dispatchEvent(new InputEvent('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return {status: 'ok'};
        }

        return {status: 'not_editable',
                reason: 'element is not an input, textarea, select or contenteditable'};
      })
    JS

    class << self
      def ports_pool
        @ports_pool ||= RandomPort::Pool.new
      end

      def running_pids
        @running_pids ||= []
      end
    end

    attr_reader :client, :devtools_url, :pid, :port, :options, :processed_requests_count, :logger

    def initialize(options = {})
      @options = options

      if @options[:enable_logger]
        @logger = Logger.new($stdout)
        @logger.progname = self.class.to_s
      end

      create_browser
    end

    def restart!
      logger.info 'Restarting...' if options[:enable_logger]

      close
      create_browser
    end

    def close
      if closed?
        logger.info 'Browser already has been closed' if options[:enable_logger]
      else
        Process.kill('HUP', @pid)
        self.class.running_pids.delete(@pid)
        self.class.ports_pool.release(@port)

        # Delete temp profile directory, if there is no custom one
        FileUtils.rm_rf(@data_dir) if !options[:data_dir] && Dir.exist?(@data_dir)

        logger.info 'Closed browser' if options[:enable_logger]
        @closed = true
      end
    end

    alias destroy_driver! close

    def closed?
      @closed
    end

    def goto(url, max_timeout: options[:max_timeout] || MAX_DEFAULT_TIMEOUT)
      logger.info "Started request: #{url}" if options[:enable_logger]
      restart! if options[:restart_after] && processed_requests_count >= options[:restart_after]

      response = @client.send_cmd 'Page.navigate', url: url

      # By default, after Page.navigate we should wait till page will load completely
      # using Page.loadEventFired. But on some websites with Ajax navigation, Page.loadEventFired
      # will stuck forever. In this case you can provide `max_timeout: false` option to skip waiting.
      if max_timeout != false
        # https://chromedevtools.github.io/devtools-protocol/tot/Page#event-frameStoppedLoading
        Timeout.timeout(max_timeout) do
          @client.wait_for do |event_name, event_params|
            event_name == 'Page.frameStoppedLoading' && event_params['frameId'] == response['frameId']
          end
        end
      end

      @processed_requests_count += 1
      logger.info "Finished request: #{url}" if options[:enable_logger]
    end

    alias visit goto

    def body
      response = @client.send_cmd 'Runtime.evaluate', expression: 'document.documentElement.outerHTML'
      response.dig('result', 'value')
    end

    def current_response
      Nokogiri::HTML(body)
    end

    def has_xpath?(path, wait: 0)
      timer = 0
      until current_response.at_xpath(path)
        return false if timer >= wait

        timer += 0.2 and sleep 0.2
      end

      true
    end

    def has_css?(selector, wait: 0)
      timer = 0
      until current_response.at_css(selector)
        return false if timer >= wait

        timer += 0.2 and sleep 0.2
      end

      true
    end

    def has_text?(text, wait: 0)
      timer = 0
      until body&.include?(text)
        return false if timer >= wait

        timer += 0.2 and sleep 0.2
      end

      true
    end

    # Clicks an element located by CSS selector (default) or XPath.
    # Selector is passed to the page as data, so quotes/backslashes in it are harmless.
    # Raises Rubium::Browser::ElementNotFound when no element matches,
    # Rubium::Browser::SelectorError when the selector itself is invalid.
    def click(selector, type: nil)
      result = call_on_document(CLICK_JS, selector, type)
      assert_lookup_succeeded!(result, selector, type)
      result
    end

    # https://github.com/cyrus-and/chrome-remote-interface/issues/226#issuecomment-320247756
    # https://stackoverflow.com/a/18937620
    def send_key_on(selector, key, type: nil)
      result = call_on_document(SEND_KEY_JS, selector, type, key.to_i)
      assert_lookup_succeeded!(result, selector, type)
      result
    end

    # https://github.com/GoogleChrome/puppeteer/blob/master/lib/Page.js#L784
    # https://stackoverflow.com/questions/46113267/how-to-use-evaluateonnewdocument-and-exposefunction
    # https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-addScriptToEvaluateOnNewDocument
    def evaluate_on_new_document(script)
      @client.send_cmd 'Page.addScriptToEvaluateOnNewDocument', source: script
    end

    ###

    def cookies
      response = @client.send_cmd 'Network.getCookies'
      response['cookies']
    end

    # https://chromedevtools.github.io/devtools-protocol/tot/Network#method-setCookies
    def set_cookies(cookies)
      @client.send_cmd 'Network.setCookies', cookies: cookies
    end

    ###

    # Sets the value of an input, textarea, select or contenteditable element.
    # Both selector and text are passed to the page as data (never concatenated
    # into JavaScript), so double quotes, backslashes, backticks and newlines in
    # the value are written verbatim. Supports CSS (default) and XPath selectors.
    # Each successful write fires one `input` and one `change` event.
    # Raises Rubium::Browser::ElementNotFound when no element matches,
    # or Rubium::Browser::ElementNotEditable when the element cannot take a value.
    def fill_in(selector, text, type: nil)
      result = call_on_document(FILL_IN_JS, selector, type, text)
      assert_lookup_succeeded!(result, selector, type)

      if result['status'] == 'not_editable'
        raise ElementNotEditable.new(selector, reason: result['reason'])
      end

      result
    end

    def execute_script(script)
      @client.send_cmd 'Runtime.evaluate', expression: script
    end

    private

    # Converts the structured status returned by the in-page functions into
    # locatable Ruby exceptions. `ok` (and any other success status) passes through.
    def assert_lookup_succeeded!(result, selector, type)
      case result['status']
      when 'not_found'
        raise ElementNotFound.new(selector, type: selector_type(selector, type))
      when 'invalid_selector'
        raise SelectorError,
              "Invalid #{selector_type(selector, type)} selector #{selector.inspect}: #{result['reason']}"
      end
    end

    # Runs a JS function in the page context with the selector and its payload
    # delivered as call arguments via Runtime.callFunctionOn, i.e. over CDP's
    # structured data channel rather than through string interpolation.
    def call_on_document(function, selector, type, *payload)
      is_xpath = selector_type(selector, type) == 'xpath'
      global = @client.send_cmd('Runtime.evaluate', expression: 'globalThis')
      object_id = global.dig('result', 'objectId')

      response = @client.send_cmd(
        'Runtime.callFunctionOn',
        objectId: object_id,
        functionDeclaration: function,
        arguments: [{ value: is_xpath }, { value: selector.to_s }] +
                   payload.map { |arg| { value: arg } },
        returnByValue: true
      )

      if (details = response['exceptionDetails'])
        raise ConfigurationError, "JavaScript error in browser: #{details.dig('exception', 'description') || details['text']}"
      end

      response.dig('result', 'value') or
        raise(ConfigurationError, 'Browser returned no result for the executed function')
    ensure
      @client.send_cmd('Runtime.releaseObject', objectId: object_id) if object_id
    end

    # Explicit `type:` (:css/:xpath or strings) wins; otherwise a selector that
    # looks like an XPath expression (starts with / or ./ or ../ or "(") is
    # treated as XPath, matching common XPath authoring conventions.
    def selector_type(selector, type)
      return type.to_s if type

      selector.to_s.match?(%r{\A\s*(\(\s*|\./|\.\./|/)}) ? 'xpath' : 'css'
    end

    def create_browser
      @processed_requests_count = 0

      @port = options[:debugging_port] || self.class.ports_pool.acquire

      @data_dir = options[:data_dir] || "/tmp/rubium_profile_#{SecureRandom.hex}"

      chrome_path = get_chrome_path
      raise ConfigurationError, "Can't find chrome executable" unless chrome_path

      command = %W[
        #{chrome_path} about:blank
        --remote-debugging-port=#{@port}
        --user-data-dir=#{@data_dir}
      ] + DEFAULT_ARGS

      command << '--headless' if ENV['HEADLESS'] != 'false' && options[:headless] != false
      command << "--window-size=#{options[:window_size].join(',')}" if options[:window_size]

      if options[:user_agent]
        user_agent = options[:user_agent].respond_to?(:call) ? options[:user_agent].call : options[:user_agent]
        command << "--user-agent=#{user_agent}"
      end

      if options[:proxy_server]
        proxy_server = options[:proxy_server].respond_to?(:call) ? options[:proxy_server].call : options[:proxy_server]
        proxy_server = convert_proxy(proxy_server) unless proxy_server.include?('://')
        command << "--proxy-server=#{proxy_server}"
      end

      @pid = spawn(*command, %i[out err] => '/dev/null')
      self.class.running_pids << @pid
      @closed = false

      counter = 0
      begin
        counter += 0.2 and sleep 0.2
        @client = ChromeRemote.client(port: @port)
      rescue Errno::ECONNREFUSED => e
        counter < MAX_CONNECT_WAIT_TIME ? retry : raise(e)
      end

      @devtools_url = "http://localhost:#{@port}/"

      # https://github.com/GoogleChrome/puppeteer/blob/master/lib/Page.js
      @client.send_cmd 'Target.setAutoAttach', autoAttach: true, waitForDebuggerOnStart: false
      @client.send_cmd 'Network.enable'
      @client.send_cmd 'Page.enable'

      evaluate_on_new_document(options[:extension_code]) if options[:extension_code]

      set_cookies(options[:cookies]) if options[:cookies]

      if options[:urls_blacklist] || options[:disable_images]
        urls = []

        urls += options[:urls_blacklist] if options[:urls_blacklist]

        if options[:disable_images]
          urls += %w[jpg jpeg png gif swf svg tif].map { |ext| ["*.#{ext}", "*.#{ext}?*"] }.flatten
          urls << 'data:image*'
        end

        @client.send_cmd 'Network.setBlockedURLs', urls: urls
      end

      logger.info 'Opened browser' if options[:enable_logger]
    end

    def get_chrome_path
      path = Rubium.configuration.chrome_path || Cliver.detect('chromium-browser') || Cliver.detect('google-chrome')
      return path if path

      macos_path = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
      macos_path if File.executable?(macos_path)
    end

    def convert_proxy(proxy_string)
      ip, port, type, = proxy_string.split(':')
      "#{type}://#{ip}:#{port}"
    end
  end
end

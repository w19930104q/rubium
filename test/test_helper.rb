# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'rubium'

require 'minitest/autorun'

# The CI/dev box ships a Playwright Chromium whose shared libraries live
# outside the default linker search path. Allow overriding via env vars while
# keeping ordinary installs (chrome on PATH) working untouched.
chrome_path = ENV['CHROME_PATH']
chrome_path ||= begin
  candidate = '/home/liiing/.cache/ms-playwright/chromium-1254/chrome-linux64/chrome'
  File.exist?(candidate) ? candidate : nil
end

if chrome_path
  lib_path = ENV['CHROME_LIB_PATH'] || '/home/liiing/.local/pwlibs/usr/lib/x86_64-linux-gnu'
  ENV['LD_LIBRARY_PATH'] = [lib_path, ENV['LD_LIBRARY_PATH']].compact.join(':')
  Rubium.configure { |config| config.chrome_path = chrome_path }
end

module TestPage
  FORM_URL = "file://#{File.expand_path('fixtures/form.html', __dir__)}"

  SPECIAL_SINGLE_LINE = 'he said "hi", path C:\tmp\a, `code` and $ interpolation'.freeze
  SPECIAL_MULTI_LINE = "line one \"quoted\"\nline two \\ backslash\nline three `backtick`".freeze

  def browser
    RubiumTest.browser
  end

  def open_form
    browser.goto(FORM_URL)
  end

  # Thin delegators so examples read like the public Browser API.
  def click(selector, **kwargs)
    browser.click(selector, **kwargs)
  end

  def fill_in(selector, text, **kwargs)
    browser.fill_in(selector, text, **kwargs)
  end

  def send_key_on(selector, key, **kwargs)
    browser.send_key_on(selector, key, **kwargs)
  end

  # Reads a value back from the page through a plain (data-based) CDP call.
  def js_value(expression)
    response = browser.execute_script(expression)
    response.dig('result', 'value')
  end

  def counter(name)
    js_value("document.getElementById('counters').dataset.#{name}").to_i
  end
end

class RubiumTest < Minitest::Test
  include TestPage

  class << self
    def browser
      @browser ||= Rubium::Browser.new
    end
  end

  Minitest.after_run do
    @browser&.close
  end
end

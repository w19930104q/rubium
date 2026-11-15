# frozen_string_literal: true

require 'test_helper'

# End-to-end coverage against a local file:// page. The focus is on data-only
# selector/value transport (no JavaScript string interpolation), CSS/XPath
# support, locatable exceptions, input/change events and sequential operations.
class BrowserFormTest < Minitest::Test
  include TestPage

  def setup
    open_form
  end

  # --- fill_in: special characters ---------------------------------------

  def test_fill_in_writes_double_quotes_backslashes_backticks_verbatim
    fill_in('#note-first', SPECIAL_SINGLE_LINE)

    assert_equal SPECIAL_SINGLE_LINE, js_value("document.getElementById('note-first').value")
  end

  def test_fill_in_writes_newlines_verbatim_into_textarea
    fill_in('#remarks', SPECIAL_MULTI_LINE)

    assert_equal SPECIAL_MULTI_LINE, js_value("document.getElementById('remarks').value")
  end

  def test_fill_in_treats_payload_as_data_not_code
    # Under the old interpolated implementation these payloads either raised a
    # SyntaxError or executed the injected expression.
    payloads = [
      %q!("); alert(1); ("!,
      %q!`); alert(2); //!,
      %q!\"); alert(3); //!,
      %q!a"b\c`d$<e>'f!
    ]

    payloads.each do |payload|
      fill_in('#note-first', payload)
      assert_equal payload, js_value("document.getElementById('note-first').value"),
                   "payload #{payload.inspect} was not written verbatim"
    end
  end

  def test_selector_with_quotes_and_backslashes_is_treated_as_data
    # The element id itself contains a double quote, backtick and backslash.
    selector = %q![data-test='say "hi"']!
    fill_in(selector, SPECIAL_SINGLE_LINE)

    assert_equal SPECIAL_SINGLE_LINE,
                 js_value("document.querySelector('[data-test]').value")
  end

  # --- same-name controls -------------------------------------------------

  def test_same_name_controls_are_independently_addressable_by_id
    fill_in('#note-first', 'first value')
    fill_in('#note-second', 'second value')

    assert_equal 'first value', js_value("document.getElementById('note-first').value")
    assert_equal 'second value', js_value("document.getElementById('note-second').value")
  end

  def test_css_class_selector_hits_first_of_same_name_controls
    fill_in('.note-field', 'class target')

    assert_equal 'class target', js_value("document.getElementById('note-first').value")
    assert_equal '', js_value("document.getElementById('note-second').value")
  end

  # --- XPath support ------------------------------------------------------

  def test_xpath_selector_is_auto_detected_and_used
    fill_in('//textarea[@id="remarks"]', 'via xpath')

    assert_equal 'via xpath', js_value("document.getElementById('remarks').value")
  end

  def test_explicit_xpath_type_overrides_auto_detection
    fill_in('//input[@id="note-second"]', 'explicit xpath', type: :xpath)

    assert_equal 'explicit xpath', js_value("document.getElementById('note-second').value")
  end

  def test_xpath_click_targets_the_matching_element
    click('//button[@id="submit-btn"]', type: :xpath)

    assert_operator counter(:clicks), :>=, 1
  end

  # --- element kinds: select / contenteditable ----------------------------

  def test_fill_in_select_by_option_value_and_text
    fill_in('#country', 'jp')
    assert_equal 'jp', js_value("document.getElementById('country').value")

    fill_in('#country', 'France')
    assert_equal 'fr', js_value("document.getElementById('country').value")
  end

  def test_fill_in_contenteditable_writes_text_and_fires_events
    fill_in('#editor', SPECIAL_MULTI_LINE)

    assert_equal SPECIAL_MULTI_LINE, js_value("document.getElementById('editor').textContent")
    assert_equal 1, counter(:inputs)
    assert_equal 1, counter(:changes)
  end

  def test_fill_in_textarea_fires_one_input_and_one_change
    fill_in('#remarks', 'remarkable')

    assert_equal 1, counter(:inputs)
    assert_equal 1, counter(:changes)
  end

  def test_fill_in_input_fires_one_input_and_one_change
    fill_in('#note-first', 'noted')

    assert_equal 1, counter(:inputs)
    assert_equal 1, counter(:changes)
  end

  def test_fill_in_select_fires_one_input_and_one_change
    fill_in('#country', 'jp')

    assert_equal 1, counter(:inputs)
    assert_equal 1, counter(:changes)
  end

  # --- sequential operations ---------------------------------------------

  def test_consecutive_fills_and_clicks_on_one_page
    fill_in('#note-first', 'one')
    fill_in('#note-second', 'two')
    fill_in('#remarks', 'three')
    fill_in('#country', 'jp')
    click('#submit-btn')
    fill_in('#note-first', 'overwritten')

    assert_equal 'overwritten', js_value("document.getElementById('note-first').value")
    assert_equal 'two', js_value("document.getElementById('note-second').value")
    assert_equal 'three', js_value("document.getElementById('remarks').value")
    assert_equal 'jp', js_value("document.getElementById('country').value")
    assert_operator counter(:clicks), :>=, 1
  end

  def test_fill_in_overwrites_previous_value
    fill_in('#note-first', 'initial')
    fill_in('#note-first', 'final')

    assert_equal 'final', js_value("document.getElementById('note-first').value")
  end

  def test_send_key_on_dispatches_keydown_with_data_based_selector
    send_key_on('#note-first', 13)

    assert_equal 1, counter(:keydowns)
  end

  def test_click_works_with_quoted_selector
    selector = %q![id='btn "quoted"']!
    click(selector)

    assert_operator counter(:clicks), :>=, 1
  end

  # --- locatable exceptions ----------------------------------------------

  def test_fill_in_raises_element_not_found_for_missing_css
    error = assert_raises(Rubium::Browser::ElementNotFound) do
      fill_in('#does-not-exist', 'x')
    end

    assert_match(/#does-not-exist/, error.message)
    assert_kind_of Rubium::Browser::SelectorError, error
  end

  def test_click_raises_element_not_found_for_missing_xpath
    error = assert_raises(Rubium::Browser::ElementNotFound) do
      click('//*[@id="missing"]', type: :xpath)
    end

    assert_match(/xpath/i, error.message)
  end

  def test_fill_in_raises_on_disabled_and_readonly_controls
    assert_raises(Rubium::Browser::ElementNotEditable) do
      fill_in('#disabled-field', 'x')
    end
    assert_raises(Rubium::Browser::ElementNotEditable) do
      fill_in('#readonly-field', 'x')
    end
  end

  def test_fill_in_raises_on_non_editable_control_kind
    error = assert_raises(Rubium::Browser::ElementNotEditable) do
      fill_in('#check-field', 'x')
    end

    assert_match(/#check-field/, error.message)
  end

  def test_fill_in_raises_when_select_option_does_not_match
    assert_raises(Rubium::Browser::ElementNotEditable) do
      fill_in('#country', 'Atlantis')
    end
  end

  def test_invalid_css_selector_raises_selector_error
    assert_raises(Rubium::Browser::SelectorError) do
      fill_in('::::not-a-selector', 'x')
    end
  end

  # --- signature compatibility -------------------------------------------

  def test_method_signatures_keep_original_positional_arity
    # Original positional parameters are preserved; `type:` is an added
    # optional keyword argument, so the required positional arity is unchanged.
    expected = { click: 1, fill_in: 2, send_key_on: 2 }
    expected.each do |method_name, count|
      parameters = Rubium::Browser.instance_method(method_name).parameters
      required_positionals = parameters.count { |kind, _| kind == :req }
      assert_equal count, required_positionals, "#{method_name} must keep #{count} required positional args"
    end

    # Original call style without the new keyword still works.
    fill_in('#note-first', 'plain call')
    assert_equal 'plain call', js_value("document.getElementById('note-first').value")
  end
end

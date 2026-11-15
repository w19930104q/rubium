# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
- `click`, `fill_in` and `send_key_on` no longer interpolate selectors and
  values into JavaScript. They are passed as data over the CDP
  `Runtime.callFunctionOn` channel, so quotes, backslashes, backticks and
  newlines in user input can no longer break the syntax or execute injected
  code (CVE-style selector/value injection).

### Added
- CSS **and XPath** selector support for `click`, `fill_in` and `send_key_on`
  via an optional `type:` keyword (`:css`/`:xpath`); XPath expressions are
  also auto-detected when the selector starts with `/`, `./`, `../` or `(`.
- `Rubium::Browser::ElementNotFound` for selectors matching no element,
  `Rubium::Browser::ElementNotEditable` for disabled/readonly or
  non-input controls (and missing `<select>` options), and a common
  `Rubium::Browser::SelectorError` base class (also raised on invalid selectors).
- `fill_in` now supports `input`, `textarea`, `select` (option by value or
  visible text) and `contenteditable` elements, firing one `input` and one
  `change` event per successful write.

### Changed
- Method signatures are unchanged for existing callers; `type:` is an added
  optional keyword argument.

## [0.3.2] - 2025-12-31
 
* Add ostruct to gemspec (Ruby 3.5 compatibility)
* Rename DEFAULT_PUPPETEER_ARGS to DEFAULT_ARGS

## [0.3.1] - 2025-12-16

### Added
- Use [Patchright like](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright?tab=readme-ov-file#command-flags-leaks) CLI args for better antidetect performance 
- Add required Ruby version >= 3.1.0
- Add Rubocop

## [0.3.0] - 2025-12-12

### Added
- Autofetch chrome path on MacOS

### Changed
- Use backticks inside 'Runtime.evaluate' for better compatibility

## [0.2.1] - 2025-12-07

### Added
- Added CHANGELOG.md to track version changes
- Require fileutils to make sure fileutils included in newer ruby versions
- Update dependencies 

### Changed
- Updated MAX_CONNECT_WAIT_TIME to 6 seconds
- Added option to provide custom data-dir path

## [0.2.0] - 2019-02-24

- Added logging support
- Added cookies and restart_after options
- Added urls_blacklist and disable_images options
- Various bug fixes and improvements

## [0.1.0] - 2019-01-XX

- Initial release

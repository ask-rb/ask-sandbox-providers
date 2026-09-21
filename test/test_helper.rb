# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-core/lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ask-runtime/lib", __dir__)
require "ask-sandbox-providers"
require "ask-runtime"
require "ask/runtime/testing"
require "minitest/autorun"
require "mocha/minitest" if Gem.loaded_specs.key?("mocha")

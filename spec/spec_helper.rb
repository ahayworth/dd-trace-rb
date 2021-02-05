$LOAD_PATH.unshift File.expand_path('../../', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'pry'
require 'rspec/collection_matchers'
require 'webmock/rspec'
require 'climate_control'

# Skip for benchmarks, as coverage collection slows them down.
unless RSpec.configuration.files_to_run.all? { |path| path.include?('/benchmark/') }
  # +SimpleCov.start+ must be invoked before any application code is loaded
  require 'simplecov'
  SimpleCov.start do
    formatter SimpleCov::Formatter::SimpleFormatter
  end
end

require 'ddtrace/encoding'
require 'ddtrace/tracer'
require 'ddtrace/span'

require 'support/configuration_helpers'
require 'support/container_helpers'
require 'support/faux_transport'
require 'support/faux_writer'
require 'support/health_metric_helpers'
require 'support/http_helpers'
require 'support/log_helpers'
require 'support/metric_helpers'
require 'support/network_helpers'
require 'support/platform_helpers'
require 'support/span_helpers'
require 'support/spy_transport'
require 'support/synchronization_helpers'
require 'support/test_helpers'
require 'support/tracer_helpers'

begin
  # Ignore interpreter warnings from external libraries
  require 'warning'
  Warning.ignore([:method_redefined, :not_reached, :unused_var], %r{.*/gems/[^/]*/lib/})
rescue LoadError
  puts 'warning suppressing gem not available, external library warnings will be displayed'
end

WebMock.allow_net_connect!
WebMock.disable!

RSpec.configure do |config|
  config.include ConfigurationHelpers
  config.include ContainerHelpers
  config.include HealthMetricHelpers
  config.include HttpHelpers
  config.include LogHelpers
  config.include MetricHelpers
  config.include NetworkHelpers
  config.include SpanHelpers
  config.include SynchronizationHelpers
  config.include TestHelpers
  config.include TracerHelpers

  config.include TestHelpers::RSpec::Integration, :integration

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  config.filter_run focus: true
  config.run_all_when_everything_filtered = true

  if config.files_to_run.one?
    # Use the documentation formatter for detailed output,
    # unless a formatter has already been configured
    # (e.g. via a command-line flag).
    config.default_formatter = 'doc'
  end

  # Check for leaky test resources
  config.after(:all) do
    # Exclude acceptable background threads
    background_threads = Thread.list.reject do |t|
      group_name = t.group.instance_variable_get(:@group_name) if t.group.instance_variable_defined?(:@group_name)
      backtrace = t.backtrace || []

      # Current thread
      t == Thread.current ||
        # Thread has shut down, but we caught it right as it was still alive
        !t.alive? ||
        # Internal JRuby thread
        defined?(JRuby) && JRuby.reference(t).native_thread.name == 'Finalizer' ||
        # WEBrick singleton thread for handling timeouts
        backtrace.find { |b| b.include?('/webrick/utils.rb') } ||
        # Rails connection reaper
        backtrace.find { |b| b.include?('lib/active_record/connection_adapters/abstract/connection_pool.rb') } ||
        # Ruby JetBrains debugger
        t.class.name.include?('DebugThread') ||
        # Categorized as a known leaky thread
        !group_name.nil?
    end

    unless background_threads.empty?
      info = background_threads.flat_map do |t|
        caller = t.instance_variable_get(:@caller) || '(not recorded)'
        [
          "#{t} (#{t.class.name})",
          ' == Caller ==',
          caller,
          ' == Backtrace ==',
          t.backtrace,
          "\n"
        ]
      end.join("\n")

      # We cannot fail tests gracefully in an `after(:all)` block.
      # The test results have already been decided by RSpec.
      # We resort to a more "blunt approach.
      STDERR.puts RSpec::Core::Formatters::ConsoleCodes.wrap(
        "#{self.class.description}: Test leaked threads! Ensure all threads are terminated when test finishes:",
        :red
      )
      STDERR.puts info
      Kernel.exit!(1) unless ENV.key?('CI')
    end
  end

  config.around(:each) do |example|
    example.run.tap do
      tracer_shutdown!
    end
  end
end

# Stores the caller thread backtrace,
# To allow for leaky threads to be traced
# back to their creation point.
module DatadogThreadDebugger
  def initialize(*args)
    caller_ = caller
    wrapped = lambda do |*thread_args|
      Thread.current.instance_variable_set(:@caller, caller_)
      yield(*thread_args)
    end

    super(*args, &wrapped)
  end

  ruby2_keywords :initialize if respond_to?(:ruby2_keywords, true)
end

Thread.send(:prepend, DatadogThreadDebugger)

# Helper matchers
RSpec::Matchers.define_negated_matcher :not_be, :be

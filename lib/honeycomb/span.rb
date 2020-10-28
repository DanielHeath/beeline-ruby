# frozen_string_literal: true

require "forwardable"
require "securerandom"
require "honeycomb/propagation"
require "honeycomb/deterministic_sampler"
require "honeycomb/rollup_fields"

module Honeycomb
  # Represents a Honeycomb span, which wraps a Honeycomb event and adds specific
  # tracing functionality
  class Span
    include PropagationSerializer
    include DeterministicSampler
    include RollupFields
    extend Forwardable

    def_delegators :@event, :add_field, :add
    def_delegator :@trace, :add_field, :add_trace_field

    attr_reader :id, :trace, :parent

    def initialize(trace:,
                   builder:,
                   context:,
                   **options)
      @id = generate_span_id
      @context = context
      @context.current_span = self
      @builder = builder
      @event = builder.event
      @trace = trace
      @children = []
      @sent = false
      @started = clock_time
      parse_options(**options)
    end

    def parse_options(parent: nil,
                      parent_id: nil,
                      is_root: parent_id.nil?,
                      sample_hook: nil,
                      presend_hook: nil,
                      sample_excludes_child_spans: nil,
                      **_options)
      @parent = parent
      # parent_id should be removed in the next major version bump. It has been
      # replaced with passing the actual parent in. This is kept for backwards
      # compatability
      @parent_id = parent_id
      @is_root = is_root
      @presend_hook = presend_hook
      @sample_hook = sample_hook
      @sample_excludes_child_spans = sample_excludes_child_spans
    end

    def create_child
      self.class.new(trace: trace,
                     builder: builder,
                     context: context,
                     parent: self,
                     parent_id: id,
                     sample_hook: sample_hook,
                     presend_hook: presend_hook,
                     sample_excludes_child_spans: @sample_excludes_child_spans).tap do |c|
        children << c
      end
    end

    def send
      return if sent?

      send_internal
    end

    def will_send_by_parent!
      @will_send_by_parent = true
      context.span_finished(self)
    end

    protected

    def send_by_parent
      return if sent?

      add_field "meta.sent_by_parent", true
      send_internal
    end

    def skip_sending
      children.each &:skip_sending
      mark_sent!
    end

    def remove_child(child)
      children.delete child
    end

    def span_ancestors
      return [] unless parent
      parent.span_ancestors + [parent]
    end

    def sampling_says_send?
      if @sample_excludes_child_spans && parent
        return parent.sampling_says_send?
      end

      if @sampling_says_send == nil
        if sample_hook.nil?
          @sampling_says_send = should_sample(event.sample_rate, trace.id)
        else
          @sampling_says_send, event.sample_rate = sample_hook.call(event.data)
        end
      end
      @sampling_says_send
    end

    private

    INVALID_SPAN_ID = ("00" * 8)

    attr_reader :event,
                :parent_id,
                :children,
                :builder,
                :context,
                :presend_hook,
                :sample_hook

    def sent?
      @sent
    end

    def root?
      @is_root
    end

    def mark_sent!
      @sent = true
      context.span_finished(self) unless @will_send_by_parent

      parent && parent.remove_child(self)
    end

    def send_internal
      add_additional_fields
      sample = sampling_says_send?
      puts " * " + (" " * span_ancestors.length) + "- " + event.data['name'] + "(#{sample})"

      unless @sample_excludes_child_spans && !sample
        send_children
      else
        skip_children
      end

      if sample
        presend_hook && presend_hook.call(event.data)
        event.send_presampled
      end
      mark_sent!
    end

    def add_additional_fields
      add_field "duration_ms", duration_ms
      add_field "trace.trace_id", trace.id
      add_field "trace.span_id", id
      add_field "meta.span_type", span_type
      parent_id && add_field("trace.parent_id", parent_id)
      add rollup_fields
      add trace.fields
      span_type == "root" && add(trace.rollup_fields)
    end

    def send_children
      children.each do |child|
        child.send_by_parent
      end
    end

    def skip_children
      children.each do |child|
        child.skip_sending
      end
    end

    def duration_ms
      (clock_time - @started) * 1000
    end

    def clock_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def span_type
      if root?
        parent_id.nil? ? "root" : "subroot"
      elsif children.empty?
        "leaf"
      else
        "mid"
      end
    end

    def generate_span_id
      loop do
        id = SecureRandom.hex(8)
        return id unless id == INVALID_SPAN_ID
      end
    end
  end
end

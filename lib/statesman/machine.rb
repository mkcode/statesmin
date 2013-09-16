require "statesman/version"
require "statesman/exceptions"
require "statesman/guard"
require "statesman/callback"
require "statesman/transition"

module Statesman
  # The main module, that should be `extend`ed in to state machine classes.
  module Machine
    def self.included(base)
      base.extend(ClassMethods)
      base.send(:attr_reader, :object)
      base.send(:attr_reader, :state_attr)
    end

    module ClassMethods
      attr_reader :initial_state

      def states
        @states ||= []
      end

      def state(name, initial: false)
        if initial
          validate_initial_state(name)
          @initial_state = name
        end
        states << name
      end

      def successors
        @successors ||= {}
      end

      def before_callbacks
        @before_callbacks ||= []
      end

      def after_callbacks
        @after_callbacks ||= []
      end

      def guards
        @guards ||= []
      end

      def transition(from: nil, to: nil)
        successors[from] ||= []
        to = Array(to)

        ([from] + to).each { |state| validate_state(state) }

        successors[from] += to
      end

      def before_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        before_callbacks << Callback.new(from: from, to: to, callback: block)
      end

      def after_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        after_callbacks << Callback.new(from: from, to: to, callback: block)
      end

      def guard_transition(from: nil, to: nil, &block)
        validate_callback_condition(from: from, to: to)
        guards << Guard.new(from: from, to: to, callback: block)
      end

      def validate_callback_condition(from: nil, to: nil)
        [from, to].compact.each { |state| validate_state(state) }
        return if from.nil? && to.nil?

        # Check that the 'from' state is not terminal
        unless from.nil? || successors.keys.include?(from)
          raise InvalidTransitionError,
                "Cannont transition away from terminal state '#{from}'"
        end

        # Check that the 'to' state is not initial
        unless to.nil? || successors.values.flatten.include?(to)
          raise InvalidTransitionError,
                "Cannont transition to initial state '#{from}'"
        end

        return if from.nil? || to.nil?

        # Check that the transition is valid when 'from' and 'to' are given
        unless successors.fetch(from, []).include?(to)
          raise InvalidTransitionError,
                "Cannot transition from '#{from}' to '#{to}'"
        end
      end

      private

      def validate_state(state)
        unless states.include?(state)
          raise InvalidStateError, "Invalid state '#{state}'"
        end
      end

      def validate_initial_state(state)
        unless initial_state.nil?
          raise InvalidStateError, "Cannot set initial state to '#{state}', " +
                                   "already defined as #{initial_state}."
        end
      end
    end

    def initialize(object, transition_class: Statesman::Transition,
                   state_attr: :current_state)
      @object = object
      @storage_adapter = Statesman.storage_adapter.new(transition_class,
                                                       object, state_attr)
      @state_attr = state_attr
    end

    def current_state
      last_action = @storage_adapter.last
      last_action ? last_action.to_state : self.class.initial_state
    end

    def can_transition_to?(new_state)
      validate_transition(from: current_state, to: new_state)
      true
    rescue InvalidTransitionError, GuardFailedError
      false
    end

    def history
      @storage_adapter.history
    end

    def transition_to!(new_state, metadata = nil)
      validate_transition(from: current_state, to: new_state)

      before_callbacks_for(from: current_state, to: new_state).each do |cb|
        cb.call(@object)
      end

      @storage_adapter.create(new_state, metadata)

      after_callbacks_for(from: current_state, to: new_state).each do |cb|
        cb.call(@object)
      end

      current_state
    end

    def transition_to(new_state, metadata = nil)
      self.transition_to!(new_state, metadata)
    rescue
      false
    end

    def guards_for(from: nil, to: nil)
      select_callbacks_for(self.class.guards, from: from, to: to)
    end

    def before_callbacks_for(from: nil, to: nil)
      select_callbacks_for(self.class.before_callbacks, from: from, to: to)
    end

    def after_callbacks_for(from: nil, to: nil)
      select_callbacks_for(self.class.after_callbacks, from: from, to: to)
    end

    private

    def select_callbacks_for(callbacks, from: nil, to: nil)
      callbacks.select { |callback| callback.applies_to?(from: from, to: to) }
    end

    def validate_transition(from: nil, to: nil)
      # Call all guards, they raise exceptions if they fail
      guards_for(from: from, to: to).each { |guard| guard.call(@object) }

      successors = self.class.successors[from] || []
      unless successors.include?(to)
        raise InvalidTransitionError,
              "Cannot transition from '#{from}' to '#{to}'"
      end
    end

  end
end

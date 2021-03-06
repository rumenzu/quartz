module Quartz
  # A base class that wraps the state of a model. Automatically extended by
  # models through use of the `state` macro.
  #
  # See `Stateful#state`.
  class State
    # The `var` macro defines a state *variable* for the `State` of a model. Its
    # primary goal is to generate convenient getters and setters for the model
    # among other purposes.
    #
    # It is intended to be used within a block provided with the `Stateful#state`
    # macro.
    #
    # Unlike state parameters, state variables are updated during the simulation
    # by its model behaviour.
    #
    # See also `#parameter`
    # See also `Stateful#state`.
    #
    # ### Usage
    #
    # `var` must receive a type declaration which will be used to declare an instance
    # variable, a getter and a setter.
    #
    # Default values *must* be declared using the type declaration notation or through
    # a block (lazy initialization) :
    #
    # ```
    # state do
    #   var foo : Int32 = 42
    #   var bar : Int32 { (rand * 100 + 1).to_i32 }
    #   var quz : Int32 { foo * 42 }
    # end
    # ```
    #
    # Note from previous example that the initialization block of `quz` is
    # allowed to reference the value of another state variable.
    macro var(name, &block)
      {%
        prop = if name.is_a?(TypeDeclaration)
                 {name: name.var, type: name.type, value: name.value, block: block}
               elsif name.is_a?(Assign)
                 {name: name.target, value: name.value, block: block}
               else
                 name.raise "a type, a default value or a block should be given to declare a state variable"
               end
        STATE_VARS << prop
      %}

      property {{name}} {% if block %} {{block}} {% end %}
    end

    # The `parameter` macro defines a state *parameter* for the `State` of a model.
    #
    # It is intended to be used within a block provided with the `Stateful#state`
    # macro.
    #
    # Unlike state variables, parameters are read-only variables that can be set
    # with the initial state of a model. As an example, they can be used to
    # define the constants of an equation.
    #
    # See also `#var` to declare state variables.
    # See also `Stateful#state`.
    #
    # ### Usage
    #
    # `parameter` must receive a type declaration which will be used to declare an instance
    # variable and a getter.
    #
    # Default values *must* be declared using the type declaration notation or through
    # a block (lazy initialization) :
    #
    # ```
    # state do
    #   parameter c = 0.013
    # end
    # ```
    macro parameter(name, &block)
      {%
        prop = if name.is_a?(TypeDeclaration)
                 {name: name.var, type: name.type, value: name.value, block: block}
               elsif name.is_a?(Assign)
                 {name: name.target, value: name.value, block: block}
               else
                 name.raise "a type, a default value or a block should be given to declare a state parameter"
               end
        STATE_PARAMS << prop
      %}

      getter {{name}} {% if block %} {{block}} {% end %}
    end

    def initialize(**kwargs)
      {% for ivar in @type.instance_vars %}
        if val = kwargs[:{{ ivar.name }}]?
          @{{ ivar.name }} = val
        end
      {% end %}
    end

    def to_named_tuple
      {% begin %}
        NamedTuple.new(
          {% for ivar in @type.instance_vars %}
            {{ ivar.id }}: @{{ ivar.id }},
          {% end %}
        )
      {% end %}
    end

    def to_hash
      {% begin %}
        {
          {% for ivar in @type.instance_vars %}
            :{{ ivar.id }} => @{{ ivar.id }},
          {% end %}
        }
      {% end %}
    end

    def ==(other : self)
      {% for ivar in @type.instance_vars %}
        return false unless @{{ivar.id}} == other.{{ivar.id}}
      {% end %}
      true
    end

    def ==(other)
      false
    end

    def clone
      dup
    end

    protected def initialize_copy(other)
      {% for ivar in @type.instance_vars %}
        @{{ivar.id}} = other.@{{ivar.id}}.clone
      {% end %}
    end

    def hash(hasher)
      {% for ivar in @type.instance_vars %}
        hasher = @{{ivar.id}}.hash(hasher)
      {% end %}
      hasher
    end

    def inspect(io)
      io << "<" << self.class.name << ": "
      {% for ivar in @type.instance_vars %}
        io << {{ivar.id.stringify}} << '='
        io << @{{ivar.id}}.inspect(io)
        {% if ivar.id != @type.instance_vars.last.id %}
          io << ", "
        {% end %}
      {% end %}
      io << ">"
    end
  end

  module Stateful
    STATE_CHECKS = {state_complete: false}

    macro included
      reset_state_checks
      macro inherited
        reset_state_checks
      end
    end

    macro reset_state_checks
      STATE_CHECKS = {state_complete: false}
    end

    # The `state` macro defines a `State` subclass for the current `Model`
    # and expects a block to be passed.
    #
    # The given block is inserted inside the definition of the `State` subclass.
    #
    # See also `State#var`.
    # See also `State#parameter`.
    #
    # ### Example
    #
    # ```
    # class MyModel < AtomicModel
    #   state do
    #     parameter a = 0.234
    #     parameter b = 3.2
    #     var x = 0.0
    #     var y : Float64 { b }
    #   end
    # end
    # ```
    macro state(&block)
      {% if STATE_CHECKS[:state_complete] %}
        {% @type.raise("#{@type}::State have already been defined. Make sure to call the 'state' macro once for each model.") %}
      {% end %}

      {% ancestor = if @type.superclass.has_constant?(:State)
                      @type.superclass.name
                    else
                      "Quartz".id
                    end %}

      class State < {{ ancestor }}::State
        STATE_VARS = [] of Nil
        STATE_PARAMS = [] of Nil
        {{ yield }}

        # Returns a copy of `self` with all instance variables cloned.
        def clone
          clone = {{"#{@type}::State".id}}.allocate
          clone.initialize_copy(self)
          GC.add_finalizer(clone) if clone.responds_to?(:finalize)
          clone
        end
      end

      def_properties
      def_serialization
      {% STATE_CHECKS[:state_complete] = true %}
    end

    macro def_serialization
    end

    @state : Quartz::State = Quartz::State.new
    @initial_state : Quartz::State?

    def state
      @state
    end

    def state=(state : Quartz::State)
      @state = state
    end

    def initial_state=(state : Quartz::State)
      @initial_state = state
    end

    def initial_state
      (@initial_state || Quartz::State.new)
    end

    macro def_properties
      {% for ivar in @type.constant(:State).constant(:STATE_VARS) %}
        def {{ivar[:name]}}
          state.{{ivar[:name]}}
        end

        def {{ivar[:name]}}=({{ivar[:name]}})
          state.{{ivar[:name]}} = {{ivar[:name]}}
        end
      {% end %}

      {% for ivar in @type.constant(:State).constant(:STATE_PARAMS) %}
        def {{ivar[:name]}}
          state.{{ivar[:name]}}
        end
      {% end %}

      @state = State.new

      def state
        @state.as(State)
      end

      protected def initial_state
        (@initial_state || State.new).as(State)
      end

      def initial_state=(state : State)
        @initial_state = state
      end

      def initial_state=(state : Quartz::State)
        raise Quartz::InvalidStateError.new("#{self} expects an initial state of type " \
                                    "#{self.class}::State, not #{state.class}")
      end

      def state=(state : State)
        @state = state
      end

      def state=(state : Quartz::State)
        raise Quartz::InvalidStateError.new("#{self} expects a state of type " \
                                    "#{self.class}::State, not #{state.class}")
      end
    end
  end
end

module Quartz::DTSS
  # This class represent a PDTSS atomic model.
  abstract class AtomicModel < Model
    include Stateful
    include Coupleable
    include Observable
    include Verifiable

    class_property time_delta : Duration = Duration.new(1, Scale::BASE)

    private macro delta(length, unit = "base")
      self.time_delta = Quartz.duration({{length}}, {{unit}})
    end

    def self.precision_scale : Scale
      @@time_delta.precision
    end

    # Returns the precision associated with the class.
    def model_precision : Scale
      @@time_delta.precision
    end

    def time_delta : Duration
      @@time_delta
    end

    @bag : Hash(OutputPort, Array(Any)) = Hash(OutputPort, Array(Any)).new { |h, k|
      h[k] = Array(Any).new
    }

    def initialize(name)
      super(name)
    end

    def initialize(name, state)
      self.initial_state = state.clone
      self.state = state
      super(name)
    end

    abstract def transition(messages : Hash(InputPort, Array(Any)))

    # The output function (λ)
    #
    # Override this method to implement the appropriate behavior of
    # your model. See `#post` to send values to output ports.
    #
    # Example:
    # ```
    # def output
    #   post(42, :output)
    # end
    abstract def output

    # :nodoc:
    # Used internally by the simulator
    protected def __initialize_state__(processor)
      if @processor != processor
        raise InvalidProcessorError.new("trying to initialize state of model \"#{name}\" from an invalid processor")
      end

      if s = initial_state
        equals = s == self.state
        if !equals || (equals && s.same?(self.state))
          self.state = s.clone
        end
      end
    end

    def inspect(io)
      io << "<" << self.class.name << ": name=" << @name
      io << ", time_delta="
      time_delta.to_s(io)
      io << ">"
      nil
    end

    # Drops off an output *value* to the specified output *port*.
    #
    # Raises an `InvalidPortHostError` if the given port doesn't belong to this
    # model.
    protected def post(value : Any::Type, on : OutputPort)
      post(Any.new(value), on)
    end

    # Drops off an output *value* to the specified output *port*.
    #
    # Raises an `InvalidPortHostError` if the given port doesn't belong to this
    # model.
    # Raises an `NoSuchPortError` if the given output port doesn't exists.
    @[AlwaysInline]
    protected def post(value : Any::Type, on : Name)
      post(Any.new(value), self.output_port(on))
    end

    protected def post(value : Any, on : OutputPort)
      raise InvalidPortHostError.new("Given port doesn't belong to this model") if on.host != self
      @bag[on] << value
    end

    protected def post(value : Any, on : Name)
      post(value, self.output_port(on))
    end

    # :nodoc:
    #
    # Returns outgoing messages added by the DEVS lambda (λ) function for the
    # current state.
    #
    # This method calls the DEVS lambda (λ) function
    # Note: this method should be called only by the simulator.
    def fetch_output! : Hash(OutputPort, Array(Any))
      @bag.clear
      self.output
      @bag
    end
  end
end

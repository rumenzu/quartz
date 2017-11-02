require "../src/quartz"

class TrafficLight < Quartz::AtomicModel

  input :interrupt
  output :observed

  state_var phase : Symbol = :red

  def external_transition(messages)
    value = messages[input_ports[:interrupt]].first.as_sym
    case value
    when :to_manual
      case @phase
      when :red, :green, :orange
        @phase = :manual
      end
    when :to_autonomous
      @phase = :red if @phase == :manual
    end
  end

  def internal_transition
    @phase = case @phase
             when :red
               :green
             when :green
               :orange
             else # orange
               :red
             end
  end

  def output
    observed = case @phase
               when :red, :orange
                 :grey
               when :green
                 :orange
               end
    post observed, :observed
  end

  def time_advance
    case @phase
    when :red    then 60
    when :green  then 50
    when :orange then 10
    else # manual
      Quartz::INFINITY
    end
  end
end

class Policeman < Quartz::AtomicModel

  state_var phase : Symbol = :idle1

  output :alternate, :add_coupling, :remove_coupling

  def internal_transition
    @phase = case @phase
             when :idle1    then :working1
             when :working1 then :move1_2
             when :move1_2  then :idle2
             when :idle2    then :working2
             when :working2 then :move2_1
             else # move2_1
               :idle1
             end
  end

  def output
    case @phase
    when :idle1, :idle2
      post :to_manual, :alternate
    when :working1, :working2
      post :to_autonomous, :alternate
    else
      tl1 = Hash(Quartz::Type, Quartz::Type).new
      tl1[:src] = :policeman
      tl1[:dst] = :traffic_light1
      tl1[:src_port] = :alternate
      tl1[:dst_port] = :interrupt

      tl2 = tl1.dup
      tl2[:dst] = :traffic_light2

      if @phase == :move1_2
        post(tl1, :remove_coupling)
        post(tl2, :add_coupling)
      else # move2_1
        post(tl2, :remove_coupling)
        post(tl1, :add_coupling)
      end
    end
  end

  def time_advance
    case @phase
    when :idle1, :idle2
      50
    when :working1, :working2
      100
    when :move2_1, :move1_2
      150
    else
      Quartz::INFINITY
    end
  end
end

class Grapher
  include Quartz::ObserverWithInfo

  def initialize(model, @simulation : Quartz::Simulation)
    model.add_observer(self)
  end

  def update(model, info)
    if model.is_a?(Quartz::DSDE::Executive) && info
      kind = info[:kind]
      if kind == :internal || kind == :confluent
        @simulation.generate_graph("dyntrafficlight_#{@simulation.time.to_i}")
      end
    end
  end
end

class PortObserver
  include Quartz::ObserverWithInfo

  def initialize(port)
    port.add_observer(self)
  end

  def update(observable, info)
    if observable.is_a?(Quartz::Port) && info
      payload = info[:payload]
      puts "#{observable.host}@#{observable} sends '#{payload}' at #{observable.host.as(Quartz::AtomicModel).time}"
    end
  end
end

model = Quartz::DSDE::CoupledModel.new(:dynamic_crossroads)
tl1 = TrafficLight.new(:traffic_light1)
tl2 = TrafficLight.new(:traffic_light2)
policeman = Policeman.new(:policeman)

model << policeman
model << tl1
model << tl2

model.attach :add_coupling, to: :add_coupling, between: :policeman, and: :executive
model.attach :remove_coupling, to: :remove_coupling, between: :policeman, and: :executive
model.attach :alternate, to: :interrupt, between: :policeman, and: :traffic_light1

simulation = Quartz::Simulation.new(model, duration: 1000)
simulation.generate_graph("dyntrafficlight_0")

Grapher.new(model.executive, simulation)
PortObserver.new(tl1.output_port(:observed))
PortObserver.new(tl2.output_port(:observed))

simulation.simulate

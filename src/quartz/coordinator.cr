module Quartz
  # This class represent a simulator associated with an `CoupledModel`,
  # responsible to route events to proper children
  class Coordinator < Processor
    getter children

    @scheduler : EventSet(Processor)

    # Returns a new instance of Coordinator
    def initialize(model : Model, scheduler : Symbol)
      super(model)

      @children = Array(Processor).new
      @scheduler = EventSetFactory(Processor).new_event_set(scheduler)
      @scheduler_type = scheduler
      @influencees = Hash(Processor, Hash(Port,Array(Any))).new { |h,k| h[k] = Hash(Port,Array(Any)).new { |h2,k2| h2[k2] = Array(Any).new }}
      @synchronize = Set(Processor).new
      @parent_bag = Hash(Port,Array(Any)).new { |h,k| h[k] = Array(Any).new }
    end

    def inspect(io)
      io << "<" << self.class.name << "tn=" << @time_next.to_s(io)
      io << ", tl=" << @time_last.to_s(io)
      io << ", components=" << @children.size.to_s(io)
      io << ">"
      nil
    end

    # Append given *child* to `#children` list, ensuring that the child now has
    # *self* as parent.
    def <<(child : Processor)
      @children << child
      child.parent = self
      child
    end
    def add_child(child); self << child; end

    # Deletes the specified child from `#children` list
    def remove_child(child)
      @scheduler.delete(child)
      idx = @children.index { |x| child.equal?(x) }
      @children.delete_at(idx).parent = nil if idx
    end

    # Returns the minimum time next in all children
    def min_time_next
      @scheduler.next_priority
    end

    # Returns the maximum time last in all children
    def max_time_last
      max = 0
      i = 0
      while i < @children.size
        tl = @children[i].time_last
        max = tl if tl > max
        i += 1
      end
      max
    end

    def initialize_processor(time)
      min = Quartz::INFINITY
      selected = Array(Processor).new
      @children.each do |child|
        tn = child.initialize_processor(time)
        selected.push(child) if tn < Quartz::INFINITY
        min = tn if tn < min
      end

      @scheduler.clear
      list = @scheduler.is_a?(RescheduleEventSet) ? @children : selected
      list.each { |c| @scheduler << c }

      @time_last = max_time_last
      @time_next = min
    end

    def collect_outputs(time) : Hash(Port, Array(Any))
      if time != @time_next
        raise BadSynchronisationError.new("\ttime: #{time} should match time_next: #{@time_next}")
      end
      @time_last = time

      imm = if @scheduler.is_a?(RescheduleEventSet)
        @scheduler.peek_all(time)
      else
        @scheduler.delete_all(time)
      end

      coupled = @model.as(CoupledModel)
      @parent_bag.clear unless @parent_bag.empty?

      imm.each do |child|
        @synchronize << child.as(Processor)
        output = child.collect_outputs(time)

        output.each do |port, payload|
          if child.is_a?(Simulator)
            port.notify_observers(port, payload.as(Any))
          end

          # check internal coupling to get children who receive sub-bag of y
          coupled.each_internal_coupling(port) do |src, dst|
            receiver = dst.host.processor.not_nil!
            if child.is_a?(Coordinator)
              @influencees[receiver][dst].concat(payload.as(Array(Any)))
            else
              @influencees[receiver][dst] << payload.as(Any)
            end
            @synchronize << receiver
          end

          # check external coupling to form sub-bag of parent output
          coupled.each_output_coupling(port) do |src, dst|
            if child.is_a?(Coordinator)
              @parent_bag[dst].concat(payload.as(Array(Any)))
            else
              @parent_bag[dst] << (payload.as(Any))
            end
          end
        end
      end

      @parent_bag
    end

    def perform_transitions(time, bag)
      bag.each do |port, sub_bag|
        # check external input couplings to get children who receive sub-bag of y
        @model.as(CoupledModel).each_input_coupling(port) do |src, dst|
          receiver = dst.host.processor.not_nil!
          @influencees[receiver][dst].concat(sub_bag)
          @synchronize << receiver
        end
      end

      @synchronize.each do |receiver|
        sub_bag = @influencees[receiver]
        if @scheduler.is_a?(RescheduleEventSet)
          receiver.perform_transitions(time, sub_bag)
        else
          tn = receiver.time_next
          # before trying to cancel a receiver, test if time is not strictly
          # equal to its time_next. If true, it means that its model will
          # receiver either an internal_transition or a confluent transition,
          # and that the receiver is no longer in the scheduler
          @scheduler.delete(receiver) if tn < Quartz::INFINITY && time != tn
          tn = receiver.perform_transitions(time, sub_bag)
          @scheduler.push(receiver) if tn < Quartz::INFINITY
        end
        sub_bag.clear
      end
      @scheduler.reschedule! if @scheduler.is_a?(RescheduleEventSet)

      # NOTE: Set#clear is more time consuming (without --release flag)
      #@synchronize = Set(Processor).new
      @synchronize.clear

      @time_last = time
      @time_next = min_time_next
    end
  end
end
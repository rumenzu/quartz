module Quartz
  module MultiComponent
    class Simulator < Quartz::Simulator

      @components : Hash(Name, Component)
      @event_set : EventSet(Component)
      @imm : Array(Quartz::MultiComponent::Component)?

      @state_bags = Hash(Quartz::MultiComponent::Component,Array(Tuple(Name,Any))).new { |h,k| h[k] = Array(Tuple(Name,Any)).new }

      def initialize(model, simulation)
        super(model, simulation)
        sched_type = model.class.preferred_event_set? || simulation.default_scheduler
        @event_set = EventSetFactory(Component).new_event_set(sched_type)
        @components = model.components
      end

      @reac_count : UInt32 = 0u32

      def transition_stats
        {
          external: @ext_count,
          internal: @int_count,
          confluent: @con_count,
          reaction: @reac_count
        }
      end

      def initialize_processor(time)
        @reac_count = @int_count = @ext_count = @con_count = 0u32
        @event_set.clear

        @components.each_value do |component|
          component.notify_observers({ :transition => Any.new(:init) })
          component.time_last = component.time = time - component.elapsed
          component.time_next = component.time_last + component.time_advance

          case @event_set
          when RescheduleEventSet
            @event_set << component
          else
            if component.time_next < Quartz::INFINITY
              @event_set << component
            end
          end

          if (logger = Quartz.logger?) && logger.debug?
            logger.debug(String.build { |str|
              str << '\'' << component.name << "' initialized ("
              str << "tl: " << component.time_last << ", tn: "
              str << component.time_next << ')'
            })
          end

          component.notify_observers({ :transition => Any.new(:init) })
        end

        @time_last = time
        @time_next = min_time_next

        @time_next
      end

      # Returns the minimum time next in all components
      def min_time_next
        tn = Quartz::INFINITY
        if (obj = @event_set.peek?)
          tn = obj.time_next
        end
        tn
      end

      def collect_outputs(time)
        raise BadSynchronisationError.new("time: #{time} should match time_next: #{@time_next}") if time != @time_next

        @imm = if @event_set.is_a?(RescheduleEventSet)
          @event_set.peek_all(time)
        else
          @event_set.delete_all(time)
        end

        output_bag = Hash(OutPort,Array(Any)).new { |h,k| h[k] = Array(Any).new }

        @imm.not_nil!.each do |component|
          if sub_bag = component.output
            sub_bag.each do |k,v|
              output_bag[@model.ensure_output_port(k)] << v
            end
          end
        end

        output_bag
      end

      def perform_transitions(time, bag)
        if !(@time_last <= time && time <= @time_next)
          raise BadSynchronisationError.new("time: #{time} should be between time_last: #{@time_last} and time_next: #{@time_next}")
        end

        if time == @time_next && bag.empty?
          @int_count += @imm.not_nil!.size
          @imm.not_nil!.each do |component|
            component.internal_transition.try do |ps|
              ps.each do |k,v|
                @state_bags[@components[k]] << {component.name, v}
              end
            end
            if (logger = Quartz.logger?) && logger.debug?
              logger.debug(String.build { |str|
                str << '\'' << component.name << "': internal transition"
              })
            end
            component.notify_observers({ :transition => Any.new(:internal) })
          end
        elsif !bag.empty?
          @components.each do |component_name, component|
            # TODO test if component defined delta_ext
            kind = :unknown
            o = if time == @time_next && component.time_next == @time_next
              kind = :confluent
              @con_count += 1u32
              component.confluent_transition(bag)
            else
              kind = :external
              @ext_count += 1u32
              component.external_transition(bag)
            end

            o.try &.each do |k,v|
              @state_bags[@components[k]] << {component_name, v}
            end

            if (logger = Quartz.logger?) && logger.debug?
              logger.debug(String.build { |str|
                str << '\'' << component.name << "': " << kind << " transition"
              })
            end

            component.notify_observers({ :transition => Any.new(kind) })
          end
        end

        @state_bags.each do |component, states|
          if @event_set.is_a?(RescheduleEventSet)
            component.reaction_transition(states)
            component.time_last = component.time = time - component.elapsed
            component.time_next = component.time_last + component.time_advance
          elsif @event_set.is_a?(LadderQueue)
            tn = component.time_next
            is_in_scheduler = tn < Quartz::INFINITY && time != tn
            if is_in_scheduler
              if @event_set.delete(component)
                is_in_scheduler = false
              end
            end
            component.reaction_transition(states)
            component.time_last = component.time = time - component.elapsed
            new_tn = component.time_next = component.time_last + component.time_advance
            if new_tn < Quartz::INFINITY && (!is_in_scheduler || (new_tn > tn && is_in_scheduler))
              @event_set.push(component)
            end
          else
            tn = component.time_next
            @event_set.delete(component) if tn < Quartz::INFINITY && time != tn
            component.reaction_transition(states)
            component.time_last = component.time = time - component.elapsed
            tn = component.time_next = component.time_last + component.time_advance
            @event_set.push(component) if tn < Quartz::INFINITY
          end

          if (logger = Quartz.logger?) && logger.debug?
            logger.debug(String.build { |str|
              str << '\'' << component.name << "': reaction transition "
              str << "(tl: " << component.time_last << ", tn: "
              str << component.time_next << ')'
            })
          end

          component.notify_observers({ :transition => Any.new(:reaction) })
        end

        @reac_count += @state_bags.size
        @state_bags.clear

        @event_set.reschedule! if @event_set.is_a?(RescheduleEventSet)

        @model.as(MultiComponent::Model).notify_observers

        @time_last = time
        @time_next = min_time_next
      end

    end
  end
end

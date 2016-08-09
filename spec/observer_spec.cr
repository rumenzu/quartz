require "./spec_helper"

module MyObserver
  abstract def update;
end

class Foo
  include Observable(MyObserver)
end

class Bar
  include MyObserver
  getter calls : Int32 = 0

  def update
    @calls += 1
  end
end

class RaiseBar < Bar
  def update
    super
    raise "ohno"
  end
end

describe "Observable" do
  it "adds observers" do
    f = Foo.new
    f.add_observer(Bar.new)
    f.count_observers.should eq(1)
  end

  it "counts observers" do
    f = Foo.new
    f.add_observer(Bar.new)
    f.add_observer(Bar.new)
    b = Bar.new
    f.add_observer(b)
    f.count_observers.should eq(3)
    f.delete_observer(b)
    f.count_observers.should eq(2)
  end

  describe "delete observers" do
    it "is truthy when successful" do
      f = Foo.new
      b = Bar.new
      f.add_observer(b)
      f.count_observers.should eq(1)
      f.delete_observer(b).should be_true
      f.count_observers.should eq(0)
    end

    it "is falsy when not successful" do
      Foo.new.delete_observer(Bar.new).should be_false
    end
  end

  describe "notify" do
    it "calls #update for each observer" do
      f = Foo.new
      b = Bar.new
      f.add_observer(b)

      f.notify_observers
      b.calls.should eq(1)
      f.notify_observers
      b.calls.should eq(2)
    end

    it "automatically delete observers that raised" do
      f = Foo.new
      b = RaiseBar.new
      f.add_observer b

      f.notify_observers
      b.calls.should eq(1)
      f.notify_observers
      b.calls.should eq(1)

      f.delete_observer(b).should be_false
    end
  end
end

class MyPortObserver
  include PortObserver
  def update(port : Port, payload : Any)
  end
end

describe "Port" do
  describe "Observable" do
    it "raises when adding a PortObserver on wrong port" do
      atom = AtomicModel.new("am")
      coupled = CoupledModel.new("cm")

      aip = Port.new(atom, IOMode::Input, "aip")
      cip = Port.new(coupled, IOMode::Input, "cip")
      cop = Port.new(coupled, IOMode::Output, "cop")

      expect_raises UnobservablePortError do
        aip.add_observer(MyPortObserver.new)
      end
      expect_raises UnobservablePortError do
        cip.add_observer(MyPortObserver.new)
      end
      expect_raises UnobservablePortError do
        cop.add_observer(MyPortObserver.new)
      end
    end
  end
end

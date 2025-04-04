require_relative '../../spec_helper'
require_relative 'fixtures/classes'

# Why do we not test that finalizers are run by the GC? The documentation
# says that finalizers are never guaranteed to be run, so we can't
# spec that they are. On some implementations of Ruby the finalizers may
# run asynchronously, meaning that we can't predict when they'll run,
# even if they were guaranteed to do so. Even on MRI finalizers can be
# very unpredictable, due to conservative stack scanning and references
# left in unused memory.

describe "ObjectSpace.define_finalizer" do
  it "raises an ArgumentError if the action does not respond to call" do
    -> {
      ObjectSpace.define_finalizer(Object.new, mock("ObjectSpace.define_finalizer no #call"))
    }.should raise_error(ArgumentError)
  end

  it "accepts an object and a proc" do
    handler = -> id { id }
    ObjectSpace.define_finalizer(Object.new, handler).should == [0, handler]
  end

  it "accepts an object and a bound method" do
    handler = mock("callable")
    def handler.finalize(id) end
    finalize = handler.method(:finalize)
    ObjectSpace.define_finalizer(Object.new, finalize).should == [0, finalize]
  end

  it "accepts an object and a callable" do
    handler = mock("callable")
    def handler.call(id) end
    ObjectSpace.define_finalizer(Object.new, handler).should == [0, handler]
  end

  it "accepts an object and a block" do
    handler = -> id { id }
    ObjectSpace.define_finalizer(Object.new, &handler).should == [0, handler]
  end

  it "raises ArgumentError trying to define a finalizer on a non-reference" do
    -> {
      ObjectSpace.define_finalizer(:blah) { 1 }
    }.should raise_error(ArgumentError)
  end

  # see [ruby-core:24095]
  it "calls finalizer on process termination" do
    code = <<-RUBY
      def scoped
        Proc.new { puts "finalizer run" }
      end
      handler = scoped
      obj = +"Test"
      ObjectSpace.define_finalizer(obj, handler)
      exit 0
    RUBY

    ruby_exe(code, :args => "2>&1").should include("finalizer run\n")
  end

  it "warns if the finalizer has the object as the receiver" do
    code = <<-RUBY
      class CapturesSelf
        def initialize
          ObjectSpace.define_finalizer(self, proc {
            puts "finalizer run"
          })
        end
      end
      CapturesSelf.new
      exit 0
    RUBY

    ruby_exe(code, :args => "2>&1").should include("warning: finalizer references object to be finalized\n")
  end

  it "warns if the finalizer is a method bound to the receiver" do
    code = <<-RUBY
      class CapturesSelf
        def initialize
          ObjectSpace.define_finalizer(self, method(:finalize))
        end
        def finalize(id)
          puts "finalizer run"
        end
      end
      CapturesSelf.new
      exit 0
    RUBY

    ruby_exe(code, :args => "2>&1").should include("warning: finalizer references object to be finalized\n")
  end

  it "warns if the finalizer was a block in the receiver" do
    code = <<-RUBY
      class CapturesSelf
        def initialize
          ObjectSpace.define_finalizer(self) do
            puts "finalizer run"
          end
        end
      end
      CapturesSelf.new
      exit 0
    RUBY

    ruby_exe(code, :args => "2>&1").should include("warning: finalizer references object to be finalized\n")
  end

  it "calls a finalizer at exit even if it is self-referencing" do
    code = <<-RUBY
      obj = +"Test"
      handler = Proc.new { puts "finalizer run" }
      ObjectSpace.define_finalizer(obj, handler)
      exit 0
    RUBY

    ruby_exe(code).should include("finalizer run\n")
  end

  it "calls a finalizer at exit even if it is indirectly self-referencing" do
    code = <<-RUBY
      class CapturesSelf
        def initialize
          ObjectSpace.define_finalizer(self, finalizer(self))
        end
        def finalizer(zelf)
          proc do
            puts "finalizer run"
          end
        end
      end
      CapturesSelf.new
      exit 0
    RUBY

    ruby_exe(code, :args => "2>&1").should include("finalizer run\n")
  end

  it "calls a finalizer defined in a finalizer running at exit" do
    code = <<-RUBY
      obj = +"Test"
      handler = Proc.new do
        obj2 = +"Test"
        handler2 = Proc.new { puts "finalizer 2 run" }
        ObjectSpace.define_finalizer(obj2, handler2)
        exit 0
      end
      ObjectSpace.define_finalizer(obj, handler)
      exit 0
    RUBY

    ruby_exe(code, :args => "2>&1").should include("finalizer 2 run\n")
  end

  it "allows multiple finalizers with different 'callables' to be defined" do
    code = <<-'RUBY'
      obj = Object.new

      ObjectSpace.define_finalizer(obj, Proc.new { STDOUT.write "finalized1\n" })
      ObjectSpace.define_finalizer(obj, Proc.new { STDOUT.write "finalized2\n" })

      exit 0
    RUBY

    ruby_exe(code).lines.sort.should == ["finalized1\n", "finalized2\n"]
  end

  it "defines same finalizer only once" do
    code = <<~RUBY
      obj = Object.new
      p = proc { |id| print "ok" }
      ObjectSpace.define_finalizer(obj, p.dup)
      ObjectSpace.define_finalizer(obj, p.dup)
    RUBY

    ruby_exe(code).should == "ok"
  end

  it "returns the defined finalizer" do
    obj = Object.new
    p = proc { |id| }
    p2 = p.dup

    ret = ObjectSpace.define_finalizer(obj, p)
    ret.should == [0, p]
    ret[1].should.equal?(p)

    ret = ObjectSpace.define_finalizer(obj, p2)
    ret.should == [0, p]
    ret[1].should.equal?(p)
  end

  describe "when $VERBOSE is not nil" do
    it "warns if an exception is raised in finalizer" do
      code = <<-RUBY
        ObjectSpace.define_finalizer(Object.new) { raise "finalizing" }
      RUBY

      ruby_exe(code, args: "2>&1").should include("warning: Exception in finalizer", "finalizing")
    end
  end

  describe "when $VERBOSE is nil" do
    it "does not warn even if an exception is raised in finalizer" do
      code = <<-RUBY
        ObjectSpace.define_finalizer(Object.new) { raise "finalizing" }
      RUBY

      ruby_exe(code, args: "2>&1", options: "-W0").should == ""
    end
  end
end

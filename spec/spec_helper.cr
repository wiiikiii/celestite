require "spec"
require "../src/celestite"

ENV["CELESTITE"] = "test"

def get_logger
  Logger.new(STDOUT)
end

def run_spec_server(renderer, timeout = 15.seconds, output : IO? = IO::Memory.new)
  # def run_spec_server(renderer, timeout = 10.seconds, output : IO? = STDOUT, error = STDERR)
  channel = Channel(Process).new

  IO.pipe do |reader, writer|
    multi = IO::MultiWriter.new(output, writer)
    now = Time.monotonic
    renderer.logger = Logger.new(multi)
    spawn do
      begin
        proc = renderer.start_server
        channel.send(proc)
      rescue
        renderer.logger.error("Renderer failed to start.")
      end
    end

    begin
      proc = channel.receive
      loop do
        break if reader.gets =~ (/SSR renderer listening/)
        raise "Node server failed to start within timeout" if ((Time.monotonic - now) > timeout)
        raise "Node server failed" if proc.terminated?
        sleep 0.1
      end
      yield
    ensure
      if proc
        kill_renderer_procs(proc.pid)
      end
    end
  end
end

def kill_renderer_procs(pid : Int)
  begin
    io = IO::Memory.new
    # If pgrep is successful then this process has children
    if Process.run("pgrep", args: ["-P", pid.to_s], output: io).success?
      child_pids = io.to_s.split
      child_pids.each do |child_pid|
        kill_renderer_procs(child_pid.to_i)
      end
    end
    # No more children, so start killing from the bottom up
    Process.kill(Signal::TERM, pid.to_i)
  rescue ex
  end
end

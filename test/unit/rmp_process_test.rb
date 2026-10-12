# frozen_string_literal: true

require File.expand_path('../../test_helper', __FILE__)

# A converter command runs in a process group of its own, and a time limit stops
# the whole group: killing the direct child (the shell of a command string, or
# convert) would leave the processes it started (gs, soffice.bin) running.
class RmpProcessTest < ActiveSupport::TestCase
  RmpProcess = RedmineMorePreviews::Lib::RmpProcess
  ConverterTimeout = RedmineMorePreviews::Exceptions::ConverterTimeout

  def setup
    skip 'process groups are not available on Windows' if Redmine::Platform.mswin?
    @dir = Dir.mktmpdir('rmp-process')
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_status_of_a_command_is_returned
    assert RmpProcess.run('true', timeout: 5).success?
    assert_not RmpProcess.run('false', timeout: 5).success?
    assert RmpProcess.run(['sh', '-c', 'exit 0'], timeout: 5).success?
  end

  def test_a_command_is_stopped_at_the_time_limit
    pid = nil
    elapsed = measure do
      assert_raises(ConverterTimeout) { RmpProcess.run('sleep 30', timeout: 1) {|p| pid = p} }
    end
    assert_operator elapsed, :<, 5
    assert_group_gone pid
  end

  def test_processes_started_by_the_command_are_stopped_as_well
    child = File.join(@dir, 'child')
    pid = nil
    elapsed = measure do
      assert_raises(ConverterTimeout) do
        RmpProcess.run("sleep 30 & echo $! > #{child}; wait", timeout: 1) {|p| pid = p}
      end
    end
    assert_operator elapsed, :<, 5
    assert_group_gone pid
    assert_process_gone File.read(child).to_i
  end

  def test_a_command_ignoring_term_is_killed
    pid = nil
    elapsed = measure do
      assert_raises(ConverterTimeout) do
        RmpProcess.run("trap '' TERM; sleep 30", timeout: 1) {|p| pid = p}
      end
    end
    assert_operator elapsed, :<, 1 + RmpProcess::KILL_GRACE + 3
    assert_group_gone pid
  end

  def test_processes_left_behind_by_a_finished_command_are_killed
    child = File.join(@dir, 'child')
    status = nil
    elapsed = measure do
      status = RmpProcess.run("sleep 30 > /dev/null 2>&1 & echo $! > #{child}", timeout: 10)
    end
    assert status.success?
    assert_operator elapsed, :<, 5
    assert_process_gone File.read(child).to_i
  end

  # --- a block in a forked child ------------------------------------------------------

  def test_block_runs_in_a_child_and_leaves_files
    out = File.join(@dir, 'out')
    assert RmpProcess.fork(timeout: 5) { File.write(out, Process.pid.to_s) }
    assert_not_equal Process.pid, File.read(out).to_i
  end

  def test_block_that_raises_is_reported
    assert_not RmpProcess.fork(timeout: 5) { raise 'broken' }
  end

  def test_block_is_stopped_at_the_time_limit
    out = File.join(@dir, 'pid')
    elapsed = measure do
      assert_raises(ConverterTimeout) { RmpProcess.fork(timeout: 1) { File.write(out, Process.pid.to_s); sleep 30 } }
    end
    assert_operator elapsed, :<, 5
    assert_process_gone File.read(out).to_i
  end

  # a server's TERM handler must not run in the child: the child is stopped
  def test_child_ignores_the_signal_handlers_of_the_server
    handled = File.join(@dir, 'handled')
    old = Signal.trap('TERM') { File.write(handled, 'yes') }
    assert_raises(ConverterTimeout) { RmpProcess.fork(timeout: 1) { sleep 30 } }
    assert_not File.exist?(handled)
  ensure
    Signal.trap('TERM', old || 'DEFAULT')
  end

  def test_child_runs_out_of_memory_not_the_server
    skip 'the address space cannot be read' unless File.readable?('/proc/self/status')
    assert_not RmpProcess.fork(timeout: 30, memory: 64 * 1024 * 1024) { 'x' * (512 * 1024 * 1024) }
    assert RmpProcess.fork(timeout: 30, memory: 64 * 1024 * 1024) { 'x' * (8 * 1024 * 1024) }
  end

  # the address space is limited to twice the memory: a child within it is
  # stopped for its resident memory, which also counts the free memory it
  # inherited and reuses
  def test_child_is_stopped_for_its_resident_memory
    skip 'the memory cannot be read' unless File.readable?('/proc/self/status')
    elapsed = measure do
      assert_not RmpProcess.fork(timeout: 30, memory: 64 * 1024 * 1024) { kept = 'x' * (100 * 1024 * 1024); sleep 20; kept.size }
    end
    assert_operator elapsed, :<, 10
  end

  # the child's garbage collection writes to most of the heap it inherits,
  # copying pages that were resident already: that is no memory it takes
  def test_child_collecting_garbage_in_a_large_parent_is_not_stopped
    skip 'the memory cannot be read' unless File.readable?('/proc/self/statm')
    live = Array.new(500_000) { 'z' * 200 }
    assert RmpProcess.fork(timeout: 30, memory: 64 * 1024 * 1024) { GC.start; GC.start; sleep 1 }
    assert live.size
  end

  # a signal stops the child at once: Ruby's DEFAULT would raise
  # SignalException, which a rescue Exception in the block would take
  def test_signal_stops_the_child_at_once
    out = File.join(@dir, 'rescued')
    elapsed = measure do
      assert_raises(ConverterTimeout) do
        RmpProcess.fork(timeout: 1) do
          sleep 30
        rescue Exception
          File.write(out, 'yes')
          sleep 30
        end
      end
    end
    assert_not File.exist?(out)
    assert_operator elapsed, :<, 3
  end

  # the child leaves with exit!: no at_exit hook of the parent runs in it
  def test_child_runs_no_at_exit_hooks
    ran = File.join(@dir, 'at_exit')
    assert RmpProcess.fork(timeout: 5) { at_exit { File.write(ran, 'yes') } }
    assert_not File.exist?(ran)
  end

  private

  def measure
    start = RmpProcess.now
    yield
    RmpProcess.now - start
  end

  # a killed process whose parent was killed with it is reaped by init: until
  # then it is a zombie, which still counts as a member of the group
  def assert_group_gone(pgid)
    assert pgid
    deadline = RmpProcess.now + 2
    loop do
      running = group_members(pgid).reject {|state| state == 'Z' }
      return pass if running.empty?
      flunk "processes of group #{pgid} are still running" if RmpProcess.now > deadline
      sleep 0.05
    end
  end

  # states of the processes in the group, from /proc where it can be read
  def group_members(pgid)
    Process.kill(0, -pgid)
    return ['?'] unless File.directory?('/proc/self')
    Dir.glob('/proc/[0-9]*/stat').filter_map do |stat|
      fields = File.read(stat).split(') ').last.to_s.split(' ')
      fields[0] if fields[2].to_i == pgid
    rescue SystemCallError
      nil
    end
  rescue Errno::ESRCH
    []
  end

  # a killed process whose parent is gone is reaped by init: it may still show
  # up as a zombie for a moment
  def assert_process_gone(pid)
    assert_operator pid, :>, 0
    deadline = RmpProcess.now + 2
    loop do
      state = File.read("/proc/#{pid}/stat").split(') ').last.to_s[0] rescue nil
      return pass if state.nil? || state == 'Z'
      flunk "process #{pid} is still running" if RmpProcess.now > deadline
      sleep 0.05
    end
  end
end

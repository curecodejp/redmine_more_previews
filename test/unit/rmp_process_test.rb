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

  private

  def measure
    start = RmpProcess.now
    yield
    RmpProcess.now - start
  end

  def assert_group_gone(pgid)
    assert pgid
    assert_raises(Errno::ESRCH) { Process.kill(0, -pgid) }
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

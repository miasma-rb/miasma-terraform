require 'open3'
require 'stringio'
require 'fileutils'
require 'tempfile'

module MiasmaTerraform
  class Stack

    @@running_actions = []

    # Register action to be cleaned up at exit
    #
    # @param action [Action]
    # @return [NilClass]
    def self.register_action(action)
      unless(@@running_actions.include?(action))
        @@running_actions.push(action)
      end
      nil
    end

    # Deregister action from at exit cleanup
    #
    # @param action [Action]
    # @return [NilClass]
    def self.deregister_action(action)
      @@running_actions.delete(action)
      nil
    end

    # Wait for all actions to complete
    def self.cleanup_actions!
      @@running_actions.map(&:complete!)
      nil
    end

    # @return [Array<String>]
    def self.list(container)
      if(container.to_s.empty?)
        raise ArgumentError.new 'Container directory must be set!'
      end
      if(File.directory?(container))
        Dir.new(container).map do |entry|
          next if entry.start_with?('.')
          entry if File.directory?(File.join(container, entry))
        end.compact
      else
        []
      end
    end

    class Error < StandardError
      class Busy < Error; end
      class NotFound < Error; end
      class CommandFailed < Error; end
      class ValidateError < Error; end
    end

    REQUIRED_ATTRIBUTES = [:name, :container]

    class Action
      attr_reader :stdin, :waiter, :command

      # Create a new action to run
      #
      # @param command [String]
      # @param opts [Hash]
      # @return [self]
      def initialize(command, opts={})
        @command = command.dup.freeze
        @options = opts.to_smash
        @io_callbacks = []
        @complete_callbacks = []
        @start_callbacks = []
        @cached_output = Smash.new(
          :stdout => StringIO.new(''),
          :stderr => StringIO.new('')
        )
        if(@options.delete(:auto_start))
          start!
        end
      end

      # Start the process
      def start!
        opts = Hash[@options.map{|k,v| [k.to_sym,v]}]
        MiasmaTerraform::Stack.register_action(self)
        @stdin, @stdout, @stderr, @waiter = Open3.popen3(@command, **opts)
        @start_callbacks.each do |callback|
          callback.call(self)
        end
        unless(@io_callbacks.empty? && @complete_callbacks.empty?)
          manage_process!
        end
        true
      end

      # Wait for the process to complete
      #
      # @return [Process::Status]
      def complete!
        start! unless waiter
        if(@process_manager)
          @process_manager.join
        end
        result = waiter.value
        MiasmaTerraform::Stack.deregister_action(self)
        result
      end

      # @return [IO] stderr stream
      def stderr
        if(@stderr == :managed_io)
          @cached_output[:stderr]
        else
          @stderr
        end
      end

      # @return [IO] stdout stream
      def stdout
        if(@stdout == :managed_io)
          @cached_output[:stdout]
        else
          @stdout
        end
      end

      # Register a block to be run when process output
      # is received
      #
      # @yieldparam line [String] output line
      # @yieldparam type [Symbol] output type (:stdout or :stderr)
      def on_io(&block)
        @io_callbacks << block
      end

      # Register a block to be run when a process completes
      #
      # @yieldparam result [Process::Status]
      # @yieldparam self [Action]
      def on_complete(&block)
        @complete_callbacks << block
      end

      # Register a block to be run when a process starts
      #
      # @yieldparam self [Action]
      def on_start(&block)
        @start_callbacks << block
      end

      private

      # Start reader thread for handling managed process output
      def manage_process!
        unless(@process_manager)
          unless(@io_callbacks.empty?)
            io_stdout = @stdout
            io_stderr = @stderr
            @stdout = @stderr = :managed_io
          end
          Thread.abort_on_exception = true
          @process_manager = Thread.new do
            if(io_stdout && io_stderr)
              begin
                while(waiter.alive?)
                  IO.select([io_stdout, io_stderr])
                  [io_stdout, io_stderr].each do |io|
                    begin
                      content = io.read_nonblock(102400)
                      type = io == io_stdout ? :stdout : :stderr
                      @cached_output[type] << content
                      content = content.split("\n")
                      @io_callbacks.each do |callback|
                        content.each do |line|
                          callback.call(line, type)
                        end
                      end
                    rescue IO::WaitReadable, EOFError
                      # ignore
                    end
                  end
                end
              end
            end
            result = waiter.value
            @complete_callbacks.each do |callback|
              callback.call(result, self)
            end
            MiasmaTerraform::Stack.deregister_action(self)
            result
          end
        end
      end
    end

    attr_reader :actions
    attr_reader :directory
    attr_reader :container
    attr_reader :name
    attr_reader :bin

    def initialize(opts={})
      @options = opts.to_smash
      init!
      @actions = []
      @name = @options[:name]
      @container = @options[:container]
      @directory = File.join(container, name)
      @bin = @options.fetch(:bin, 'terraform')
    end

    # @return [TrueClass, FalseClass] stack currently exists
    def exists?
      File.directory?(directory)
    end

    # @return [TrueClass, FalseClass] stack is currently active
    def active?
      actions.any? do |action|
        action.waiter.alive?
      end
    end

    # Save the TF stack
    def save(opts={})
      save_opts = opts.to_smash
      type = exists? ? "update" : "create"
      lock_stack
      write_file(tf_path, save_opts[:template].to_json)
      write_file(tfvars_path, save_opts[:parameters].to_json)
      action = run_action('apply')
      store_events(action)
      action.on_start do |_|
        update_info do |info|
          info["state"] = "#{type}_in_progress"
          info
        end
      end
      action.on_complete do |status, this_action|
        update_info do |info|
          if(type == "create")
            info["created_at"] = (Time.now.to_f * 1000).floor
          end
          info["updated_at"] = (Time.now.to_f * 1000).floor
          info["state"] = status.success? ? "#{type}_complete" : "#{type}_failed"
          info
        end
        unlock_stack
      end
      action.start!
      true
    end

    # @return [Array<Hash>] resource list
    def resources
      must_exist do
        if(has_state?)
          action = run_action('state list', :auto_start)
          # wait for action to complete
          action.complete!
          successful_action(action) do
            resource_lines = action.stdout.read.split("\n").find_all do |line|
              line.match(/^[^\s]/)
            end
            resource_lines.map do |line|
              parts = line.split('.')
              resource_info = Smash.new(
                :type => parts[0],
                :name => parts[1],
                :status => 'UPDATE_COMPLETE'
              )
              action = run_action("state show #{line}", :auto_start)
              action.complete!
              successful_action(action) do
                info = Smash.new
                action.stdout.read.split("\n").each do |line|
                  parts = line.split('=').map(&:strip)
                  next if parts.size != 2
                  info[parts[0]] = parts[1]
                end
                resource_info[:physical_id] = info[:id] if info[:id]
              end
              resource_info
            end
          end
        else
          []
        end
      end
    end

    # @return [Array<Hash>] events list
    def events
      must_exist do
        load_info.fetch(:events, []).map do |item|
          new_item = item.dup
          parts = item[:resource_name].to_s.split('.')
          new_item[:resource_name] = parts[1]
          new_item[:resource_type] = parts[0]
          new_item
        end
      end
    end

    # @return [Hash] stack outputs
    def outputs
      must_exist do
        if(has_state?)
          action = run_action('output -json', :auto_start)
          action.complete!
          successful_action(action) do
            result = JSON.parse(action.stdout.read).to_smash.map do |key, info|
              [key, info[:value]]
            end
            Smash[result]
          end
        else
          Smash.new
        end
      end
    end

    # @return [String] current stack template
    def template
      must_exist do
        if(File.exists?(tf_path))
          File.read(tf_path)
        else
          "{}"
        end
      end
    end

    # @return [Hash] stack information
    def info
      must_exist do
        stack_data = load_info
        Smash.new(
          :id => name,
          :name => name,
          :state => stack_data[:state].to_s,
          :status => stack_data[:state].to_s.upcase,
          :updated_time => stack_data[:updated_at].to_s,
          :creation_time => stack_data[:created_at].to_s,
          :outputs => outputs
        )
      end
    end

    def validate(*_)
      raise NotImplementedError
    end

    # @return [TrueClass] destroy this stack
    def destroy!
      must_exist do
        lock_stack
        action = run_action('destroy -force')
        action.on_start do |_|
          update_info do |info|
            info[:state] = "delete_in_progress"
            info
          end
        end
        action.on_complete do |*_|
          unlock_stack
        end
        action.on_complete do |result, _|
          unless(result.success?)
            update_info do |info|
              info[:state] = "delete_failed"
              info
            end
          else
            FileUtils.rm_rf(directory)
          end
        end
        action.start!
      end
      true
    end

    protected

    # Start running a terraform process
    def run_action(cmd, auto_start=false)
      action = Action.new("#{bin} #{cmd} -no-color", :chdir => directory)
      action.on_start do |this_action|
        actions << this_action
      end
      action.on_complete do |_, this_action|
        actions.delete(this_action)
      end
      action.start! if auto_start
      action
    end

    # Validate stack exists before running block
    def must_exist(lock=false)
      if(exists?)
        if(lock)
          lock_stack do
            yield
          end
        else
          yield
        end
      else
        raise Error::NotFound.new "Stack does not exist `#{name}`"
      end
    end

    # Lock stack and run block
    def lock_stack
      FileUtils.mkdir_p(directory)
      @lock_file = File.open(lock_path, File::RDWR|File::CREAT)
      if(@lock_file.flock(File::LOCK_EX | File::LOCK_NB))
        if(block_given?)
          result = yield
          @lock_file.flock(File::LOCK_UN)
          @lock_file = nil
          result
        else
          true
        end
      else
        raise Error::Busy.new "Failed to aquire process lock for `#{name}`. Stack busy."
      end
    end

    # Unlock stack
    def unlock_stack
      if(@lock_file)
        @lock_file.flock(File::LOCK_UN)
        @lock_file = nil
        true
      else
        false
      end
    end

    # @return [String] path to template file
    def tf_path
      File.join(directory, 'main.tf')
    end

    # @return [String] path to variables file
    def tfvars_path
      File.join(directory, 'terraform.tfvars')
    end

    # @return [String] path to internal info file
    def info_path
      File.join(directory, 'info.json')
    end

    # @return [String] path to state file
    def state_path
      File.join(directory, 'terraform.tfstate')
    end

    # @return [TrueClass, FalseClass] stack has state
    def has_state?
      File.exists?(state_path)
    end

    # @return [String] path to lock file
    def lock_path
      File.join(directory, '.lck')
    end

    # @return [Smash] stack info
    def load_info
      if(File.exists?(info_path))
        result = JSON.parse(File.read(info_path)).to_smash
      else
        result = Smash.new
      end
      result[:created_at] = (Time.now.to_f * 1000).floor unless result[:created_at]
      result[:state] = 'unknown' unless result[:state]
      result
    end

    # @return [TrueClass]
    def update_info
      result = yield(load_info)
      write_file(info_path, result.to_json)
      true
    end

    # Raise exception if action was not completed successfully
    def successful_action(action=nil)
      action = current_action unless action
      status = action.complete!
      unless(status.success?)
        raise Error::CommandFailed.new "Command failed `#{action.command}` - #{action.stderr.read}"
      else
        yield
      end
    end

    # Store stack events generated by action
    #
    # @param action [Action]
    def store_events(action)
      action.on_io do |line, type|
        result = line.match(/^(\*\s+)?(?<name>[^\s]+): (?<status>.+)$/)
        if(result)
          resource_name = result["name"]
          resource_status = result["status"]
          event = Smash.new(
            :timestamp => (Time.now.to_f * 1000).floor,
            :resource_name => resource_name,
            :resource_status => resource_status,
            :id => SecureRandom.uuid
          )
          update_info do |info|
            info[:events] ||= []
            info[:events].unshift(event)
            info
          end
        end
      end
    end

    # Validate initialization
    def init!
      missing_attrs = REQUIRED_ATTRIBUTES.find_all do |key|
        !@options[key]
      end
      unless(missing_attrs.empty?)
        raise ArgumentError.new("Missing required attributes: #{missing_attrs.sort}")
      end
      # TODO: Add tf bin check
    end

    # File write helper that proxies via temporary file
    # to prevent corrupted writes on unexpected interrupt
    #
    # @param path [String] path to file
    # @param contents [String] contents of file
    # @return [TrueClass]
    def write_file(path, contents=nil)
      tmp_file = Tempfile.new('miasma')
      yield(tmp_file) if block_given?
      tmp_file.print(contents.to_s) if contents
      tmp_file.close
      FileUtils.mv(tmp_file.path, path)
      true
    end

  end
end

Kernel.at_exit{ MiasmaTerraform::Stack.cleanup_actions! }

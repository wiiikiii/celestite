##
# The Renderer class does the heavy lifting of actually calling the node process to render
##

require "logger"
require "http/client"

module Celestite
  module Renderer
    @component_dir : String?
    @routes_file : String?
    @port : Int32
    @template_dir : String?
    @default_template : String?
    @build_dir : String?
    @build_dir_public_path : String?
    @client : HTTP::Client

    getter node_process : Process?
    getter errors : IO::Memory

    ##
    # You can pass in a logger to keep things neat & tidy (like with Amber).
    ##

    property logger : Logger

    def initialize(@component_dir = nil, @routes_file = nil, @logger = Logger.new(nil), @port = 4000, @template_dir = nil, @default_template = nil, @build_dir = nil, @build_dir_public_path = nil)
      ENV["CELESTITE"] ||= "development"
      @logger.info "Renderer Initialized"
      @client = HTTP::Client.new("localhost", @port)
      @errors = IO::Memory.new
    end

    ##
    # Starts up a node server and spawns two fibers to pipe both output & errors.
    #
    # Fibers take a bit of getting used to, but for more details, see:
    # https://crystal-lang.org/docs/guides/concurrency.html
    #
    # The key here is that the while loop + gets, as per the docs:
    # "...talk directly with the Runtime Scheduler and the Event Loop..."
    # "...the standard library already takes care of doing all of this so you don't have to."
    ##

    def spawn_process
      node_process = Process.new(@process_command, shell: true, output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)

      spawn do
        while line = node_process.output.gets
          @logger.info(line)
        end
      end

      spawn do
        while line = node_process.error.gets
          @logger.error(line)
          @errors.puts(line)
        end
      end

      @logger.info "Renderer started as process #{node_process.pid}"
      return node_process
    end

    def start_server
      raise "Error - you must define component_dir to launch the node process" unless @component_dir

      @logger.info("Starting node server with command: #{@process_command}")

      while node_process = self.spawn_process
        sleep 2
        if node_process.terminated?
          @logger.info("Node process terminated.  Retrying...")
        else
          break
        end
      end

      @node_process = node_process
      return node_process
    end

    def kill_server
      proc = @node_process
      proc.kill if (proc && !proc.terminated?)
    end

    def render(path : String?, context : Celestite::Context? = Celestite::Context.new, template : String? = @default_template)
      @logger.info "Rendering #{path}"
      @logger.info "Context: #{context}"
      @logger.info "Template: #{template}"

      path_with_query = String.build do |q|
        q << path
        q << "?template=#{template}" if template
      end

      method = (context || template) ? "POST" : "GET"
      headers = (method == "POST") ? HTTP::Headers{"content-type" => "application/json"} : nil

      response = @client.exec(method: method, path: path_with_query, headers: headers, body: context.to_json).body
    end

    class Vue
      include Renderer

      def initialize(@component_dir = nil, @routes_file = nil, @logger = Logger.new(nil), @port = 4000, @template_dir = nil, @default_template = nil, @build_dir = nil, @build_dir_public_path = nil)
        super
        @process_command = String.build do |str|
          str << "NODE_PATH=. "
          str << "NODE_PORT=#{port} " if @port
          str << "VUE_TEMPLATE_DIR=#{template_dir} " if @template_dir
          str << "VUE_COMPONENT_DIR=#{component_dir} " if @component_dir
          str << "VUE_ROUTES_FILE=#{routes_file} " if @routes_file
          str << "VUE_CLIENT_BUILD_DIR=#{build_dir} " if @build_dir
          str << "VUE_CLIENT_BUILD_DIR_PUBLIC_PATH=#{build_dir_public_path} " if @build_dir_public_path

          if ENV["CELESTITE"] == "development"
            str << "yarn --cwd #{__DIR__}/../../ run dev -e \"json js\" "
            str << "--watch #{template_dir}" if @template_dir
          else
            str << "yarn --cwd #{__DIR__}/../../ run prod"
          end
        end
      end

      def start_server
        raise "Error - you must define routes_file to launch the node process for Vue" unless @routes_file
        super
      end
    end

    class Svelte
      include Renderer

      def initialize(@component_dir = nil, @routes_file = nil, @logger = Logger.new(nil), @port = 4000, @template_dir = nil, @default_template = nil, @build_dir = nil, @build_dir_public_path = nil)
        super
        @process_command = String.build do |str|
          if ENV["CELESTITE"] == "development"
            # NODE_PATH is modified here so that the sapper app can find 'polka' (a requirement of server.js) without needing to install it in the Amber app
            str << "NODE_PATH=#{__DIR__}/../../node_modules/ "
            str << "yarn --cwd #{__DIR__}/../../ run svelte-dev "
            str << "-p #{port} " if @port
            str << "--routes #{component_dir} " if @component_dir
            str << "--build-dir #{build_dir} " if @build_dir
            str << "--src src/svelte-scripts "
            str << "--output src/svelte-scripts/node_modules/@sapper "
          else
            # TODO:  Production string
          end
        end
      end
    end
  end
end

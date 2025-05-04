# github_daily_digest/lib/configuration.rb
require 'dotenv'
require 'active_support/all' # For parsing duration string
require 'optparse'

module GithubDailyDigest
  class Configuration
    attr_reader :github_token, :gemini_api_key, :github_org_name, :github_org_names,
                :log_level, :fetch_window_duration, :max_api_retries,
                :rate_limit_sleep_base, :time_since, :gemini_model,
                :json_only, :output_to_stdout, :help_requested,
                :output_formats, :output_destination, :concise_output,
                :use_graphql, :no_graphql, :specific_users,
                :html_theme, :html_title, :html_show_charts,
                :time_window_days

    def initialize(args = nil)
      Dotenv.load
      @json_only = true # Default to JSON only output
      @output_to_stdout = true # Default to stdout
      @gemini_model = ENV.fetch('GEMINI_MODEL', 'gemini-1.5-flash')
      @help_requested = false
      
      # Support multiple output formats - if env specifies a single format, convert to array
      output_format_env = ENV.fetch('OUTPUT_FORMAT', 'json').downcase
      @output_formats = output_format_env.include?(',') ? 
                      output_format_env.split(',').map(&:strip).map(&:downcase) : 
                      [output_format_env.downcase]
      
      @output_destination = ENV.fetch('OUTPUT_DESTINATION', 'stdout').downcase # 'stdout' or 'log'
      @concise_output = ENV.fetch('CONCISE_OUTPUT', 'true').downcase == 'true' # Whether to use concise output format (defaults to true)
      @use_graphql = ENV.fetch('USE_GRAPHQL', 'true').downcase == 'true' # Whether to use GraphQL API (defaults to true)
      @no_graphql = !@use_graphql # Inverse of use_graphql for easier API
      @specific_users = ENV.fetch('SPECIFIC_USERS', '').split(',').map(&:strip).reject(&:empty?) # Specific users to process
      
      # HTML-specific options
      @html_theme = ENV.fetch('HTML_THEME', 'default').downcase # 'default', 'dark', or 'light'
      @html_title = ENV.fetch('HTML_TITLE', nil) # Custom title for HTML output
      @html_show_charts = ENV.fetch('HTML_SHOW_CHARTS', 'true').downcase == 'true' # Whether to show charts in HTML output

      # Parse command line arguments if provided
      parse_command_line_args(args) if args

      # Early return if help is requested
      return if @help_requested

      # Load environment variables
      load_env_vars

      # Validate the configuration
      validate_config

      # Calculate the time window
      calculate_time_window
    end

    def help_text
      <<~HELP
        USAGE: github-daily-digest [options]

        GitHub Daily Digest generates insights about developer activity using GitHub API and Google's Gemini AI.

        Options:
          -h, --help                       Show this help message
          -t, --token TOKEN                GitHub API token (instead of GITHUB_TOKEN env var)
          -g, --gemini-key KEY             Gemini API key (instead of GEMINI_API_KEY env var)
          -o, --org NAME                   GitHub organization name(s) (instead of GITHUB_ORG_NAME env var)
                                           Multiple organizations can be comma-separated (e.g., 'org1,org2,org3')
          -u, --users USERNAMES            Specific users to process (comma-separated, e.g. 'user1,user2,user3')
                                           If not specified, all organization members will be processed
          -m, --model MODEL                Gemini model to use (default: gemini-1.5-flash)
          -w, --window DURATION            Time window for fetching data (e.g., '1.day', '12.hours')
          -v, --verbose                    Enable verbose output (instead of JSON-only)
          -l, --log-level LEVEL            Set log level (DEBUG, INFO, WARN, ERROR, FATAL)
          -f, --format FORMAT              Output format: json, markdown, html (default: json)
                                           html option generates a standalone web page with charts
          -d, --destination DEST           Output destination: stdout or log (default: stdout)
          -c, --[no-]concise               Use concise output format (overview + combined only, default: true)
          -q, --[no-]graphql               Use GraphQL API for better performance and data quality (default: true)
                                           Use --no-graphql to fall back to REST API
          
          HTML Output Options:
          --html-theme THEME               Theme for HTML output: default, dark, light (default: default)
          --html-title TITLE               Custom title for HTML output
          --[no-]html-charts               Include interactive charts in HTML output (default: true)

        Examples:
          github-daily-digest --token YOUR_TOKEN --gemini-key YOUR_KEY --org acme-inc
          github-daily-digest --window 2.days --verbose
          github-daily-digest --format markdown --destination log
          github-daily-digest --org "org1,org2,org3" --format markdown

        Environment variables can also be used instead of command-line options:
          GITHUB_TOKEN, GEMINI_API_KEY, GITHUB_ORG_NAME, GEMINI_MODEL, FETCH_WINDOW, LOG_LEVEL,
          OUTPUT_FORMAT, OUTPUT_DESTINATION, CONCISE_OUTPUT, USE_GRAPHQL
      HELP
    end

    # Check if we need to show help
    def help_requested?
      @help_requested
    end
    
    # Returns number of days in the configured time window
    def time_window_days
      if @fetch_window_duration
        # Handle ActiveSupport::Duration objects
        if @fetch_window_duration.respond_to?(:in_days)
          return @fetch_window_duration.in_days.to_i
        # Handle string durations like '7.days'
        elsif @fetch_window_duration.is_a?(String)
          match = @fetch_window_duration.match(/(\d+)\.days/)
          return match ? match[1].to_i : 7
        end
      end
      
      # Default to 7 days if fetch_window_duration not set or has unexpected type
      return 7
    end

    private

    def parse_command_line_args(args)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: github-daily-digest [options]"

        opts.on("-h", "--help", "Show help") do
          puts help_text
          @help_requested = true
        end

        opts.on("-t", "--token TOKEN", "GitHub API token") do |token|
          ENV['GITHUB_TOKEN'] = token
        end

        opts.on("-g", "--gemini-key KEY", "Gemini API key") do |key|
          ENV['GEMINI_API_KEY'] = key
        end

        opts.on("-o", "--org NAME", "GitHub organization name(s)") do |org|
          ENV['GITHUB_ORG_NAME'] = org
        end

        opts.on("-u", "--users USERNAMES", "Specific users to process (comma-separated)") do |users|
          @specific_users = users.split(',').map(&:strip).reject(&:empty?)
        end

        opts.on("-m", "--model MODEL", "Gemini model to use") do |model|
          @gemini_model = model
        end

        opts.on("-w", "--window DURATION", "Time window for fetching data (e.g., '1.day')") do |window|
          ENV['FETCH_WINDOW'] = window
        end

        opts.on("-v", "--verbose", "Enable verbose output (instead of JSON-only)") do
          @json_only = false
        end

        opts.on("-l", "--log-level LEVEL", "Set log level (DEBUG, INFO, WARN, ERROR, FATAL)") do |level|
          ENV['LOG_LEVEL'] = level
        end

        opts.on("-f", "--format FORMAT", "Output format (json, markdown, html)") do |format|
          @output_formats = format.downcase.split(',').map(&:strip).map(&:downcase)
          unless @output_formats.all? { |f| ['json', 'markdown', 'html'].include?(f) }
            puts "Error: Invalid output format(s) '#{format}'. Must be one or more of 'json', 'markdown', or 'html'."
            exit(1)
          end
        end

        opts.on("-d", "--destination DEST", "Output destination (stdout, log)") do |dest|
          @output_destination = dest.downcase
          unless ['stdout', 'log'].include?(@output_destination)
            puts "Error: Invalid output destination '#{dest}'. Must be 'stdout' or 'log'."
            exit(1)
          end
          @output_to_stdout = (@output_destination == 'stdout')
        end

        opts.on("-c", "--[no-]concise", "Use concise output format (overview + combined only)") do |concise|
          @concise_output = concise
        end

        opts.on("-q", "--[no-]graphql", "Use GraphQL API for better performance and data quality") do |graphql|
          @use_graphql = graphql
          @no_graphql = !graphql
        end
        
        # HTML-specific options
        opts.on("--html-theme THEME", "Theme for HTML output (default, dark, light)") do |theme|
          unless ['default', 'dark', 'light'].include?(theme.downcase)
            puts "Error: Invalid HTML theme '#{theme}'. Must be 'default', 'dark', or 'light'."
            exit(1)
          end
          @html_theme = theme.downcase
        end
        
        opts.on("--html-title TITLE", "Custom title for HTML output") do |title|
          @html_title = title
        end
        
        opts.on("--[no-]html-charts", "Include interactive charts in HTML output") do |show_charts|
          @html_show_charts = show_charts
        end
      end

      begin
        parser.parse!(args)
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        puts "Error: #{e.message}"
        puts parser
        exit(1)
      end
    end

    def load_env_vars
      @github_token = ENV['GITHUB_TOKEN']
      @gemini_api_key = ENV['GEMINI_API_KEY']
      @github_org_name = ENV['GITHUB_ORG_NAME']
      # Parse multiple organizations if provided (comma-separated)
      @github_org_names = @github_org_name.split(',').map(&:strip) if @github_org_name
      @log_level = ENV.fetch('LOG_LEVEL', 'INFO').upcase
      @fetch_window_duration_str = ENV.fetch('FETCH_WINDOW', '7.days')
      @max_api_retries = ENV.fetch('MAX_API_RETRIES', '3').to_i
      @rate_limit_sleep_base = ENV.fetch('RATE_LIMIT_SLEEP_BASE', '5').to_i
    end

    def validate_config
      return if @help_requested

      raise ArgumentError, "Missing required env var or option: GITHUB_TOKEN" unless @github_token
      raise ArgumentError, "Missing required env var or option: GEMINI_API_KEY" unless @gemini_api_key
      raise ArgumentError, "Missing required env var or option: GITHUB_ORG_NAME" unless @github_org_name
      validate_log_level
      parse_fetch_window
    end

    def validate_log_level
      valid_levels = %w[DEBUG INFO WARN ERROR FATAL]
      unless valid_levels.include?(@log_level)
        raise ArgumentError, "Invalid LOG_LEVEL: #{@log_level}. Must be one of #{valid_levels.join(', ')}"
      end
    end

    def parse_fetch_window
      # Attempt to parse the duration string (e.g., "1.day", "24.hours")
      @fetch_window_duration = eval(@fetch_window_duration_str) # Use eval carefully here
      unless @fetch_window_duration.is_a?(ActiveSupport::Duration)
         raise ArgumentError, "Invalid FETCH_WINDOW format: '#{@fetch_window_duration_str}'. Use ActiveSupport format (e.g., '1.day', '24.hours')."
      end
    rescue SyntaxError, NameError => e
        raise ArgumentError, "Error parsing FETCH_WINDOW: '#{@fetch_window_duration_str}'. #{e.message}"
    end

    def calculate_time_window
      @time_since = (@fetch_window_duration.ago).iso8601
    end
  end
end
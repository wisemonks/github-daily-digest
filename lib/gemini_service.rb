# github_daily_digest/lib/gemini_service.rb
require 'gemini-ai'
require 'json'
require 'pry'

module GithubDailyDigest
  class GeminiService
    # Default model - will be overridden by configuration
    DEFAULT_MODEL = 'gemini-2.5-flash-preview-04-17'  # Updated to a more widely available model
    # Keys expected in the Gemini JSON response
    EXPECTED_KEYS = %w[projects changes contribution_weights pr_count summary lines_changed].freeze

    attr_reader :client

    def initialize(api_key:, logger:, config:, github_graphql_service:)
      @logger = logger
      @config = config
      @github_graphql_service = github_graphql_service
      @model = config.gemini_model || DEFAULT_MODEL
      
      initialize_client(api_key, @model)
    rescue => e
      @logger.fatal("Failed to initialize Gemini client: #{e.message}")
      raise
    end
    
    def initialize_client(api_key, model)
      @logger.info("Initializing Gemini client with model: #{model}")
      
      @client = Gemini.new(
        credentials: {
          service: 'generative-language-api',  
          api_key: api_key
        },
        options: { 
          model: model
        }
      )
    end

    def analyze_activity(username:, commits:, review_count:, time_window_days:)
      # If there are no commits and no reviews, return empty data
      if commits.empty? && review_count == 0
        @logger.info("No activity found for #{username} to analyze.")
        return default_no_activity_report
      else
        @logger.debug("Found activity for #{username}: #{commits.size} commits in repositories: #{commits.map { |c| c[:repo] }.uniq.join(', ')}")
      end

      # Fetch actual code changes for a sample of commits to analyze
      commits_with_code = if @github_graphql_service
                          @github_graphql_service.fetch_commits_changes(commits)
                        else
                          @logger.debug("GraphQL service not available, proceeding without detailed commit changes")
                          commits
                        end
      
      # Make multiple attempts to analyze with Gemini, handle errors gracefully
      begin
        prompt = build_prompt(username, commits_with_code, review_count, time_window_days)
        # @logger.debug("Gemini Prompt for #{username}:\n#{prompt}") # Uncomment for debugging prompts

        response_text = execute_gemini_request(prompt, username)
        @logger.debug("Gemini response for #{username}: #{response_text}")
        
        if response_text
          return parse_and_validate_response(response_text, username)
        else
          # Failure occurred within execute_gemini_request (already logged)
          @logger.warn("Gemini analysis failed for #{username}, using fallback analysis.")
          return create_fallback_analysis(username, commits, review_count)
        end
      rescue => e
        @logger.error("Unexpected error analyzing #{username}'s activity: #{e.message}")
        @logger.warn("Using fallback analysis due to error.")
        return create_fallback_analysis(username, commits, review_count)
      end
    end

    def analyze_user_activity(username, user_data)
      @logger.info("Analyzing activity for user: #{username}")
      
      # Return early if no data
      return {} if user_data.nil? || user_data.empty?
      
      # Extract relevant data for analysis
      commits = user_data[:commits] || []
      reviews = user_data[:reviews] || []
      
      if commits.empty? && reviews.empty?
        @logger.info("No activity found for user: #{username}")
        return {}
      end
      
      review_count = reviews.size
      @logger.info("Fetching code changes for #{commits.size} of #{commits.size} commits")
      
      # Fetch detailed commit changes for all commits
      commit_changes = []
      all_files = []
      
      commits.each do |commit|
        # Skip commits without necessary information
        next unless commit[:repo_name] && commit[:sha]
        
        changes = @github_graphql_service.fetch_commit_changes(commit[:repo_name], commit[:sha])
        
        if changes && !changes.empty?
          commit_changes << changes
          
          # Collect files for language analysis
          if changes[:files] && !changes[:files].empty?
            all_files.concat(changes[:files])
          end
        end
      end
      
      @logger.info("Successfully fetched changes for #{commit_changes.size} commits")
      
      # Calculate language distribution
      language_stats = {}
      require_relative './language_analyzer'
      language_stats = LanguageAnalyzer.calculate_distribution(all_files)
      
      if commit_changes.empty?
        @logger.warn("No commit changes found for user: #{username}")
        
        # Create fallback analysis for users with review activity but no commit activity
        if review_count > 0
          fallback = create_fallback_analysis(username, [], review_count)
          fallback["language_distribution"] = {}
          return fallback
        end
        
        return {}
      end
      
      # Perform Gemini analysis
      begin
        # Package commit data for analysis
        analysis_data = {
          username: username,
          commits: commit_changes,
          reviews: review_count
        }
        
        analysis_result = analyze_activity(analysis_data[:username], analysis_data[:commits], analysis_data[:reviews], 30)
        
        # Add language distribution to the analysis result
        if analysis_result
          analysis_result["language_distribution"] = language_stats
        end
        
        # Return the completed analysis
        analysis_result || create_fallback_analysis(username, commit_changes, review_count)
      rescue => e
        @logger.error("Error analyzing user activity for #{username}: #{e.message}")
        @logger.error(e.backtrace.join("\n"))
        
        # Create fallback analysis in case of error
        fallback = create_fallback_analysis(username, commit_changes, review_count)
        fallback["language_distribution"] = language_stats
        fallback
      end
    end

    private

    def build_prompt(username, commits, review_count, time_window_days)
      total_lines_changed = 0
      total_additions = 0
      total_deletions = 0
      commits_with_stats = 0
      
      repos = Set.new
      commit_summary = ""
      
      # Process commits to extract statistics and build a summary
      commits.each do |commit|
        repos << commit[:repo]
        commit_date = Time.parse(commit[:date].to_s) rescue "Unknown"
        
        # Build commit message summary with additions/deletions if available
        stats_text = ""
        if commit[:stats]
          additions = commit[:stats][:additions] || 0
          deletions = commit[:stats][:deletions] || 0
          total_lines = additions.to_i + deletions.to_i
          
          total_lines_changed += total_lines
          total_additions += additions.to_i
          total_deletions += deletions.to_i
          commits_with_stats += 1
          
          stats_text = " (+#{additions}, -#{deletions})"
        end
        
        # Add commit message and stats
        message = commit[:message] || "No message"
        commit_summary << "* #{commit_date.strftime('%Y-%m-%d')}: [#{commit[:repo]}] #{message.strip.gsub(/\n+/, ' ')}#{stats_text}\n"
        
        # Add code changes if available (limited to avoid huge prompts)
        if commit[:code_changes] && !commit[:code_changes].empty? && commit[:code_changes][:files]
          commit_summary << "  Code changes:\n"
          commit[:code_changes][:files].each_with_index do |file, index|
            # Limit to first 3 files to avoid excessive prompt size
            break if index >= 3
            
            commit_summary << "    - #{file[:path]} (+#{file[:additions]}, -#{file[:deletions]})\n"
            
            # Include a limited snippet of the patch if available
            if file[:patch]
              # Limit the patch to 10 lines max
              patch_preview = file[:patch].split("\n")[0...10].join("\n")
              # Add an ellipsis if the patch was truncated
              patch_preview += "\n..." if file[:patch].split("\n").size > 10
              
              commit_summary << "```\n#{patch_preview}\n```\n"
            end
          end
          
          # Indicate if there were more files not shown
          if commit[:code_changes][:changed_files] && commit[:code_changes][:changed_files] > 3
            commit_summary << "    - ... and #{commit[:code_changes][:changed_files] - 3} more files\n"
          end
        elsif commit[:files] && commit[:files].to_i > 0
          # Include basic file count information if code changes couldn't be fetched
          commit_summary << "    - Changed #{commit[:files]} files (detailed changes not available)\n"
        end
      end
      
      # If no commits had detailed stats, try to estimate from commit count and changed files
      if commits_with_stats == 0 && !commits.empty?
        total_files_changed = commits.sum { |c| c[:files].to_i }
        estimated_lines = total_files_changed * 30  # Rough estimate: 30 lines per file
        
        if estimated_lines > 0
          total_lines_changed = estimated_lines
          total_additions = (estimated_lines * 0.7).to_i  # Assume 70% additions
          total_deletions = (estimated_lines * 0.3).to_i  # Assume 30% deletions
          commits_with_stats = commits.size
        end
      end
      
      # Calculate some derived metrics
      avg_lines = commits_with_stats > 0 ? (total_lines_changed.to_f / commits_with_stats).round : 0
      repos_joined = repos.to_a.join(", ")
      
      # Format the prompt
      <<~PROMPT
      You are an expert GitHub activity analyzer specializing in code complexity and engineering contribution analysis. Analyze the following GitHub user's activity:

      GitHub User: #{username}
      Time Period: Last #{time_window_days} days
      Total Commits: #{commits.size}
      PR Reviews: #{review_count}
      #{commits_with_stats > 0 ? "Total Lines Changed: #{total_lines_changed} (#{total_additions} additions, #{total_deletions} deletions)" : ""}
      #{commits_with_stats > 0 ? "Average Lines per Commit: #{avg_lines}" : ""}
      Repositories: #{repos_joined}

      Commit Details (with code samples where available):
      #{commit_summary}

      As a technical expert, carefully analyze:
      1. The actual code complexity and technical depth of the work based on the commit messages and code changes
      2. A weighted contribution score using the factors described below
      3. A brief summary that captures the technical essence of their contribution (max 100 characters)
      4. Key technical projects they worked on

      IMPORTANT INSTRUCTIONS:
      - Calculate weighted contribution score using these factors (each on a scale of 0-10):
        * Lines of code weight: Based on total volume of code changed
        * Complexity weight: Based on algorithmic/architectural complexity
        * Technical depth weight: Based on core vs peripheral system components
        * Scope weight: Based on number of repositories and projects involved
        * PR review weight: Based on code review contributions
      - Use these weights to allow fair comparison between users analyzed separately
      - Higher weights should be given for:
        * Large amounts of code changed
        * Complex algorithmic changes
        * Changes to core systems/architectural components
        * Work spanning multiple repositories
        * Significant code review contributions
      - Type of contribution affects weights:
        * Feature development: Higher complexity and technical depth weights
        * Bug fixes: Higher technical depth weight
        * Refactoring: Higher complexity weight
        * Documentation: Lower weights overall

      Return your analysis in this exact JSON format only, with no additional explanation:
      ```json
      {
        "projects": #{repos.empty? ? "[]" : repos.to_json},
        "changes": #{commits.size},
        "contribution_weights": {
          "lines_of_code": 5,
          "complexity": 6,
          "technical_depth": 5, 
          "scope": 4,
          "pr_reviews": 3
        },
        "pr_count": #{review_count},
        "summary": "Brief description of their work",
        "lines_changed": #{total_lines_changed}
      }
      ```
      PROMPT
    end

    def execute_gemini_request(prompt, username, retries = @config.max_api_retries)
      attempts = 0
      begin
        attempts += 1
        @logger.debug("Sending request to Gemini for #{username} (Attempt #{attempts}/#{retries})")
        @logger.debug("Using model: #{@model} with API key: #{@config.gemini_api_key.to_s[0..5]}...")
        
        generation_config = {
          temperature: 0.2     # Lower temp for consistency
        }
        
        @logger.debug("Request configuration: model=#{@model}")
        
        response = @client.generate_content({
          contents: { role: 'user', parts: { text: prompt } },
          generation_config: generation_config
        })
        
        # Extract text from the response - gemini-ai gem has a different structure
        @logger.debug("Response class: #{response.class}")
        @logger.debug("Response keys: #{response.keys}") if response.respond_to?(:keys)
        @logger.debug("Response inspect (truncated): #{response.inspect[0..300]}...")
        
        # More flexible response parsing based on structure
        raw_response = nil
        
        if response.is_a?(Hash) && response['candidates'] && response['candidates'][0] && 
           response['candidates'][0]['content'] && response['candidates'][0]['content']['parts'] && 
           response['candidates'][0]['content']['parts'][0]
          # Direct hash structure
          raw_response = response['candidates'][0]['content']['parts'][0]['text']
          @logger.debug("Parsed response using direct hash structure")
        elsif response.is_a?(Array) && response[0] && response[0]['candidates'] && 
              response[0]['candidates'][0] && response[0]['candidates'][0]['content'] && 
              response[0]['candidates'][0]['content']['parts'] && 
              response[0]['candidates'][0]['content']['parts'][0]
          # Array of events structure
          raw_response = response[0]['candidates'][0]['content']['parts'][0]['text']
          @logger.debug("Parsed response using array of events structure")
        else
          @logger.error("Gemini response for #{username} has unexpected structure: #{response.inspect}")
          raise StandardError, "Invalid Gemini response structure"
        end
    
        @logger.debug("Raw Gemini response for #{username}: #{raw_response.strip}")
        return raw_response
    
      rescue Faraday::ResourceNotFound => e
        @logger.error("Gemini API resource not found error: #{e.message}")
        @logger.error("This usually indicates an invalid API key, endpoint, or model name.")
        @logger.error("Current model: #{@model}")
        
        if attempts < retries
          # On 404, try with a different model
          if attempts == 1
            @logger.warn("Attempting with alternate model 'gemini-1.5-pro-latest'...")
            @model = 'gemini-1.5-pro-latest'
            initialize_client(@config.gemini_api_key, @model)
          elsif attempts == 2
            @logger.warn("Attempting with alternate model 'gemini-pro'...")
            @model = 'gemini-pro'
            initialize_client(@config.gemini_api_key, @model)
          end
          
          sleep_time = calculate_backoff(attempts)
          @logger.warn("Retrying Gemini request for #{username} in #{sleep_time}s...")
          sleep sleep_time
          retry
        end
        
        nil # Return nil to trigger fallback
      rescue Faraday::ConnectionFailed => e
        @logger.error("Gemini API connection error: #{e.message}")
        if attempts < retries
          sleep_time = calculate_backoff(attempts)
          @logger.warn("Retrying Gemini request for #{username} in #{sleep_time}s...")
          sleep sleep_time
          retry
        else
          @logger.error("Gemini connection failed after #{attempts} attempts.")
          nil
        end
      rescue => e
        @logger.error("General error during Gemini request for #{username}: #{e.class} - #{e.message}")
        if attempts < retries
           sleep_time = calculate_backoff(attempts)
           @logger.warn("Retrying Gemini request for #{username} due to unexpected error in #{sleep_time}s...")
           sleep sleep_time
           retry
        else
          @logger.error("Gemini request failed permanently for #{username} after #{attempts} attempts.")
          nil # Indicate failure
        end
      end
    end
    
    def parse_and_validate_response(response_text, username)
      # Find JSON in the response
      json_match = response_text.match(/```json\s*(.*?)\s*```/m) || response_text.match(/\{.*\}/m)
      
      if json_match
        begin
          json_str = json_match[1] || json_match[0]
          @logger.debug("Raw JSON from Gemini for #{username}: #{json_str}")
          
          result = JSON.parse(json_str)
          @logger.debug("Parsed Gemini response for #{username}: #{result.inspect}")
          
          # Validate required fields
          unless result["projects"] && result["changes"] && result["summary"]
            missing_fields = []
            missing_fields << "projects" unless result["projects"]
            missing_fields << "changes" unless result["changes"]
            missing_fields << "summary" unless result["summary"]
            
            @logger.warn("Invalid Gemini response format for #{username}: missing fields: #{missing_fields.join(', ')}")
            return fallback_result(username)
          end
          
          # Handle missing or malformed contribution_weights with defaults
          unless result["contribution_weights"].is_a?(Hash) && 
                 result["contribution_weights"].has_key?("lines_of_code") &&
                 result["contribution_weights"].has_key?("complexity") &&
                 result["contribution_weights"].has_key?("technical_depth") &&
                 result["contribution_weights"].has_key?("scope") &&
                 result["contribution_weights"].has_key?("pr_reviews")
            
            @logger.warn("Gemini response for #{username} is missing proper contribution_weights structure")
            
            # Create default weights based on other available data
            lines_changed = result["lines_changed"].to_i
            commits = result["changes"].to_i
            projects = result["projects"].is_a?(Array) ? result["projects"].size : 1
            pr_count = result["pr_count"].to_i || 0
            
            # Calculate weights using a 0-10 scale
            result["contribution_weights"] = {
              "lines_of_code" => calculate_loc_weight(lines_changed),
              "complexity" => calculate_complexity_weight(commits, projects),
              "technical_depth" => calculate_depth_weight(projects),
              "scope" => calculate_scope_weight(commits),
              "pr_reviews" => calculate_pr_weight(pr_count)
            }
            
            @logger.info("Created default contribution_weights for #{username}: #{result["contribution_weights"].inspect}")
          else
            # Convert existing weights from 0-100 scale to 0-10 scale
            if result["contribution_weights"].is_a?(Hash)
              @logger.debug("BEFORE conversion - contribution_weights for #{username}: #{result["contribution_weights"].inspect}")
              
              ["lines_of_code", "complexity", "technical_depth", "scope", "pr_reviews"].each do |key|
                value = result["contribution_weights"][key]
                if value.is_a?(String) || value.is_a?(Numeric)
                  # Convert to integer and scale down if the value is large
                  numeric_value = value.to_i
                  if numeric_value > 10
                    result["contribution_weights"][key] = (numeric_value / 10.0).ceil
                  else
                    result["contribution_weights"][key] = numeric_value
                  end
                end
              end
              
              @logger.debug("AFTER conversion - contribution_weights for #{username}: #{result["contribution_weights"].inspect}")
            end
          end
          
          # Calculate the total score
          total_score = 0
          if result["contribution_weights"].is_a?(Hash)
            ["lines_of_code", "complexity", "technical_depth", "scope", "pr_reviews"].each do |key|
              total_score += result["contribution_weights"][key].to_i
            end
          end
          result["total_score"] = total_score
          
          @logger.info("Successfully parsed Gemini response with contribution_weights for #{username}")
          @logger.info("FINAL contribution_weights for #{username}: #{result["contribution_weights"].inspect}")
          @logger.info("FINAL total_score for #{username}: #{result["total_score"]}")
          result
        rescue JSON::ParserError => e
          @logger.error("Failed to parse Gemini response for #{username}: #{e.message}")
          fallback_result(username)
        end
      else
        @logger.error("Could not extract JSON from Gemini response for #{username}")
        fallback_result(username)
      end
    end
    
    # Helper methods for calculating weights on a 0-10 scale
    def calculate_loc_weight(lines_changed)
      case lines_changed
      when 0..500 then 2
      when 501..2000 then 4
      when 2001..5000 then 6
      when 5001..10000 then 8
      else 10
      end
    end
    
    def calculate_complexity_weight(commits, repo_count)
      base = case commits
             when 0..5 then 2
             when 6..15 then 4
             when 16..30 then 6
             when 31..50 then 8
             else 10
             end
      
      # Adjust for multi-repo work (max 10)
      [base + (repo_count > 1 ? 2 : 0), 10].min
    end
    
    def calculate_depth_weight(project_count)
      case project_count
      when 0..1 then 2
      when 2..3 then 4
      when 4..5 then 6
      when 6..8 then 8
      else 10
      end
    end
    
    def calculate_scope_weight(commits)
      case commits
      when 0..5 then 2
      when 6..15 then 4
      when 16..30 then 6
      when 31..50 then 8
      else 10
      end
    end
    
    def calculate_pr_weight(pr_count)
      case pr_count
      when 0 then 0
      when 1..2 then 3
      when 3..5 then 5
      when 6..10 then 7
      else 10
      end
    end
    
    def fallback_result(username)
      {
        "projects" => [],
        "changes" => 0,
        "contribution_weights" => {
          "lines_of_code" => 5,
          "complexity" => 6,
          "technical_depth" => 5, 
          "scope" => 4,
          "pr_reviews" => 3
        },
        "pr_count" => 0,
        "summary" => "Could not analyze activity",
        "lines_changed" => 0
      }
    end
    
    def calculate_backoff(attempt)
      # Exponential backoff with jitter
      (@config.rate_limit_sleep_base ** attempt) + rand(0.0..1.0)
    end
    
    def default_no_activity_report
      {
        projects: [],
        changes: 0,
        contribution_weights: {
          lines_of_code: 0,
          complexity: 0,
          technical_depth: 0,
          scope: 0,
          pr_reviews: 0
        },
        pr_count: 0,
        summary: "No activity detected in the specified time window.",
        lines_changed: 0,
        _generated_by: "fallback_system"
      }
    end

    # Create a basic analysis when Gemini service fails
    def create_fallback_analysis(username, commits, review_count)
      @logger.debug("Creating fallback analysis for #{username}")
      
      total_lines_changed = 0
      total_additions = 0
      total_deletions = 0
      complexity_score = 1.0
      projects = Set.new
      
      # Process commits to extract statistics
      commits.each do |commit|
        projects << commit[:repo] if commit[:repo]
        
        # Calculate lines changed
        if commit[:stats]
          additions = commit[:stats][:additions].to_i
          deletions = commit[:stats][:deletions].to_i
          
          total_lines_changed += (additions + deletions)
          total_additions += additions
          total_deletions += deletions
        end
        
        # Simple heuristic for complexity - commits with more complex messages 
        # or with specific keywords tend to be more complex
        commit_message = commit[:message].to_s.downcase
        if commit_message.include?("refactor") || commit_message.include?("architecture") || 
           commit_message.include?("redesign") || commit_message.include?("performance")
          complexity_score *= 1.2
        end
      end
      
      # If no line data available, make an estimate based on commit count
      if total_lines_changed == 0 && commits.size > 0
        # Assume average 50 lines per commit if we don't have actual data
        total_lines_changed = commits.size * 50
        total_additions = total_lines_changed * 0.7 # Assume 70% additions
        total_deletions = total_lines_changed * 0.3 # Assume 30% deletions
      end
      
      # Calculate weights on 0-10 scale
      loc_weight = case total_lines_changed 
                   when 0..500 then 2
                   when 501..2000 then 4
                   when 2001..5000 then 6
                   when 5001..10000 then 8
                   else 10
                   end
                   
      complexity_weight = case complexity_score
                          when 0..1.1 then 2
                          when 1.1..1.3 then 4
                          when 1.3..1.5 then 6
                          when 1.5..2.0 then 8
                          else 10
                          end
                          
      technical_depth_weight = case projects.size
                               when 0..1 then 2
                               when 2..3 then 4
                               when 4..5 then 6
                               when 6..7 then 8
                               else 10
                               end
                               
      scope_weight = case commits.size
                    when 0..5 then 2
                    when 6..15 then 4
                    when 16..30 then 6
                    when 31..50 then 8
                    else 10
                    end
                    
      pr_weight = case review_count
                  when 0 then 0
                  when 1..2 then 3
                  when 3..5 then 5
                  when 6..10 then 7
                  else 10
                  end
      
      # Calculate total score
      total_score = loc_weight + complexity_weight + technical_depth_weight + scope_weight + pr_weight
      
      # Generate summary based on activity
      summary = if commits.empty? && review_count == 0
                  "No activity detected in the specified time window."
                elsif projects.size > 1
                  "Cross-repository development across #{projects.size} projects with #{commits.size} commits."
                elsif commits.size > 20
                  "Active development with #{commits.size} commits focusing on #{projects.first}."
                else
                  "Development activity on #{projects.first || 'repositories'}."
                end
      
      @logger.info("Generated fallback analysis for #{username}")
      
      {
        "projects" => projects.to_a,
        "changes" => commits.size,
        "contribution_weights" => {
          "lines_of_code" => loc_weight,
          "complexity" => complexity_weight,
          "technical_depth" => technical_depth_weight,
          "scope" => scope_weight,
          "pr_reviews" => pr_weight
        },
        "total_score" => total_score,
        "pr_count" => review_count,
        "summary" => summary,
        "lines_changed" => total_lines_changed,
        "_generated_by" => "fallback_system"
      }
    end
  end
end

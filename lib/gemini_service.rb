# github_daily_digest/lib/gemini_service.rb
require 'gemini-ai'
require 'json'

module GithubDailyDigest
  class GeminiService
    # Default model - will be overridden by configuration
    DEFAULT_MODEL = 'gemini-1.5-flash'  # Updated to a more widely available model
    # Keys expected in the Gemini JSON response
    EXPECTED_KEYS = %w[projects changes spent_time pr_count complexity_score summary lines_changed].freeze

    def initialize(api_key:, logger:, config:)
      @logger = logger
      @config = config
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
      @logger.debug("Analyzing activity for user: #{username} with Gemini.")
      @logger.debug("Activity details for #{username}: #{commits.size} commits, #{review_count} reviews in #{time_window_days} days")
      
      if commits.empty? && review_count == 0
        @logger.info("No activity found for #{username} to analyze.")
        return default_no_activity_report
      else
        @logger.debug("Found activity for #{username}: #{commits.size} commits in repositories: #{commits.map { |c| c[:repo] }.uniq.join(', ')}")
      end

      # Make multiple attempts to analyze with Gemini, handle errors gracefully
      begin
        prompt = build_prompt(username, commits, review_count, time_window_days)
        # @logger.debug("Gemini Prompt for #{username}:\n#{prompt}") # Uncomment for debugging prompts

        response_text = execute_gemini_request(prompt, username)

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

    private

    def build_prompt(username, commits, review_count, time_window_days)
      # Create a summary of commits with line change information if available
      commit_summary = commits.map do |c|
        line_changes = if c[:stats] && (c[:stats][:additions] || c[:stats][:deletions])
                         additions = c[:stats][:additions] || 0
                         deletions = c[:stats][:deletions] || 0
                         total = additions + deletions
                         "with #{additions} additions, #{deletions} deletions (#{total} total lines changed)"
                       else
                         ""
                       end
        
        "- Repository: #{c[:repo]}\n  Branch: #{c[:branch]}\n  Message: #{c[:message]}\n  Files changed: #{c[:files]}\n  #{line_changes}"
      end.join("\n\n")
      
      # Calculate estimated effort metrics
      total_lines_changed = 0
      total_additions = 0
      total_deletions = 0
      commits_with_stats = 0
      
      commits.each do |commit|
        if commit[:stats]
          additions = commit[:stats][:additions] || 0
          deletions = commit[:stats][:deletions] || 0
          
          total_additions += additions
          total_deletions += deletions
          total_lines_changed += (additions + deletions)
          commits_with_stats += 1
        end
      end
      
      # Add average lines per commit if available
      avg_lines = "unknown"
      if commits_with_stats > 0
        avg_lines = (total_lines_changed.to_f / commits_with_stats).round
      end
      
      # The repositories the user contributed to
      repos = commits.map { |c| c[:repo] }.uniq
      repos_joined = repos.empty? ? "None" : repos.join(', ')
      
      # Format the prompt
      <<~PROMPT
      You are an expert GitHub activity analyzer. Analyze the following GitHub user's activity:

      GitHub User: #{username}
      Time Period: Last #{time_window_days} days
      Total Commits: #{commits.size}
      PR Reviews: #{review_count}
      #{commits_with_stats > 0 ? "Total Lines Changed: #{total_lines_changed} (#{total_additions} additions, #{total_deletions} deletions)" : ""}
      #{commits_with_stats > 0 ? "Average Lines per Commit: #{avg_lines}" : ""}
      Repositories: #{repos_joined}

      Commit Details:
      #{commit_summary}

      Based on this information, please analyze:
      1. The complexity of the work on a scale of 0-100 (where 0 is trivial and 100 is extremely complex)
      2. The estimated time spent (use ranges like "1-3 hours", "3-6 hours", "6-12 hours", "12-24 hours", "24-36 hours", "36-60 hours", "60+ hours")
      3. A brief summary of their contribution (max 100 characters)
      4. Key projects they worked on

      IMPORTANT INSTRUCTIONS:
      - Factor in BOTH commits AND PR reviews when estimating time spent
      - Each PR review should be counted as approximately 30-60 minutes of work
      - Provide a numerical complexity score between 0-100
      - Higher complexity scores should be given for: many repositories, diverse work, complex messages, large changes
      - COMPLEXITY MUST VARY BETWEEN USERS - do not assign the same score to everyone
      - Time estimates should be influenced by complexity score - higher complexity = more time per commit
      - Use the following guidelines for complexity scores:
        * 0-30: Simple changes (typo fixes, documentation, minor UI tweaks)
        * 31-60: Moderate complexity (bug fixes, small features, refactoring)
        * 61-80: High complexity (new features, complex bug fixes, performance improvements)
        * 81-100: Very high complexity (architecture changes, major new systems, complex algorithms)

      Return your analysis in this exact JSON format only, with no additional explanation:
      ```json
      {
        "projects": #{repos.empty? ? "[]" : repos.to_json},
        "changes": #{commits.size},
        "spent_time": "estimated time range",
        "pr_count": #{review_count},
        "complexity_score": 75, // Replace with actual score between 0-100
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
      cleaned_response = response_text.strip.gsub(/^```json\s*/, '').gsub(/\s*```$/, '')
      begin
        json_response = JSON.parse(cleaned_response)
    
        # Validate keys
        missing_keys = EXPECTED_KEYS - json_response.keys
        unless missing_keys.empty?
          @logger.error("Gemini response for #{username} missing required keys: #{missing_keys.join(', ')}. Raw: #{cleaned_response}")
          # Return partial data with error or a full error structure
          return { error: "Gemini response structure invalid (missing keys)", data: json_response }
        end
    
        @logger.debug("Successfully parsed Gemini response for #{username}.")
        return json_response # Return the valid hash
    
      rescue JSON::ParserError => json_e
        @logger.error("Failed to parse Gemini JSON response for #{username}. Error: #{json_e.message}. Raw: #{cleaned_response}")
        return { error: "Gemini response was not valid JSON", raw_response: cleaned_response }
      end
    end
    
    def calculate_backoff(attempt)
      # Exponential backoff with jitter
      (@config.rate_limit_sleep_base ** attempt) + rand(0.0..1.0)
    end
    
    def default_no_activity_report
      {
        projects: [],
        changes: 0,
        spent_time: "0 hours",
        pr_count: 0,
        complexity_score: 0,
        summary: "No activity detected in the specified time window.",
        lines_changed: 0,
        _generated_by: "fallback_system"
      }
    end

    # Create a basic analysis when Gemini service fails
    def create_fallback_analysis(username, commits, review_count)
      @logger.info("Creating fallback analysis for #{username}")
      
      # Extract basic data from commits
      projects = commits.map { |c| c[:repo] }.uniq
      
      # Calculate total lines changed if stats are available
      total_lines_changed = 0
      commits_with_stats = 0
      
      commits.each do |commit|
        if commit[:stats] && (commit[:stats][:total] || (commit[:stats][:additions] || 0) + (commit[:stats][:deletions] || 0) > 0)
          total = commit[:stats][:total] || (commit[:stats][:additions] || 0) + (commit[:stats][:deletions] || 0)
          total_lines_changed += total
          commits_with_stats += 1
        end
      end
      
      # Calculate average lines per commit for commits with stats
      avg_lines_per_commit = commits_with_stats > 0 ? (total_lines_changed.to_f / commits_with_stats).round : 20 # Default to 20 if no stats
      
      # Estimate total lines changed for all commits
      estimated_total_lines = avg_lines_per_commit * commits.count
      
      # Add equivalent lines for PR reviews (200 lines per review as a more significant contribution)
      estimated_total_lines += review_count * 200 if review_count
      
      # Calculate complexity score (0-100) based on number of projects, commits, and lines
      complexity_score = 0
      complexity_score += [projects.size * 10, 50].min # Up to 50 points for project diversity
      complexity_score += [commits.size * 2, 30].min   # Up to 30 points for commit volume
      complexity_score += [estimated_total_lines / 100, 20].min # Up to 20 points for code volume
      
      # Determine time spent based on estimated lines and complexity
      spent_time = if estimated_total_lines > 3000
                     "60+ hours"
                   elsif estimated_total_lines > 1000
                     "36-60 hours"
                   elsif estimated_total_lines > 300
                     "12-36 hours" 
                   elsif estimated_total_lines > 100
                     "6-12 hours"
                   elsif estimated_total_lines > 0
                     "1-3 hours"
                   else
                     "0 hours"
                   end
      
      # Form a simple summary based on the available data
      activity_level = if commits.empty? && review_count == 0
                         "no"
                       elsif commits.size > 20 || review_count > 5
                         "significant"
                       else
                         "moderate"
                       end
      
      # Create the summary text - max 100 chars as expected by the Gemini API
      summary = if commits.empty? && review_count == 0
                   "No activity detected for this user during the time period."
                 else
                   project_str = projects.size == 1 ? "1 repo" : "#{projects.size} repos" 
                   commit_str = commits.size == 1 ? "1 commit" : "#{commits.size} commits"
                   
                   "Made #{commit_str} across #{project_str}" + (review_count > 0 ? ", reviewed #{review_count} PRs" : "")
                 end
      
      # Ensure the summary is not too long (100 chars max)
      summary = summary[0...97] + "..." if summary.length > 100
      
      # Ensure all values are in the correct format
      {
        projects: projects,
        changes: commits.size.to_i,  # Ensure this is an integer
        spent_time: spent_time,
        pr_count: review_count.to_i, # Ensure this is an integer
        complexity_score: complexity_score.to_i, # Ensure this is an integer 
        summary: summary,
        lines_changed: estimated_total_lines.to_i, # Ensure this is an integer
        _generated_by: "fallback_system"
      }
    end
  end
end

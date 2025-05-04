# github_daily_digest/lib/daily_digest_runner.rb
require 'json'
require 'time'
require 'set'

# Require dependent classes (adjust paths if structure differs)
require_relative 'configuration'
require_relative 'github_service'
require_relative 'github_graphql_service'
require_relative 'activity_analyzer'
require_relative 'gemini_service'
require_relative 'output_formatter'
require_relative 'html_formatter'

module GithubDailyDigest
  class DailyDigestRunner
    # Delay between processing users
    USER_PROCESSING_DELAY = 1 # second

    def initialize(config:, logger:, use_graphql: nil)
      @config = config
      @logger = logger
      
      # Default to using GraphQL API unless explicitly disabled
      @use_graphql = use_graphql.nil? ? (!config.no_graphql) : use_graphql
      
      # Initialize REST API service (always needed for some operations)
      @github_service = GithubService.new(token: config.github_token, logger: @logger, config: config)
      
      # Initialize GraphQL service if enabled
      if @use_graphql
        @logger.info("Initializing GitHub GraphQL service")
        begin
          @github_graphql_service = GithubGraphQLService.new(token: config.github_token, logger: @logger, config: config)
          # Verify GraphQL authentication
          @github_graphql_service.verify_authentication
          @logger.info("GitHub GraphQL service successfully initialized")
        rescue => e
          @logger.warn("Failed to initialize GraphQL service: #{e.message}. Falling back to REST API.")
          @use_graphql = false
          @github_graphql_service = nil
        end
      end
      
      @gemini_service = GeminiService.new(
        api_key: config.gemini_api_key, 
        logger: @logger, 
        config: config,
        github_graphql_service: @github_graphql_service
      )
      @analyzer = ActivityAnalyzer.new(gemini_service: @gemini_service, github_graphql_service: @github_graphql_service, logger: @logger)
    end

    def run
      @logger.info("Starting GitHub Daily Digest")
      @logger.debug("Debug mode enabled with log level: #{@logger.level}")
      
      # Verify GitHub authentication via the client
      @logger.info("Verifying GitHub authentication...")
      begin
        user = @github_service.get_current_user
        if user
          @logger.info("Authenticated to GitHub as user: #{user[:login]}")
        else
          @logger.fatal("GitHub authentication failed: Unable to get user information")
          return false
        end
      rescue => e
        @logger.fatal("GitHub authentication failed: #{e.message}")
        @logger.debug("Authentication error backtrace: #{e.backtrace.join("\n")}")
        return false
      end
      
      # Log where results will be output
      if @config.output_to_stdout
        @logger.info("Results will be output directly")
      else
        @logger.info("Results will be saved to file")
      end
      
      # Process all organization data
      @logger.info("Starting daily digest process for organization(s): #{@config.github_org_name}")
      @logger.info("Fetching data since: #{@config.time_since}")
      @logger.info("Using GraphQL API: #{@use_graphql ? 'Yes' : 'No'}")
      @logger.info("Output format: #{@config.output_formats}")
      
      begin
        results_by_org = process_organizations
        
        # Process results into desired format (JSON, Markdown, or HTML)
        @logger.info("Processing results into #{@config.output_formats} format")
        result = process_results(results_by_org, @config.specific_users)
        
        @logger.info("Execution finished successfully.")
        return true
      rescue => e
        @logger.fatal("Error during execution: #{e.message}")
        @logger.error("Error backtrace: #{e.backtrace.join("\n")}")
        return false
      end
    rescue => e
      @logger.fatal("Unhandled error: #{e.message}")
      @logger.error("Unhandled error backtrace: #{e.backtrace.join("\n")}")
      return false
    end

    # Process a single organization
    def process_organization(org_name)
      @logger.info("Processing organization #{org_name}")
      
      # Set current organization in config and GraphQL service
      original_org_name = @config.github_org_name
      @config.instance_variable_set(:@github_org_name, org_name)
      @github_graphql_service.instance_variable_set(:@current_org_name, org_name) if @github_graphql_service
      
      begin
        # Process based on API type and user selection
        if @config.specific_users && !@config.specific_users.empty?
          # If specific users were provided, process just those
          if @use_graphql
            org_results = process_specific_users_for_organization(org_name)
          else
            @logger.warn("Specific user processing is currently only supported with GraphQL API")
            org_results = process_organization_with_rest(org_name)
          end
        else
          # Process all users in the organization
          if @use_graphql
            org_results = process_organization_with_graphql(org_name)
          else
            org_results = process_organization_with_rest(org_name)
          end
        end
        
        return org_results
      ensure
        # Restore original org name in config
        @config.instance_variable_set(:@github_org_name, original_org_name)
      end
    end

    # Process all organizations and return combined results
    def process_organizations
      org_names = @config.github_org_names
      
      # Initialize results hash
      all_org_results = {}
      
      # Process each organization separately
      org_names.each_with_index do |org_name, index|
        @logger.info("===== Processing organization: #{org_name} (#{index+1}/#{org_names.size}) =====")
        
        org_results = process_organization(org_name)
        
        # Add results to the combined hash, using org name as namespace
        all_org_results[org_name] = org_results
      end
      
      @logger.info("Daily digest process completed successfully for all organizations.")
      
      # Save results to file
      save_results(all_org_results)
      
      return all_org_results
    end

    # Refactored method to process a user's activity data and analyze it
    def process_user_activity(username, activity_data, time_window_days)
      @logger.info("--------------------------------------------------")
      @logger.info("Processing user: #{username}")
      
      # Analyze the activity
      analysis = @analyzer.analyze(
        username: username, 
        activity_data: activity_data,
        time_window_days: time_window_days
      )
      return analysis
    end
    
    # Common time window calculation used in multiple places
    def calculate_time_window_days
      ((Time.now - Time.parse(@config.time_since)) / 86400).round
    end

    def process_organization_with_graphql(org_name)
      @logger.info("Processing organization #{org_name} using GraphQL API")
      
      # 1. Fetch commits from all branches across all active repos via GraphQL
      all_commits_data = @github_graphql_service.fetch_all_branch_commits(org_name, @config.time_since)
      
      # 2. Map all commits to their respective users
      user_commits_map = @github_graphql_service.map_commits_to_users(all_commits_data)
      
      # 3. Get all PR review data
      user_reviews_map = @github_graphql_service.fetch_pull_request_reviews(org_name, @config.time_since)
      
      # 4. Get repository statistics
      repo_stats = @github_graphql_service.fetch_repository_stats(org_name)
      
      # 5. Get trending repositories
      trending_repos = @github_graphql_service.fetch_trending_repositories(org_name, @config.time_since)
      
      # 6. Process all relevant users
      all_user_analysis = {}
      time_window_days = calculate_time_window_days
      
      # Get all active users (those with commits or reviews)
      active_users = (user_commits_map.keys + user_reviews_map.keys).uniq
      
      # Filter by specific users if provided
      if @config.specific_users && !@config.specific_users.empty?
        original_count = active_users.size
        active_users = active_users.select do |user|
          @config.specific_users.any? { |specific_user| specific_user.downcase == user.downcase }
        end
        @logger.info("Filtered active users from #{original_count} to #{active_users.size} based on specified users")
      end
      
      # Process users with activity
      active_users.each do |username|
        activity_data = {
          commits: user_commits_map[username] || [],
          review_count: user_reviews_map[username]&.size || 0
        }
        
        all_user_analysis[username] = process_user_activity(username, activity_data, time_window_days)
      end
      
      # Add metadata to be used by the formatter
      all_user_analysis[:_meta] = {
        api_type: "GitHub GraphQL API",
        repo_stats: repo_stats,
        trending_repos: trending_repos,
        generated_at: Time.now
      }
      
      @logger.info("==================================================")
      @logger.info("Finished processing all users for organization: #{org_name}")
      
      # Return the results for this organization
      return all_user_analysis
    end

    def process_organization_with_rest(org_name)
      @logger.info("Processing organization #{org_name} using REST API")
      
      # 1. Fetch all organization members
      member_logins = @github_service.fetch_members(org_name)
      
      if member_logins.empty?
        @logger.warn("No members found or error occurred fetching members for #{org_name}.")
        return {}
      end
      
      # Filter members if specific users were provided
      if @config.specific_users && !@config.specific_users.empty?
        original_count = member_logins.size
        # Filter case-insensitively
        member_logins = member_logins.select do |member|
          @config.specific_users.any? { |user| user.downcase == member.downcase }
        end
        @logger.info("Filtered members from #{original_count} to #{member_logins.size} based on specified users")
      end
      
      # 2. Get all active repositories during the time window with their commits
      active_repos = @github_service.fetch_active_repos(org_name, @config.time_since)
      
      # 3. Map all commits to their respective users (much more efficient)
      user_commits_map = @github_service.map_commits_to_users(active_repos)
      
      # Process all relevant users (members who had commits + members without commits)
      all_user_analysis = {}
      time_window_days = calculate_time_window_days
      
      # First process users with commits
      user_commits_map.each do |username, commits|
        # Skip users who aren't members of the organization
        next unless member_logins.include?(username)
        
        activity_data = {
          commits: commits,
          review_count: @github_service.search_user_reviews(username, org_name, @config.time_since)
        }
        
        all_user_analysis[username] = process_user_activity(username, activity_data, time_window_days)
      end
      
      # Now process remaining members (those without commits)
      member_logins.each do |username|
        next if all_user_analysis[username]
        
        activity_data = {
          commits: [],
          review_count: @github_service.search_user_reviews(username, org_name, @config.time_since)
        }
        
        all_user_analysis[username] = process_user_activity(username, activity_data, time_window_days)
      end
      
      # Try to get some basic repo stats for consistent output format with GraphQL
      repo_stats = active_repos.map do |repo, commits|
        {
          name: repo.split('/').last,
          path: repo,
          total_commits: commits.size,
          open_prs: 0  # We don't have this info in REST mode without extra API calls
        }
      end
      
      # Add metadata to be used by the formatter
      all_user_analysis[:_meta] = {
        api_type: "GitHub REST API",
        repo_stats: repo_stats,
        trending_repos: [],  # Not available in REST mode
        generated_at: Time.now
      }
      
      @logger.info("==================================================")
      @logger.info("Finished processing all users for organization: #{org_name}")
      
      # Return the results for this organization
      return all_user_analysis
    end

    # Process specific users for an organization using the same approach as process_organization_with_graphql
    def process_specific_users_for_organization(org_name)
      @logger.info("Processing specific users for organization #{org_name}")
      
      # Save current org name in config
      original_org_name = @config.github_org_name
      @config.instance_variable_set(:@github_org_name, org_name)
      
      # Use the same logic as process_organization_with_graphql but with specific users
      # 1. Fetch commits from all branches across all active repos via GraphQL
      all_commits_data = @github_graphql_service.fetch_all_branch_commits(org_name, @config.time_since)
      
      # 2. Map all commits to their respective users
      user_commits_map = @github_graphql_service.map_commits_to_users(all_commits_data)
      
      # 3. Get all PR review data
      user_reviews_map = @github_graphql_service.fetch_pull_request_reviews(org_name, @config.time_since)
      
      # 4. Get repository statistics
      repo_stats = @github_graphql_service.fetch_repository_stats(org_name)
      
      # 5. Get trending repositories
      trending_repos = @github_graphql_service.fetch_trending_repositories(org_name, @config.time_since)
      
      # Process all relevant users
      all_user_analysis = {}
      time_window_days = calculate_time_window_days
      
      # Process only the specified users
      @config.specific_users.each do |username|
        @logger.info("Processing specific user: #{username}")
        
        # Get activity data for this specific user
        activity_data = {
          commits: user_commits_map[username.downcase] || user_commits_map[username] || [],
          review_count: user_reviews_map[username.downcase]&.size || user_reviews_map[username]&.size || 0
        }
        
        # Process user activity
        begin
          all_user_analysis[username] = process_user_activity(username, activity_data, time_window_days)
        rescue => e
          @logger.error("Error processing user #{username}: #{e.message}")
          
          # Add empty data for this user to avoid breaking the report
          all_user_analysis[username] = {
            projects: [],
            changes: 0,
            spent_time: "0 hours",
            pr_count: 0,
            summary: "Error processing activity data: #{e.message}",
            lines_changed: 0,
            _generated_by: "error_handler"
          }
        end
      end
      
      # Add metadata to be used by the formatter
      all_user_analysis[:_meta] = {
        api_type: "GitHub GraphQL API",
        repo_stats: repo_stats,
        trending_repos: trending_repos,
        generated_at: Time.now
      }
      
      # Restore original org name in config
      @config.instance_variable_set(:@github_org_name, original_org_name)
      
      @logger.info("==================================================")
      @logger.info("Finished processing specific users for organization: #{org_name}")
      
      # Return the results for this organization
      return all_user_analysis
    end

    # Main function to process results from GitHub API and format them for output
    def process_results(results, specific_users = [])
      @logger.info("Processing results...")
      
      # Debug the structure of the results hash
      @logger.info("Results structure: #{results.keys.join(', ')}")
      
      # Dump the first organization structure to better understand the data
      if results.keys.first && results[results.keys.first].is_a?(Hash)
        org_data = results[results.keys.first]
        @logger.info("First org data keys: #{org_data.keys.join(', ')}")
        
        # Count total commits in all repositories
        total_repo_commits = 0
        
        # Check for repository data in _meta
        if org_data["_meta"] && org_data["_meta"]["repos"] && org_data["_meta"]["repos"].is_a?(Hash)
          org_data["_meta"]["repos"].each do |repo_name, repo_data|
            if repo_data["commit_count"].to_i > 0
              @logger.info("Repository #{repo_name} has #{repo_data["commit_count"]} commits")
              total_repo_commits += repo_data["commit_count"].to_i
            end
          end
          @logger.info("Total commits in all repositories: #{total_repo_commits}")
        end
        
        # Check for key users
        org_data.keys.select { |k| k.is_a?(String) && !k.start_with?("_") }.take(3).each do |username|
          user_data = org_data[username]
          if user_data.is_a?(Hash)
            @logger.info("User #{username} data keys: #{user_data.keys.join(', ')}")
            
            # Check for commits data structure
            if user_data["commits"] && user_data["commits"].is_a?(Array)
              @logger.info("User #{username} has #{user_data["commits"].size} commits as an array")
            end
            
            if user_data["commit_count"]
              @logger.info("User #{username} has 'commit_count': #{user_data["commit_count"]}")
            end
            
            if user_data["commits_count"]
              @logger.info("User #{username} has 'commits_count': #{user_data["commits_count"]}")
            end
          end
        end
      end
      
      # Generate summary statistics and AI description
      results = generate_summary_statistics(results) if @config.gemini_api_key
      
      # Initialize the appropriate output formatter
      output_formatter = OutputFormatter.new(
        config: @config,
        logger: @logger
      )

      output_results = {}
      
      # Process each requested output format
      @config.output_formats.each do |output_format|
        @logger.info("Processing results into #{output_format} format")
        
        case output_format
        when 'json'
          json_output = output_formatter.format(results, 'json')
          if @config.output_to_stdout
            @logger.info("Writing JSON to stdout")
            puts json_output
          else
            output_file = "github_daily_digest_#{Time.now.strftime('%Y-%m-%d')}.json"
            @logger.info("Writing JSON to file: #{output_file}")
            File.write(output_file, json_output)
          end
          output_results['json'] = json_output
          
        when 'markdown'
          markdown_output = output_formatter.format(results, 'markdown')
          if @config.output_to_stdout
            @logger.info("Writing Markdown to stdout")
            puts markdown_output
          else
            output_file = "github_daily_digest_#{Time.now.strftime('%Y-%m-%d')}.md"
            @logger.info("Writing Markdown to file: #{output_file}")
            File.write(output_file, markdown_output)
          end
          output_results['markdown'] = markdown_output
          
        when 'html'
          @logger.info("Processing results into html format")
          # For HTML output, we'll use our standalone HTML formatter
          # First, convert the data to JSON format
          json_data = JSON.pretty_generate(results)
          
          if @config.output_to_stdout
            # Generate HTML and output to stdout
            html_formatter = HtmlFormatter.new(
              data: results,
              theme: @config.html_theme,
              title: @config.html_title || "Team Activity Report - #{Time.now.strftime('%Y-%m-%d')}",
              show_charts: true
            )
            html_output = html_formatter.generate
            
            # Output the HTML
            puts html_output
            
            output_results['html'] = html_output
          else
            # Generate the HTML to a file
            output_file = "#{Time.now.strftime('%Y-%m-%d')}.html"
            html_formatter = HtmlFormatter.new(
              data: results,
              output_file: output_file, 
              theme: @config.html_theme,
              title: @config.html_title || "Team Activity Report - #{Time.now.strftime('%Y-%m-%d')}",
              show_charts: true
            )
            html_formatter.generate
            @logger.info("HTML output generated to: #{output_file}")
            output_results['html'] = output_file
          end
        else
          @logger.warn("Unknown output format: #{output_format}, skipping")
        end
      end
      
      # Return all generated outputs
      output_results
    end

    # Format time window into a human-readable string
    def format_time_period(time_window_days)
      time_window = time_window_days.to_i rescue 7
      
      case time_window
      when 1 then "Last 24 hours"
      when 7 then "Last week"
      when 30, 31 then "Last month"
      else "Last #{time_window} days"
      end
    end

    # Generate summary statistics and AI-generated summary description
    def generate_summary_statistics(results)
      @logger.info("Generating summary statistics and AI description...")
      
      # Calculate aggregate statistics
      total_commits = 0
      total_prs = 0
      total_reviews = 0
      total_lines_changed = 0
      all_weights = {
        "lines_of_code" => [],
        "complexity" => [],
        "technical_depth" => [],
        "scope" => [],
        "pr_reviews" => []
      }
      active_users_count = 0
      active_repos_count = 0
      
      # Gather all language stats
      all_languages = {}
      
      # Process each organization's data
      results.each do |org_name, org_data|
        next if org_name == :_meta || org_name == "_meta" || !org_data.is_a?(Hash)
        
        # Users are direct children of the org hash - we need to find all users
        users_in_org = org_data.keys.reject { |key| key == "_meta" || key == :_meta }
        
        # Count users with commit activity
        active_users = users_in_org.select do |username|
          user_data = org_data[username]
          next false unless user_data.is_a?(Hash)
          
          # Check for commit activity
          commits = user_data["commits"] || user_data["commits_count"] || user_data["commit_count"] || []
          commits.is_a?(Array) && !commits.empty?
        end
        
        active_users_count += active_users.size
        
        # Process each user's data
        users_in_org.each do |username|
          user_data = org_data[username]
          next unless user_data.is_a?(Hash)
          
          # Track if this user has any activity
          has_activity = false
          
          # Aggregate user statistics
          commits = user_data["commits"] || []
          
          # Check if this user has commits (could be an array or a count)
          if commits.is_a?(Array) && !commits.empty?
            total_commits += commits.size
            has_activity = true
          end
          
          if user_data["commits_count"].to_i > 0
            total_commits += user_data["commits_count"].to_i
            has_activity = true
          end
          
          if user_data["commit_count"].to_i > 0
            total_commits += user_data["commit_count"].to_i
            has_activity = true
          end
          
          # Count PRs
          if user_data["prs_count"].to_i > 0
            total_prs += user_data["prs_count"].to_i
            has_activity = true
          end
          
          if user_data["pr_count"].to_i > 0
            total_prs += user_data["pr_count"].to_i
            has_activity = true
          end
          
          # Count reviews
          if user_data["reviews_count"].to_i > 0
            total_reviews += user_data["reviews_count"].to_i
            has_activity = true
          end
          
          if user_data["review_count"].to_i > 0
            total_reviews += user_data["review_count"].to_i
            has_activity = true
          end
          
          # Count lines changed
          if user_data["lines_changed"].to_i > 0
            total_lines_changed += user_data["lines_changed"].to_i
            has_activity = true
          end
        
          # Collect language stats
          if user_data["language_distribution"] && user_data["language_distribution"].is_a?(Hash)
            user_data["language_distribution"].each do |lang, percentage|
              all_languages[lang] ||= 0
              all_languages[lang] += percentage.to_f
            end
          end
        
          # Process contribution weights
          if user_data["contribution_weights"] && user_data["contribution_weights"].is_a?(Hash)
            weights = user_data["contribution_weights"]
            all_weights.keys.each do |key|
              weight_value = weights[key].to_i rescue 0
              all_weights[key] << weight_value if weight_value > 0
            end
          end
          
          # If this user had any activity, increment active users count
          active_users_count += 1 if has_activity
        end
        
        # Count active repositories from _meta.repos
        if org_data["_meta"] && org_data["_meta"]["repos"] && org_data["_meta"]["repos"].is_a?(Hash)
          active_repos = org_data["_meta"]["repos"].values.select do |repo|
            repo["commit_count"].to_i > 0 if repo.is_a?(Hash) && repo["commit_count"]
          end
          active_repos_count += active_repos.size
        end
      end
      
      # Calculate average contribution weights
      average_weights = {}
      all_weights.each do |key, values|
        average_weights[key] = values.empty? ? 0 : (values.sum.to_f / values.size).round(1)
      end
      
      # Normalize language percentages
      language_distribution = {}
      if all_languages.any?
        total_percentage = all_languages.values.sum
        all_languages.each do |lang, percentage|
          normalized = (percentage.to_f / total_percentage * 100).round(1)
          language_distribution[lang] = normalized if normalized > 0
        end
      end
      
      # Create the formatted time period text for the summary
      time_period = format_time_period(@config.time_window_days)
      
      # Generate an AI summary if Gemini is configured
      ai_summary = nil
      if @config.gemini_api_key
        ai_prompt = create_summary_prompt(
          results: results,
          period: time_period,
          total_commits: total_commits,
          total_prs: total_prs,
          total_lines_changed: total_lines_changed,
          active_users_count: active_users_count,
          active_repos_count: active_repos_count,
          language_distribution: language_distribution
        )
        ai_summary = generate_ai_summary(ai_prompt)
      end
      
      # Build the final summary statistics
      summary_statistics = {
        "total_commits" => total_commits,
        "total_prs" => total_prs,
        "total_reviews" => total_reviews,
        "total_lines_changed" => total_lines_changed,
        "active_users_count" => active_users_count,
        "active_repos_count" => active_repos_count,
        "average_weights" => average_weights,
        "team_language_distribution" => language_distribution,
        "period" => time_period,
        "ai_summary" => ai_summary
      }
      
      # Add the summary statistics to the results hash
      results["summary_statistics"] = summary_statistics
      
      results
    end
    
    # Create a prompt for the AI to generate a summary of team activity
    def create_summary_prompt(results:, period:, total_commits:, total_prs:, total_lines_changed:, active_users_count:, active_repos_count:, language_distribution:)
      prompt = "Create a comprehensive yet concise professional summary of team activity for the following period: #{period}.\n\n"
      prompt += "Key metrics:\n"
      prompt += "- Total commits: #{total_commits}\n"
      prompt += "- Total pull requests: #{total_prs}\n"
      prompt += "- Total lines of code changed: #{total_lines_changed}\n"
      prompt += "- Active developers: #{active_users_count}\n"
      prompt += "- Active repositories: #{active_repos_count}\n"
      
      # Add team language distribution
      if language_distribution && !language_distribution.empty?
        top_languages = language_distribution.sort_by { |_, percentage| -percentage }.take(5)
        prompt += "\nTop programming languages used by the team:\n"
        top_languages.each do |lang, percentage|
          prompt += "- #{lang}: #{percentage.round(1)}%\n"
        end
      end
      
      # Collect information about individual developers and their work
      if results && results.is_a?(Hash)
        user_summaries = []
        repositories_worked_on = []
        
        results.each do |org_name, org_data|
          next if org_name == :_meta || org_name == "_meta" || org_name == "summary_statistics" || !org_data.is_a?(Hash)
          
          org_data.each do |username, user_data|
            next if username == "_meta" || username == :_meta || !user_data.is_a?(Hash)
            next unless user_data["total_score"].to_i > 0 || user_data["lines_changed"].to_i > 0
            
            # Gather user summary
            if user_data["summary"].is_a?(String) && !user_data["summary"].empty?
              user_summaries << "#{username}: #{user_data["summary"]}"
            end
            
            # Gather repositories
            if user_data["projects"].is_a?(Array)
              @logger.info("  Found #{user_data["projects"].length} projects for user #{username}") if @logger
              
              user_data["projects"].each do |project|
                begin
                  if project.is_a?(Hash)
                    repo_name = nil
                    
                    # Try to extract the name safely
                    if project.key?("name")
                      repo_name = project["name"].to_s
                    elsif project.key?(:name)
                      repo_name = project[:name].to_s
                    end
                    
                    if repo_name && !repo_name.empty?
                      repositories_worked_on << repo_name
                    end
                  else
                    @logger.warn("  Skipping non-hash project for user #{username}: #{project.inspect}") if @logger
                  end
                rescue => e
                  @logger.warn("  Error processing project for user #{username}: #{e.message}") if @logger
                end
              end
            end
          end
        end
        
        # Add individual developer summaries
        if user_summaries.any?
          prompt += "\nIndividual developer summaries:\n"
          user_summaries.take(5).each do |summary|
            prompt += "- #{summary}\n"
          end
        end
        
        # Add repositories being worked on
        if repositories_worked_on.any?
          unique_repos = repositories_worked_on.uniq
          prompt += "\nRepositories being worked on:\n"
          unique_repos.take(10).each do |repo|
            prompt += "- #{repo}\n"
          end
        end
      end
      
      prompt += "\nBased on this information, provide a professional summary of the team's activity "
      prompt += "that highlights the main focus areas, types of work being done, and overall productivity trends. "
      prompt += "Keep it concise (3-4 sentences) and data-focused. Emphasize what the team accomplished collectively."
      
      return prompt
    end
    
    # Build the final summary statistics
    def build_summary_prompt(stats, results)
      prompt = "Generate a concise 2-3 sentence summary of the following GitHub team activity:\n\n"
      prompt += "Time period: #{stats['period']}\n"
      prompt += "#{stats['active_users_count']} developers made #{stats['total_commits']} commits "
      prompt += "across #{stats['active_repos_count']} repositories.\n"
      prompt += "Total lines of code changed: #{stats['total_lines_changed']}\n"
      
      # Add language distribution
      if stats["team_language_distribution"] && !stats["team_language_distribution"].empty?
        top_languages = stats["team_language_distribution"].sort_by { |_, v| -v }.take(3)
        prompt += "\nTop programming languages used by the team:\n"
        top_languages.each do |lang, percentage|
          prompt += "- #{lang}: #{percentage.round(1)}%\n"
        end
      end
      
      # Add information about most active repos if available
      active_repos = results["organizations"]&.flat_map do |_, org|
        org["repositories"]&.map do |name, repo|
          { name: name, commits: repo["commit_count"] || 0 }
        end
      end&.compact
      
      if active_repos && !active_repos.empty?
        top_repos = active_repos.sort_by { |r| -r[:commits] }.take(3)
        prompt += "Most active repositories: #{top_repos.map { |r| r[:name] }.join(', ')}\n"
      end
      
      prompt += "\nBased on this information, provide a professional summary of the team's activity "
      prompt += "that highlights the main focus areas and overall productivity. Keep it brief and data-focused. Emphasize what the team accomplished collectively."
      
      return prompt
    end
    
    def generate_ai_summary(prompt)
      begin
        @logger.info("Generating AI summary of team activity")
        response = @gemini_service.client.generate_content({
          contents: { role: 'user', parts: { text: prompt } },
          generation_config: { temperature: 0.2 }
        })
        
        # Extract text from the response
        if response && response.respond_to?(:text) && response.text
          @logger.info("Successfully generated AI summary")
          return response.text.strip
        elsif response.is_a?(Hash) && response['candidates'] && response['candidates'][0] && 
            response['candidates'][0]['content'] && response['candidates'][0]['content']['parts'] && 
            response['candidates'][0]['content']['parts'][0]
          # Direct hash structure
          @logger.info("Successfully generated AI summary (hash structure)")
          return response['candidates'][0]['content']['parts'][0]['text'].to_s.strip
        else
          @logger.warn("Failed to generate AI summary: Empty response")
          return "Team showed varied activity levels across multiple repositories, demonstrating collaborative development efforts."
        end
      rescue => e
        @logger.error("Error generating AI summary: #{e.message}")
        return "Team showed varied activity levels across multiple repositories, demonstrating collaborative development efforts."
      end
    end

    private

    def save_results(analysis_data)
      # Only save results to file if not outputting to stdout
      unless @config.output_to_stdout
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        
        # Create results directory if it doesn't exist
        results_dir = File.join(Dir.pwd, 'results')
        Dir.mkdir(results_dir) unless Dir.exist?(results_dir)
        
        output_files = []
        
        @config.output_formats.each do |format|
          case format
          when 'json'
            output_file = File.join(results_dir, "daily_digest_#{timestamp}.json")
            output_formatter = OutputFormatter.new(config: @config, logger: @logger)
            File.write(output_file, output_formatter.format(analysis_data, 'json'))
            output_files << output_file
            
          when 'markdown'
            output_file = File.join(results_dir, "daily_digest_#{timestamp}.md")
            output_formatter = OutputFormatter.new(config: @config, logger: @logger)
            File.write(output_file, output_formatter.format(analysis_data, 'markdown'))
            output_files << output_file
            
          when 'html'
            output_file = File.join(results_dir, "daily_digest_#{timestamp}.html")
            html_formatter = HtmlFormatter.new(
              data: analysis_data,
              output_file: output_file, 
              theme: @config.html_theme,
              title: @config.html_title || "Team Activity Report - #{Time.now.strftime('%Y-%m-%d')}",
              show_charts: true
            )
            html_formatter.generate
            @logger.info("HTML output generated to: #{output_file}")
            output_files << output_file
          else
            # Default to JSON
            output_file = File.join(results_dir, "daily_digest_#{timestamp}.json")
            output_formatter = OutputFormatter.new(config: @config, logger: @logger)
            File.write(output_file, output_formatter.format(analysis_data, 'json'))
            output_files << output_file
          end
        end
        
        @logger.info("Analysis saved to #{output_files.join(', ')}")
        output_files
      end
    end
  end
end
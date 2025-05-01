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
      @analyzer = ActivityAnalyzer.new(gemini_service: @gemini_service, logger: @logger)
    end

    def run
      org_names = @config.github_org_names
      @logger.info("Starting daily digest process for organization(s): #{org_names.join(', ')}")
      @logger.info("Fetching data since: #{@config.time_since}")
      @logger.info("Using GraphQL API: #{@use_graphql ? 'Yes' : 'No'}")

      # Initialize results hash
      all_org_results = {}
      
      # Process each organization separately
      org_names.each_with_index do |org_name, index|
        @logger.info("===== Processing organization: #{org_name} (#{index+1}/#{org_names.size}) =====")
        
        org_results = process_organization(org_name)
        
        # Add results to the combined hash, using org name as namespace
        all_org_results[org_name] = org_results
      end
      
      # Save results to file if not in JSON-only mode
      save_results(all_org_results) unless @config.json_only
      
      @logger.info("Daily digest process completed successfully for all organizations.")
      
      # Return the results with organization structure
      return all_org_results

    rescue => e # Catch errors during initialization or top-level execution
       @logger.fatal("Critical error during Daily Digest run: #{e.message}")
       @logger.fatal(e.backtrace.join("\n"))
       # Return an error object
       return { error: e.message, backtrace: e.backtrace }
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

    private

    def save_results(analysis_data)
      # Log the final JSON if not in JSON-only mode
      @logger.info("Saving analysis results to file")

      # Save the JSON to a timestamped file
      begin
        results_dir = File.expand_path('results', Dir.pwd)
        Dir.mkdir(results_dir) unless Dir.exist?(results_dir)
        results_file = File.join(results_dir, "daily_digest_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
        File.write(results_file, JSON.pretty_generate(analysis_data))
        @logger.info("Analysis saved to #{results_file}")
      rescue => e
        @logger.error("Failed to save results JSON to file: #{e.message}")
      end
    end
  end
end
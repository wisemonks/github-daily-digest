# github_daily_digest/lib/daily_digest_runner.rb
require 'json'
require 'time'
require 'set'

# Require dependent classes (adjust paths if structure differs)
require_relative 'configuration'
require_relative 'github_service'
require_relative 'github_graphql_service'
require_relative 'gemini_service'
require_relative 'user_activity_fetcher'
require_relative 'activity_analyzer'
require_relative 'output_formatter'


module GithubDailyDigest
  class DailyDigestRunner
    # Delay between processing users
    USER_PROCESSING_DELAY = 1 # second

    def initialize(config:, logger:, use_graphql: nil)
      @config = config
      @logger = logger
      @use_graphql = use_graphql.nil? ? config.use_graphql : use_graphql
      
      # Initialize REST API service (always needed for some operations)
      @github_service = GithubService.new(token: config.github_token, logger: @logger, config: config)
      
      # Initialize GraphQL service if enabled
      if @use_graphql
        @logger.info("Initializing GitHub GraphQL service")
        begin
          @github_graphql_service = GithubGraphQLService.new(token: config.github_token, logger: @logger, config: config)
          @logger.info("GitHub GraphQL service successfully initialized")
        rescue => e
          @logger.warn("Failed to initialize GraphQL service: #{e.message}. Falling back to REST API.")
          @use_graphql = false
          @github_graphql_service = nil
        end
      end
      
      @gemini_service = GeminiService.new(api_key: config.gemini_api_key, logger: @logger, config: config)
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
      # Process differently depending on whether GraphQL is enabled
      if @use_graphql
        process_organization_with_graphql(org_name)
      else
        process_organization_with_rest(org_name)
      end
    end

    def process_organization_with_graphql(org_name)
      @logger.info("Processing organization #{org_name} using GraphQL API")
      
      # 1. Fetch all organization members
      member_logins = @github_graphql_service.fetch_members(org_name)
      if member_logins.empty?
        @logger.warn("No members found or error occurred fetching members for #{org_name}.")
        return {}
      end
      
      # 2. Fetch commits from all branches across all active repos via GraphQL
      all_commits_data = @github_graphql_service.fetch_all_branch_commits(org_name, @config.time_since)
      
      # 3. Map all commits to their respective users
      user_commits_map = @github_graphql_service.map_commits_to_users(all_commits_data)
      
      # 4. Get all PR review data
      user_reviews_map = @github_graphql_service.fetch_pull_request_reviews(org_name, @config.time_since)
      
      # 5. Get repository statistics
      repo_stats = @github_graphql_service.fetch_repository_stats(org_name)
      
      # 6. Get trending repositories
      trending_repos = @github_graphql_service.fetch_trending_repositories(org_name, @config.time_since)
      
      # 7. Get user profiles
      user_profiles = @github_graphql_service.fetch_user_profiles(member_logins)
      
      # 8. Create a set of org members for filtering
      org_members_set = member_logins.to_set
      
      # Process all relevant users
      all_user_analysis = {}
      
      # First process users with activity (commits or reviews)
      active_users = (user_commits_map.keys + user_reviews_map.keys).uniq
      active_members = active_users.select { |user| org_members_set.include?(user) }
      
      active_members.each do |username|
        @logger.info("--------------------------------------------------")
        @logger.info("Processing user with activity: #{username}")
        
        # Create activity data hash
        activity_data = {
          commits: user_commits_map[username] || [],
          review_count: user_reviews_map[username]&.size || 0
        }
        
        # Calculate time window in days
        time_window_days = ((Time.now - Time.parse(@config.time_since)) / 86400).round
        
        # Analyze the activity
        analysis = @analyzer.analyze(
          username: username, 
          activity_data: activity_data,
          time_window_days: time_window_days
        )
        all_user_analysis[username] = analysis
        
        # Remove from the set so we know who's left to process
        org_members_set.delete(username)
      end
      
      # Now process remaining members (those without any activity)
      org_members_set.each do |username|
        @logger.info("--------------------------------------------------")
        @logger.info("Processing user without activity: #{username}")
        
        # Create empty activity data
        activity_data = {
          commits: [],
          review_count: 0
        }
        
        # Calculate time window in days
        time_window_days = ((Time.now - Time.parse(@config.time_since)) / 86400).round
        
        # Analyze the activity
        analysis = @analyzer.analyze(
          username: username, 
          activity_data: activity_data,
          time_window_days: time_window_days
        )
        all_user_analysis[username] = analysis
      end
      
      # Add metadata to be used by the formatter
      all_user_analysis[:_meta] = {
        api_type: "GitHub GraphQL API",
        repo_stats: repo_stats,
        trending_repos: trending_repos,
        user_profiles: user_profiles,
        generated_at: Time.now
      }
      
      @logger.info("==================================================")
      @logger.info("Finished processing all users for organization: #{org_name}")
      
      # Return the results for this organization
      return all_user_analysis
    end

    # Process organization using REST API (original implementation)
    def process_organization_with_rest(org_name)
      # 1. Fetch all organization members
      member_logins = @github_service.fetch_members(org_name)
      if member_logins.empty?
        @logger.warn("No members found or error occurred fetching members for #{org_name}.")
        return {}
      end
      
      # 2. Get all active repositories during the time window with their commits
      active_repos = @github_service.fetch_active_repos(org_name, @config.time_since)
      
      # 3. Map all commits to their respective users (much more efficient)
      user_commits_map = @github_service.map_commits_to_users(active_repos)
      
      # 4. Create a set of org members for filtering
      org_members_set = member_logins.to_set
      
      # Process all relevant users (members who had commits + members without commits)
      all_user_analysis = {}

      # First process users with commits
      user_commits_map.each do |username, commits|
        # Skip users who aren't members of the organization
        next unless org_members_set.include?(username)
        
        @logger.info("--------------------------------------------------")
        @logger.info("Processing user with activity: #{username}")
        
        # Get PR review count for the user
        review_count = @github_service.search_user_reviews(username, org_name, @config.time_since)
        @logger.info("User #{username} reviewed #{review_count} PRs since #{@config.time_since}.")
        
        # Create activity data hash
        activity_data = {
          commits: commits,
          review_count: review_count
        }
        
        # Calculate time window in days
        time_window_days = ((Time.now - Time.parse(@config.time_since)) / 86400).round
        
        # Analyze the activity
        analysis = @analyzer.analyze(
          username: username, 
          activity_data: activity_data,
          time_window_days: time_window_days
        )
        all_user_analysis[username] = analysis
        
        # Remove from the set so we know who's left to process
        org_members_set.delete(username)
      end
      
      # Now process remaining members (those without commits)
      org_members_set.each do |username|
        @logger.info("--------------------------------------------------")
        @logger.info("Processing user without commits: #{username}")
        
        # Get PR review count for the user
        review_count = @github_service.search_user_reviews(username, org_name, @config.time_since)
        @logger.info("User #{username} reviewed #{review_count} PRs since #{@config.time_since}.")
        
        # Create activity data hash with empty commits
        activity_data = {
          commits: [],
          review_count: review_count
        }
        
        # Calculate time window in days
        time_window_days = ((Time.now - Time.parse(@config.time_since)) / 86400).round
        
        # Analyze the activity
        analysis = @analyzer.analyze(
          username: username, 
          activity_data: activity_data,
          time_window_days: time_window_days
        )
        all_user_analysis[username] = analysis
      end

      @logger.info("==================================================")
      @logger.info("Finished processing all users for organization: #{org_name}")
      
      # Return the results for this organization
      return all_user_analysis
    end

    private

    def save_results(analysis_data)
      # Log the final JSON if not in JSON-only mode
      final_json = JSON.pretty_generate(analysis_data)
      @logger.info("Saving analysis results to file")

      # Save the JSON to a timestamped file
      begin
        results_dir = File.expand_path('results', Dir.pwd)
        Dir.mkdir(results_dir) unless Dir.exist?(results_dir)
        results_file = File.join(results_dir, "daily_digest_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
        File.write(results_file, final_json)
        @logger.info("Analysis saved to #{results_file}")
      rescue => e
        @logger.error("Failed to save results JSON to file: #{e.message}")
      end
    end
  end
end
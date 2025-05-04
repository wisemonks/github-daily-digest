# github_daily_digest/lib/github_service.rb
require 'octokit'
require 'time' # Ensure Time is loaded for ISO8601
require 'ostruct'

module GithubDailyDigest
  class GithubService
    MAX_RETRIES = 3 # Local retry specifically for rate limits within a method call

    def initialize(token:, logger:, config:)
      @logger = logger
      @config = config
      @client = Octokit::Client.new(access_token: token)
      @client.auto_paginate = true # Essential for members/repos
      verify_authentication
    rescue Octokit::Unauthorized => e
      @logger.fatal("GitHub authentication failed. Check GITHUB_TOKEN. Error: #{e.message}")
      raise # Re-raise to stop execution
    rescue => e
      @logger.fatal("Failed to initialize GitHub client: #{e.message}")
      raise
    end

    def fetch_members(org_name)
      @logger.info("Fetching members for organization: #{org_name}")
      members = handle_api_errors { @client.organization_members(org_name) }
      if members
        logins = members.map(&:login)
        @logger.info("Found #{logins.count} members.")
        logins
      else
        @logger.error("Could not fetch members for #{org_name}.")
        [] # Return empty array on failure after retries
      end
    rescue Octokit::NotFound => e
      @logger.error("Organization '#{org_name}' not found or token lacks permission. Error: #{e.message}")
      []
    end
    
    # Get information about the authenticated user
    def get_current_user
      handle_api_errors do
        user = @client.user
        {
          login: user.login,
          name: user.name,
          email: user.email,
          avatar_url: user.avatar_url,
          scopes: @client.scopes
        }
      end
    rescue => e
      @logger.error("Failed to get current user information: #{e.message}")
      nil
    end

    def fetch_org_repos(org_name)
      @logger.info("Fetching repositories for organization: #{org_name}")

      # First try with type: 'all'
      repos = handle_api_errors do
        @client.organization_repositories(org_name, { type: 'all', per_page: 100 })
      end

      if repos
        @logger.info("Found #{repos.count} repositories.")

        # Log some details about the first few repos for debugging
        if repos.any?
          sample_repos = repos.take(3)
          sample_repos.each do |repo|
            @logger.info("Sample repo: #{repo.full_name}, Private: #{repo.private}, Fork: #{repo.fork}")
          end
        end

        repos # Return the array of Sawyer::Resource objects
      else
        @logger.error("Could not fetch repositories for #{org_name}.")
        []
      end
    end

    # Fetches commits for a specific user in a specific repo since a given time
    def fetch_user_commits_in_repo(repo_full_name, username, since_time)
      @logger.debug("Fetching commits by #{username} in #{repo_full_name} since #{since_time}")
      options = { author: username, since: since_time }
      commits = handle_api_errors(catch_conflicts: true) do
        @client.commits_since(repo_full_name, since_time, options)
        # Alternative if above doesn't work reliably with author filter:
        # @client.commits(repo_full_name, since: since_time).select { |c| c.author&.login == username }
      end
      commits || [] # Return empty array on failure
    rescue Octokit::Conflict, Octokit::NotFound => e
      # Repo might be empty, disabled issues/wiki, or inaccessible
      @logger.warn("Skipping repo #{repo_full_name} for user #{username}. Reason: #{e.message}")
      []
    end

    # Searches for PRs reviewed by the user
    def search_user_reviews(username, org_name, since_time)
      @logger.debug("Searching PR reviews for user: #{username} since #{since_time}")
      query = "is:pr reviewed-by:#{username} org:#{org_name} updated:>#{since_time}"
      results = handle_api_errors { @client.search_issues(query, per_page: 1) } # Fetch 1 to get total_count efficiently
      count = results ? results.total_count : 0
      @logger.debug("Found #{count} PRs reviewed by #{username} via search.")
      count
    end

    # Fetches all repositories with activity since a given time
    def fetch_active_repos(org_name, since_time)
      @logger.info("Fetching active repositories for organization: #{org_name} since #{since_time}")
      repos = fetch_org_repos(org_name)
      
      @logger.info("Checking #{repos.size} repositories for activity")
      active_repos = {}
      
      repos.each_with_index do |repo, index|
        repo_full_name = repo.full_name
        @logger.info("Checking for activity in #{repo_full_name} since #{since_time} [#{index+1}/#{repos.size}]")
        
        begin
          # Get all branches for this repository
          branches = handle_api_errors(catch_conflicts: true) do
            @client.branches(repo_full_name)
          end
          
          if branches.nil? || branches.empty?
            @logger.debug("No branches found in #{repo_full_name}")
            next
          end
          
          @logger.info("Found #{branches.count} branches in #{repo_full_name}")
          
          # Find branches with recent activity
          active_branches = []
          all_commits = []
          
          # We'll check each branch in parallel
          branches.each do |branch|
            branch_name = branch.name
            
            # Get latest commit for the branch
            latest_commit = branch.commit
            if latest_commit
              commit_date = nil
              
              # Get full commit details to check date
              commit_details = handle_api_errors(catch_conflicts: true) do
                @client.commit(repo_full_name, latest_commit.sha)
              end
              
              if commit_details && commit_details.commit && commit_details.commit.author
                commit_date = commit_details.commit.author.date
              end
              
              # If this branch has commits since our cutoff date, flag it as active
              if commit_date && Time.parse(commit_date.to_s) >= Time.parse(since_time.to_s)
                active_branches << branch_name
              end
            end
          end
          
          if active_branches.any?
            @logger.info("Found #{active_branches.size} active branches in #{repo_full_name}: #{active_branches.join(', ')}")
            
            # Now get commits for each active branch
            active_branches.each do |branch_name|
              branch_commits = handle_api_errors(catch_conflicts: true) do
                @client.commits(repo_full_name, { sha: branch_name, since: since_time })
              end
              
              if branch_commits && branch_commits.any?
                @logger.debug("Found #{branch_commits.count} commits in branch #{branch_name} of #{repo_full_name}")
                
                # Add branch information to each commit
                branch_commits.each do |commit|
                  commit.branch = branch_name
                end
                
                all_commits.concat(branch_commits)
              end
            end
            
            # Remove duplicate commits (same SHA across multiple branches)
            # But preserve branch information
            unique_commits = {}
            all_commits.each do |commit|
              if unique_commits[commit.sha]
                # If we've seen this commit before, add branch to its branches list
                unique_commits[commit.sha].branches ||= []
                unique_commits[commit.sha].branches << commit.branch unless unique_commits[commit.sha].branches.include?(commit.branch)
              else
                # First time seeing this commit
                commit.branches = [commit.branch]
                unique_commits[commit.sha] = commit
              end
            end
            
            commits = unique_commits.values
            
            if commits.any?
              @logger.info("Found #{commits.count} unique commits across active branches in #{repo_full_name}")
              active_repos[repo_full_name] = commits
            end
          else
            @logger.debug("No active branches found in #{repo_full_name} since #{since_time}")
          end
          
          # Avoid hitting rate limits
          sleep(0.1) if index > 0 && index % 10 == 0
        rescue => e
          @logger.error("Error checking repo #{repo_full_name}: #{e.message}")
          @logger.error(e.backtrace.join("\n"))
          next
        end
      end
      
      if active_repos.empty?
        @logger.warn("No active repositories found with commits since #{since_time}")
      else
        @logger.info("Found #{active_repos.size} active repositories with commits out of #{repos.size} total repos")
        active_repos.keys.each do |repo_name|
          @logger.info("Active repo: #{repo_name} with #{active_repos[repo_name].size} commits")
        end
      end
      
      active_repos
    end

    # Maps commits to users for efficient activity tracking
    def map_commits_to_users(active_repos)
      @logger.info("Mapping commits to users")
      user_commits = {}

      active_repos.each do |repo_full_name, commits|
        commits.each do |commit|
          author = commit.author&.login
          next unless author # Skip commits without a valid GitHub author

          # Fetch commit details to get line changes
          commit_details = handle_api_errors do
            @client.commit(repo_full_name, commit.sha)
          end

          user_commits[author] ||= []

          if commit_details
            # Add commit with line changes information if available
            user_commits[author] << format_commit(commit, repo_full_name, commit_details)
          else
            # Fallback to basic commit info if details couldn't be fetched
            user_commits[author] << format_commit(commit, repo_full_name)
          end
        end
      end

      @logger.info("Found commits from #{user_commits.size} users")
      user_commits
    end

    private

    def verify_authentication
      @logger.info("Verifying GitHub authentication...")
      user = @client.user
      @logger.info("Authenticated to GitHub as user: #{user.login}")

      # Check token scopes
      scopes = @client.scopes
      @logger.info("Token scopes: #{scopes.join(', ')}")

      # Check if the token has sufficient permissions
      has_repo_scope = scopes.any? { |s| s == 'repo' || s.start_with?('repo:') }
      has_org_scope = scopes.any? { |s| s == 'read:org' || s == 'admin:org' }

      @logger.info("Token has repo scope: #{has_repo_scope}")
      @logger.info("Token has org read scope: #{has_org_scope}")

      if !has_repo_scope
        @logger.warn("WARNING: Token may not have sufficient permissions to access private repositories")
      end

      if !has_org_scope
        @logger.warn("WARNING: Token may not have sufficient permissions to access all organization data")
      end

      user # Return user object if needed elsewhere, otherwise just confirms connection
    end

    # Wrapper for handling common API errors and rate limiting
    def handle_api_errors(retries = @config.max_api_retries, catch_conflicts: false)
      attempts = 0
      begin
        attempts += 1
        yield # Execute the Octokit API call block
      rescue Octokit::Conflict => e
        if catch_conflicts && e.message.include?('Git Repository is empty')
          @logger.warn("Repository is empty: #{e.message}")
          nil # Just return nil without stack trace for empty repositories
        else
          @logger.error("GitHub API conflict error: #{e.message}")
          nil
        end
      rescue Octokit::TooManyRequests => e
        if attempts <= retries
          sleep_time = calculate_backoff(attempts)
          @logger.warn("GitHub rate limit hit (Attempt #{attempts}/#{retries}). Sleeping for #{sleep_time}s. Limit resets at: #{e.response_headers['x-ratelimit-reset'] ? Time.at(e.response_headers['x-ratelimit-reset'].to_i) : 'N/A'}")
          sleep sleep_time
          retry
        else
          @logger.error("GitHub rate limit exceeded after #{attempts} attempts. Error: #{e.message}")
          nil # Indicate failure after retries
        end
      rescue Octokit::ServerError, Octokit::BadGateway, Net::ReadTimeout, Faraday::ConnectionFailed => e
        # Retry on temporary server issues or network problems
        if attempts <= retries
          sleep_time = calculate_backoff(attempts)
          @logger.warn("GitHub temporary error (Attempt #{attempts}/#{retries}): #{e.class}. Retrying in #{sleep_time}s.")
          sleep sleep_time
          retry
        else
          @logger.error("GitHub API error after #{attempts} attempts: #{e.class} - #{e.message}")
          nil
        end
      rescue => e # Catch other potential Octokit errors or unexpected issues
        @logger.error("Unexpected GitHub API error: #{e.class} - #{e.message}")
        nil # Indicate failure
      end
    end

    # Helper to format commit data consistently
    def format_commit(commit_data, repo_full_name, commit_details = nil)
      # Basic commit info
      formatted = {
        sha: commit_data.sha,
        repo: repo_full_name,
        date: commit_data.commit.author.date.iso8601,
        message: commit_data.commit.message
      }
      
      # Add branch information if available
      if commit_data.respond_to?(:branches) && commit_data.branches
        formatted[:branches] = commit_data.branches
      end
      
      # Add stats if available from commit details
      if commit_details && commit_details.stats
        formatted[:stats] = {
          additions: commit_details.stats.additions,
          deletions: commit_details.stats.deletions,
          total_changes: commit_details.stats.total
        }
      end
      
      formatted
    end

    def calculate_backoff(attempt)
      # Exponential backoff with jitter
      (@config.rate_limit_sleep_base ** attempt) + rand(0.0..1.0)
    end

  end
end
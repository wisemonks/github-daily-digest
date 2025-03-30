# github_daily_digest/lib/user_activity_fetcher.rb

module GithubDailyDigest
  class UserActivityFetcher
    # Delay between checking repos to be kind to the API
    REPO_FETCH_DELAY = 0.1 # seconds

    def initialize(username:, github_service:, github_graphql_service: nil, logger:, config:)
      @username = username
      @github_service = github_service
      @github_graphql_service = github_graphql_service
      @logger = logger
      @config = config
      @org_name = config.github_org_name
      @since_time = config.time_since
      @use_graphql = !@github_graphql_service.nil?
    end

    def fetch_activity
      @logger.info("Fetching activity for user: #{@username}")
      
      if @use_graphql
        fetch_activity_with_graphql
      else
        fetch_activity_with_rest
      end
    end

    private

    def fetch_activity_with_graphql
      @logger.info("Using GraphQL API for #{@username}")
      
      # In GraphQL mode, we already have all commits across repos in the org 
      # so we just need to filter for this user
      commits = []
      review_data = []
      
      # Get all active repos with their commits from the GraphQL service
      # (It's more efficient to query once for all repos/users and then filter)
      active_repos = @github_graphql_service.fetch_active_repos(@org_name, @since_time)
      
      # Filter commits for current user
      user_commits_map = @github_graphql_service.map_commits_to_users(active_repos)
      commits = user_commits_map[@username] || []
      
      # Format commits to match expected structure
      formatted_commits = commits.map do |commit|
        {
          repo: commit[:repo],
          sha: commit[:sha],
          message: commit[:message].split("\n", 2).first.strip, # First line only, trimmed
          url: "https://github.com/#{commit[:repo]}/commit/#{commit[:sha]}",
          timestamp: commit[:date] ? Time.parse(commit[:date].to_s).iso8601 : 'N/A',
          stats: commit[:stats]
        }
      end
      
      # Get PR review data
      user_reviews = @github_graphql_service.fetch_pull_request_reviews(@org_name, @since_time)
      review_count = user_reviews[@username]&.size || 0
      
      @logger.info("GraphQL fetch completed for #{@username}. Found #{formatted_commits.count} commits and #{review_count} reviews.")
      
      { commits: formatted_commits, review_count: review_count }
    end

    def fetch_activity_with_rest
      @logger.info("Using REST API for #{@username}")
      commits = fetch_all_user_commits
      review_count = fetch_user_review_count

      { commits: commits, review_count: review_count }
    end

    def fetch_all_user_commits
      @logger.debug("Starting commit fetch for #{@username}")
      user_commits = []
      repos = @github_service.fetch_org_repos(@org_name)

      unless repos&.any?
        @logger.warn("No repositories found or accessible for org #{@org_name}. Cannot fetch commits.")
        return []
      end

      @logger.info("Checking #{repos.count} repositories for #{@username}'s commits since #{@since_time}...")

      repos.each_with_index do |repo, index|
        repo_full_name = repo.full_name
        begin
          commits_in_repo = @github_service.fetch_user_commits_in_repo(repo_full_name, @username, @since_time)

          unless commits_in_repo.empty?
            @logger.debug("Found #{commits_in_repo.count} commits by #{@username} in #{repo_full_name}")
            commits_in_repo.each do |commit|
              user_commits << format_commit(commit, repo_full_name)
            end
          end

          # Avoid hitting secondary rate limits / abuse detection
          sleep(REPO_FETCH_DELAY) if index > 0 && index % 20 == 0

        rescue => e # Catch unexpected errors during processing for a single repo
          @logger.error("Unexpected error processing commits for repo #{repo_full_name}, user #{@username}: #{e.message}")
          # Log backtrace if needed: @logger.error(e.backtrace.join("\n"))
          next # Continue to the next repository
        end
      end

      @logger.info("Finished checking repositories for #{@username}. Found #{user_commits.count} total commits.")
      user_commits
    end

    def fetch_user_review_count
      @logger.debug("Fetching review count for #{@username}")
      count = @github_service.search_user_reviews(@username, @org_name, @since_time)
      @logger.info("User #{@username} reviewed #{count} PRs since #{@since_time}.")
      count
    end

    def format_commit(commit_data, repo_full_name)
      {
        repo: repo_full_name,
        sha: commit_data.sha,
        message: commit_data.commit.message.split("\n", 2).first.strip, # First line only, trimmed
        url: commit_data.html_url,
        # Ensure timestamp is parsed correctly, handle potential nil values
        timestamp: commit_data.commit&.author&.date ? Time.parse(commit_data.commit.author.date.to_s).iso8601 : 'N/A'
      }
    end
  end
end
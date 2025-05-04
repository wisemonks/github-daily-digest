# github_daily_digest/lib/activity_analyzer.rb
require_relative './language_analyzer.rb'
module GithubDailyDigest
  class ActivityAnalyzer
    def initialize(gemini_service:, github_graphql_service:, logger:)
      @gemini_service = gemini_service
      @github_graphql_service = github_graphql_service
      @logger = logger
    end

    def analyze(username:, activity_data:, time_window_days: 7)
      @logger.info("Analyzing activity for user: #{username}")
      commits = activity_data[:commits]
      review_count = activity_data[:review_count]

      commits_with_code = if @github_graphql_service
                          @github_graphql_service.fetch_commits_changes(commits)
                        else
                          @logger.debug("GraphQL service not available, proceeding without detailed commit changes")
                          commits
                        end

      analysis_result = @gemini_service.analyze_activity(
        username: username,
        commits_with_code: commits_with_code,
        review_count: review_count,
        time_window_days: time_window_days
      )
      @logger.debug("Gemini analysis result for #{username}: #{analysis_result}")

      # Add username and timestamp to the result for context
      analysis_result[:username] = username
      analysis_result[:analysis_timestamp] = Time.now.iso8601

      # Calculate language distribution
      
      analysis_result[:language_distribution] = LanguageAnalyzer.calculate_distribution(commits_with_code.map{ |f| f[:code_changes][:files] }.flatten)

      if analysis_result[:error]
         @logger.error("Analysis failed for #{username}: #{analysis_result[:error]}")
      else
         @logger.info("Analysis successful for #{username}")
      end

      analysis_result
    end
  end
end
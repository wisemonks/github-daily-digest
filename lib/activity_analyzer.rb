# github_daily_digest/lib/activity_analyzer.rb

module GithubDailyDigest
  class ActivityAnalyzer
    def initialize(gemini_service:, logger:)
      @gemini_service = gemini_service
      @logger = logger
    end

    def analyze(username:, activity_data:, time_window_days: 7)
      @logger.info("Analyzing activity for user: #{username}")
      commits = activity_data[:commits]
      review_count = activity_data[:review_count]

      analysis_result = @gemini_service.analyze_activity(
        username: username,
        commits: commits,
        review_count: review_count,
        time_window_days: time_window_days
      )

      # Add username and timestamp to the result for context
      analysis_result[:username] = username
      analysis_result[:analysis_timestamp] = Time.now.iso8601

      if analysis_result[:error]
         @logger.error("Analysis failed for #{username}: #{analysis_result[:error]}")
      else
         @logger.info("Analysis successful for #{username}")
      end

      analysis_result
    end
  end
end
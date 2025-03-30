# github_daily_digest/lib/github_daily_digest.rb
require "logger"
require "active_support/all"
require "octokit"
require "gemini-ai"
require "json"
require "time"

# Order matters for relative requires if classes depend on each other during load
require_relative "lib/github_daily_digest/version"
require_relative "lib/configuration"
require_relative "lib/github_service"
require_relative "lib/github_graphql_service"
require_relative "lib/gemini_service"
require_relative "lib/user_activity_fetcher"
require_relative "lib/activity_analyzer"
require_relative "lib/daily_digest_runner"

module GithubDailyDigest
  class Error < StandardError; end
  # You can define custom error classes here if needed

  # Example convenience method (optional)
  # def self.run_digest(config_options = {})
  #   # Logic to potentially configure and run the digest directly
  #   # This is less common for a tool primarily used via executable
  # end
end
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
require_relative "lib/activity_analyzer"
require_relative "lib/daily_digest_runner"

module GithubDailyDigest
  class Error < StandardError; end
end
# frozen_string_literal: true

require_relative "github_daily_digest/version"
require_relative "configuration"
require_relative "github_service"
require_relative "github_graphql_service"
require_relative "gemini_service"
require_relative "user_activity_fetcher"
require_relative "activity_analyzer"
require_relative "daily_digest_runner"
require_relative "output_formatter"

module GithubDailyDigest
  class Error < StandardError; end
  # Your code goes here...
end

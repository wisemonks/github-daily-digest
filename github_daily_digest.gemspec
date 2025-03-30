# github_daily_digest/github_daily_digest.gemspec
require_relative "lib/github_daily_digest/version"

Gem::Specification.new do |spec|
  spec.name          = "github_daily_digest"
  spec.version       = GithubDailyDigest::VERSION
  spec.authors       = ["Arturas Piksrys"]
  spec.email         = ["arturas@wisemonks.com"] 

  spec.summary       = "Generates daily activity digests for GitHub organization members using Gemini."
  spec.description   = "Fetches recent GitHub commits and PR reviews for organization members and uses Google's Gemini API to analyze and summarize the activity. Provides an executable for daily runs."
  spec.homepage      = "https://github.com/wisemonks/github_daily_digest" 
  spec.license       = "MIT" 
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage # Assumes source is at homepage
  # spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here." # Optional

  # Specify which files should be added to the gem when it is packaged.
  # Note: Excludes test files, .env, logs, results, etc.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      # Exclude test files, dev config, local results/logs etc.
      f.match(%r{\A(?:test|spec|features)/}) ||
      f.match(%r{\A\.git}) ||
      f.match(%r{\A\.env}) ||
      f.match(%r{daily_digest\.log}) ||
      f.match(%r{cron\.log}) ||
      f.match(%r{\Aresults/})
    end
  end
  spec.bindir        = "bin" # Directory for executables
  spec.executables   = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) } # Find executables in bin/
  spec.require_paths = ["lib"] # Code is loaded from the lib directory

  # Runtime Dependencies: Gems required for the gem to function
  spec.add_dependency "activesupport", "~> 7.0" # Or your preferred version constraint
  spec.add_dependency "gemini-ai", "~> 4.2"
  spec.add_dependency "logger" # Standard lib, but good practice to list
  spec.add_dependency "octokit", "~> 6.1"
  spec.add_dependency "graphql-client", "~> 0.19.0"

  # Development Dependencies: Gems needed for development/testing (managed by Gemfile)
  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  # spec.add_development_dependency "rspec", "~> 3.0" # If you add tests
  spec.add_development_dependency "dotenv", "~> 2.8" # Needed by the *executable* for convenience
end
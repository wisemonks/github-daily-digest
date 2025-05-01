#!/usr/bin/env ruby

# A temporary solution file to generate proper markdown output with contribution weights
# Run this after generating JSON output from github-daily-digest

require 'json'
require 'optparse'

options = {
  input_file: nil,
  output_file: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby markdown_formatter.rb [options]"

  opts.on("-i", "--input FILE", "Input JSON file") do |file|
    options[:input_file] = file
  end

  opts.on("-o", "--output FILE", "Output Markdown file") do |file|
    options[:output_file] = file
  end
end.parse!

unless options[:input_file]
  puts "Error: Input file is required"
  exit 1
end

# Read the JSON file
json_data = JSON.parse(File.read(options[:input_file]))

# Generate markdown
markdown = "# GitHub Activity Digest\n\n"
markdown << "Generated on: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}\n\n"

# Add overview section
markdown << "## Overview\n\n"
markdown << "| Category | Value |\n"
markdown << "| --- | --- |\n"
markdown << "| **Time Period** | Last 7 days |\n"

# Get organizations
organizations = json_data.keys.reject { |k| k == "_meta" }
markdown << "| **Organizations** | #{organizations.join(', ')} |\n"
markdown << "| **Data Source** | GitHub API |\n\n"

# Process users
all_users = {}
organizations.each do |org|
  json_data[org].each do |username, user_data|
    next if username == "_meta"
    
    # Skip users with no activity
    next if user_data["changes"].to_i == 0 && user_data["pr_count"].to_i == 0
    
    all_users[username] ||= {
      username: username,
      commits: 0,
      prs: 0,
      lines_changed: 0,
      projects: [],
      total_score: 0,
      weights: {
        "lines_of_code" => 0,
        "complexity" => 0,
        "technical_depth" => 0,
        "scope" => 0,
        "pr_reviews" => 0
      },
      summary: user_data["summary"] || ""
    }
    
    # Accumulate data
    all_users[username][:commits] += user_data["changes"].to_i
    all_users[username][:prs] += user_data["pr_count"].to_i
    all_users[username][:lines_changed] += user_data["lines_changed"].to_i
    
    # Get projects
    if user_data["projects"].is_a?(Array)
      all_users[username][:projects] += user_data["projects"]
    end
    
    # Get contribution weights
    if user_data["contribution_weights"].is_a?(Hash)
      weights = user_data["contribution_weights"]
      
      all_users[username][:weights]["lines_of_code"] = [all_users[username][:weights]["lines_of_code"], weights["lines_of_code"].to_i].max
      all_users[username][:weights]["complexity"] = [all_users[username][:weights]["complexity"], weights["complexity"].to_i].max
      all_users[username][:weights]["technical_depth"] = [all_users[username][:weights]["technical_depth"], weights["technical_depth"].to_i].max
      all_users[username][:weights]["scope"] = [all_users[username][:weights]["scope"], weights["scope"].to_i].max
      all_users[username][:weights]["pr_reviews"] = [all_users[username][:weights]["pr_reviews"], weights["pr_reviews"].to_i].max
    end
    
    # Calculate total score
    all_users[username][:total_score] = 0
    all_users[username][:weights].each do |key, value|
      all_users[username][:total_score] += value.to_i
    end
  end
end

# Sort users by total score
sorted_users = all_users.values.sort_by { |user| -user[:total_score] }

# Add active users section
markdown << "## Active Users\n\n"
markdown << "Users are sorted by their total contribution score, which is calculated as the sum of individual contribution weights.\n"
markdown << "Each contribution weight is on a scale of 0-10 and considers different aspects of contribution value.\n\n"

# Create users table
markdown << "| User | Commits | PRs | Lines Changed | Total Score | Contribution Weights | Summary | Projects |\n"
markdown << "|------|---------|-----|---------------|-------------|----------------------|---------|----------|\n"

sorted_users.each do |user|
  # Format weights
  weights_display = "LOC: #{user[:weights]['lines_of_code']} | " +
                    "Complexity: #{user[:weights]['complexity']} | " + 
                    "Depth: #{user[:weights]['technical_depth']} | " +
                    "Scope: #{user[:weights]['scope']} | " +
                    "PR: #{user[:weights]['pr_reviews']}"
  
  # Format projects
  projects_display = user[:projects].uniq.join(", ")
  
  # Create row
  markdown << "| #{user[:username]} | #{user[:commits]} | #{user[:prs]} | #{user[:lines_changed]} | #{user[:total_score]} | #{weights_display} | #{user[:summary]} | #{projects_display} |\n"
end

# Output markdown
if options[:output_file]
  File.write(options[:output_file], markdown)
  puts "Markdown written to #{options[:output_file]}"
else
  puts markdown
end

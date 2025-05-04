#!/usr/bin/env ruby
# github_daily_digest/generate_html_report.rb
#
# Script to generate a standalone HTML page with GitHub Daily Digest data
# Uses the HtmlFormatter class to create a responsive dashboard with charts
# All dependencies are loaded via CDN (Tailwind CSS, React, ReCharts)

require 'json'
require 'optparse'
require_relative 'lib/html_formatter'

options = {
  input_file: nil,
  output_file: nil,
  theme: 'default',
  chart_theme: 'default',
  title: nil,
  show_charts: true,
  show_extended: true,  # New option to show extended details by default
  show_repo_details: true,  # Show repository details for each user
  show_language_details: true,  # Show language statistics
  show_work_details: true  # Show details of work done from commits
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby generate_html_report.rb [options]"

  opts.on("-i", "--input FILE", "Input JSON file") do |file|
    options[:input_file] = file
  end

  opts.on("-o", "--output FILE", "Output HTML file (defaults to YYYY-MM-DD.html)") do |file|
    options[:output_file] = file
  end
  
  opts.on("-t", "--title TITLE", "Custom title for the report") do |title|
    options[:title] = title
  end
  
  opts.on("--theme THEME", "Theme to use (default, dark, light)") do |theme|
    unless ['default', 'dark', 'light'].include?(theme)
      puts "Error: Invalid theme '#{theme}'. Must be 'default', 'dark', or 'light'."
      exit 1
    end
    options[:theme] = theme
  end
  
  opts.on("--no-charts", "Disable charts in the output") do
    options[:show_charts] = false
  end
  
  opts.on("--no-extended", "Disable extended details in the output") do
    options[:show_extended] = false
  end
  
  opts.on("--no-repo-details", "Disable repository details per user") do
    options[:show_repo_details] = false
  end
  
  opts.on("--no-language-details", "Disable language distribution statistics") do
    options[:show_language_details] = false
  end
  
  opts.on("--no-work-details", "Disable work summary details from commits") do
    options[:show_work_details] = false
  end
  
  opts.on("-h", "--help", "Show help") do
    puts opts
    exit
  end
end.parse!

unless options[:input_file]
  puts "Error: Input file is required"
  puts "Usage: ruby generate_html_report.rb -i input.json [-o output.html]"
  exit 1
end

# Set default output file if not provided
unless options[:output_file]
  options[:output_file] = "#{Time.now.strftime('%Y-%m-%d')}.html"
end

begin
  # Read the JSON file
  json_data = File.read(options[:input_file])
  digest_data = JSON.parse(json_data)
  
  # Generate the HTML report
  formatter = GithubDailyDigest::HtmlFormatter.new(
    digest_data, 
    output_file: options[:output_file],
    theme: options[:theme],
    chart_theme: options[:chart_theme],
    title: options[:title],
    show_charts: options[:show_charts],
    show_extended: options[:show_extended],
    show_repo_details: options[:show_repo_details],
    show_language_details: options[:show_language_details],
    show_work_details: options[:show_work_details]
  )
  output_path = formatter.generate
  
  puts "HTML report successfully generated at: #{output_path}"
  puts "Open in your browser with: open '#{output_path}'"
  
rescue JSON::ParserError => e
  puts "Error parsing JSON file: #{e.message}"
  exit 1
rescue StandardError => e
  puts "Error generating HTML report: #{e.message}"
  puts e.backtrace.join("\n")
  exit 1
end

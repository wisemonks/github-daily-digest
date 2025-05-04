#!/usr/bin/env ruby
# Generate an HTML report directly from the most recent GitHub Daily Digest JSON output
# This script is a simpler, more reliable way to generate HTML reports

require_relative 'lib/html_formatter'
require 'json'
require 'optparse'
require 'time'

options = {
  input_file: nil,
  output_file: nil,
  theme: 'dark',
  title: "Team Activity Report - #{Time.now.strftime('%Y-%m-%d')}"
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby daily_html_report.rb [options]"
  
  opts.on("-i", "--input FILE", "Input JSON file (defaults to latest in results directory)") do |file|
    options[:input_file] = file
  end
  
  opts.on("-o", "--output FILE", "Output HTML file (defaults to YYYY-MM-DD.html)") do |file|
    options[:output_file] = file
  end
  
  opts.on("--theme THEME", "Theme to use (default, dark, light)") do |theme|
    options[:theme] = theme
  end
  
  opts.on("-t", "--title TITLE", "Custom title for the report") do |title|
    options[:title] = title
  end
  
  opts.on("-h", "--help", "Show help") do
    puts opts
    exit
  end
end.parse!

puts "GitHub Daily Digest - HTML Report Generator"

# Find the latest JSON file if not specified
if options[:input_file].nil?
  results_dir = File.join(Dir.pwd, 'results')
  
  if Dir.exist?(results_dir)
    json_files = Dir.glob(File.join(results_dir, "*.json"))
    
    if json_files.any?
      json_files.sort_by! { |f| File.mtime(f) }
      options[:input_file] = json_files.last
      puts "Using latest JSON file: #{options[:input_file]}"
    else
      puts "No JSON files found in results directory. Please specify an input file with -i."
      exit 1
    end
  else
    puts "Results directory not found. Please specify an input file with -i."
    exit 1
  end
end

# If no output file specified, use the current date
options[:output_file] ||= "#{Time.now.strftime('%Y-%m-%d')}.html"

begin
  puts "Reading data from #{options[:input_file]}..."
  json_data = File.read(options[:input_file])
  digest_data = JSON.parse(json_data)
  
  puts "Generating HTML report with theme: #{options[:theme]}"
  formatter = GithubDailyDigest::HtmlFormatter.new(
    digest_data,
    output_file: options[:output_file],
    theme: options[:theme],
    title: options[:title]
  )
  
  output_path = formatter.generate
  
  puts "HTML report successfully generated at: #{output_path}"
  puts "Open in your browser with: open '#{output_path}'"
  
rescue JSON::ParserError => e
  puts "Error parsing JSON file: #{e.message}"
  exit 1
rescue => e
  puts "Error generating HTML report: #{e.message}"
  puts e.backtrace
  exit 1
end

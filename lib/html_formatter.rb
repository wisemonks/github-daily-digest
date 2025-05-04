#!/usr/bin/env ruby
# github_daily_digest/lib/html_formatter.rb

module GithubDailyDigest
  class HtmlFormatter
    attr_reader :data, :output_file, :theme

    def initialize(data, options = {})
      @data = normalize_data(data)
      @output_file = options[:output_file] || generate_default_filename
      @theme = options[:theme] || 'default' # Can be 'default', 'dark', or 'light'
      @chart_theme = options[:chart_theme] || 'default' # Can customize chart colors
      @title = options[:title] || "GitHub Daily Digest - #{Time.now.strftime('%Y-%m-%d')}"
      @show_charts = options.key?(:show_charts) ? options[:show_charts] : true
      @show_extended = options.key?(:show_extended) ? options[:show_extended] : true
      @show_repo_details = options.key?(:show_repo_details) ? options[:show_repo_details] : true
      @show_language_details = options.key?(:show_language_details) ? options[:show_language_details] : true
      @show_work_details = options.key?(:show_work_details) ? options[:show_work_details] : true
      @raw_data = options[:raw_data] # Store raw data for later use
    end

    def generate
      html_content = build_html
      File.write(output_file, html_content)
      puts "HTML report generated at: #{output_file}"
      output_file
    end

    private

    def generate_default_filename
      date = Time.now.strftime('%Y-%m-%d')
      "github_digest_#{date}.html"
    end

    def build_html
      # Generate charts section conditionally
      charts_section = ""
      if @show_charts
        charts_section = <<-CHARTS
<div class="card p-6 mb-8">
  <h2 class="text-2xl font-bold mb-6">Contribution Charts</h2>
  
  <!-- User Activity Chart -->
  <div class="chart-container">
    <canvas id="userActivityChart"></canvas>
  </div>
  
  <!-- Contribution Weights Chart -->
  <div class="chart-container">
    <canvas id="contributionWeightsChart"></canvas>
  </div>
  
  <!-- Language Distribution Chart (Combined) -->
  <div class="chart-container">
    <canvas id="combinedLanguageDistributionChart"></canvas>
  </div>
</div>
        CHARTS
      end
      
      # Main HTML template
      template = <<-HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>#{@title}</title>
  <!-- Inter font -->
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap">
  <!-- Tailwind CSS via CDN -->
  <script src="https://cdn.tailwindcss.com"></script>
  <!-- Chart.js -->
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
  <script>
    tailwind.config = {
      darkMode: '#{@theme == 'dark' ? 'class' : 'media'}',
      theme: {
        extend: {
          colors: {
            primary: '#{primary_color}',
            secondary: '#{secondary_color}',
            accent: '#{accent_color}'
          },
          fontFamily: {
            sans: ['Inter', 'system-ui', 'sans-serif'],
          }
        }
      }
    }
  </script>
  <style>
    body {
      font-family: 'Inter', sans-serif;
    }
    
    .chart-container {
      height: 400px;
      margin-bottom: 2rem;
    }
    
    .card {
      @apply bg-white dark:bg-gray-800 rounded-lg shadow-md overflow-hidden;
    }
    
    .badge {
      @apply inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium;
    }
    
    .stat-number {
      @apply text-3xl font-bold;
    }
    
    .user-row-details {
      display: none;
    }
    
    .user-row.expanded .user-row-details {
      display: table-row;
    }
    
    @media print {
      body {
        font-size: 12px;
      }
      .no-print {
        display: none !important;
      }
      .user-row-details {
        display: table-row;
      }
      .card {
        box-shadow: none;
        border: 1px solid #eee;
      }
      .chart-container {
        height: 300px;
        page-break-inside: avoid;
      }
      table {
        page-break-inside: auto;
      }
      tr {
        page-break-inside: avoid;
        page-break-after: auto;
      }
    }
  </style>
</head>
<body class="bg-gray-50 #{@theme == 'dark' ? 'dark' : ''} dark:bg-gray-900 text-gray-900 dark:text-white">
  <!-- Header -->
  <header class="bg-gradient-to-r from-indigo-600 to-indigo-900 py-10">
    <div class="container mx-auto px-4">
      <div class="flex flex-col md:flex-row justify-between items-start md:items-center">
        <h1 class="text-3xl font-bold text-white mb-2">#{@title}</h1>
        <div class="mt-4 md:mt-0 space-x-3">
          <button id="themeToggle" class="bg-white/10 text-white px-4 py-2 rounded-lg hover:bg-white/20 transition">
            Toggle theme
          </button>
          <button id="exportPDF" class="bg-white/10 text-white px-4 py-2 rounded-lg hover:bg-white/20 transition">
            Export PDF
          </button>
        </div>
      </div>
    </div>
  </header>

  <main class="container mx-auto px-4 py-8">
    <!-- Stats -->
    <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
      <div class="card p-6">
        <p class="text-gray-500 dark:text-gray-400 mb-1 font-medium">Active Users</p>
        <p class="stat-number text-indigo-600 dark:text-indigo-400">#{@data["summary"]["active_users_count"]}</p>
      </div>
      <div class="card p-6">
        <p class="text-gray-500 dark:text-gray-400 mb-1 font-medium">Total Commits</p>
        <p class="stat-number text-green-600 dark:text-green-400">#{@data["summary"]["total_commits"]}</p>
      </div>
      <div class="card p-6">
        <p class="text-gray-500 dark:text-gray-400 mb-1 font-medium">Total PRs</p>
        <p class="stat-number text-purple-600 dark:text-purple-400">#{@data["summary"]["total_pull_requests"]}</p>
      </div>
    </div>
  
    <!-- Charts -->
    #{charts_section}
    
    <!-- Users Activity -->
    <div class="card p-6 mb-8">
      <h2 class="text-2xl font-bold mb-6">Team Activity</h2>
      <div class="overflow-x-auto">
        <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead>
            <tr>
              <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">User</th>
              <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Organization</th>
              <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Lines Changed</th>
              <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Contribution Weights</th>
              <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Total Score</th>
              <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Details</th>
            </tr>
          </thead>
          <tbody>
            #{generate_user_rows}
          </tbody>
        </table>
      </div>
    </div>
    
    <!-- Summary Dashboard -->
    <div class="flex justify-between items-center mb-6">
      <h1 class="text-2xl font-bold">#{@title || 'GitHub Daily Digest Dashboard'}</h1>
      <div class="flex space-x-2">
        <button id="theme-toggle" class="p-2 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-800 dark:text-gray-200">
          <svg xmlns="http://www.w3.org/2000/svg" class="icon-light hidden h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
            <path d="M17.293 13.293A8 8 0 016.707 2.707a8.001 8.001 0 1010.586 10.586z" />
          </svg>
          <svg xmlns="http://www.w3.org/2000/svg" class="icon-dark h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M10 2a1 1 0 011 1v1a1 1 0 11-2 0V3a1 1 0 011-1zm4 8a4 4 0 11-8 0 4 4 0 018 0zm-.464 4.95l.707.707a1 1 0 001.414-1.414l-.707-.707a1 1 0 00-1.414 1.414zm2.12-10.607a1 1 0 010 1.414l-.706.707a1 1 0 11-1.414-1.414l.707-.707a1 1 0 011.414 0zM17 11a1 1 0 100-2h-1a1 1 0 100 2h1zm-7 4a1 1 0 011 1v1a1 1 0 11-2 0v-1a1 1 0 011-1zM5.05 6.464A1 1 0 106.465 5.05l-.708-.707a1 1 0 00-1.414 1.414l.707.707zm1.414 8.486l-.707.707a1 1 0 01-1.414-1.414l.707-.707a1 1 0 011.414 1.414zM4 11a1 1 0 100-2H3a1 1 0 000 2h1z" clip-rule="evenodd" />
          </svg>
        </button>
      </div>
    </div>
    
    <!-- Summary Dashboard -->
    <div class="card bg-white dark:bg-gray-800 rounded-lg shadow-md p-6 mb-8">
      <h2 class="text-2xl font-bold mb-4">Activity Summary</h2>
      
      <div class="flex flex-col md:flex-row">
        <!-- Time period filter -->
        <div class="mb-4 md:mr-4">
          <label class="block text-sm font-medium mb-1">Time period</label>
          <div class="inline-block border border-gray-300 dark:border-gray-600 rounded-md">
            <p class="px-3 py-2 text-sm">#{@data["summary_statistics"]&.[]("period") || "Last 7 days"}</p>
          </div>
        </div>
      </div>
      
      <!-- Stats Grid -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mt-4">
        <!-- Total Commits -->
        <div class="stat-card bg-gray-50 dark:bg-gray-700/50 p-4 rounded-lg">
          <h3 class="text-sm font-medium text-gray-500 dark:text-gray-400">Total Commits</h3>
          <div class="mt-2">
            <p class="text-4xl font-bold">#{@data["summary_statistics"]&.[]("total_commits") || 0}</p>
          </div>
        </div>
        
        <!-- Lines Changed -->
        <div class="stat-card bg-gray-50 dark:bg-gray-700/50 p-4 rounded-lg">
          <h3 class="text-sm font-medium text-gray-500 dark:text-gray-400">Lines Changed</h3>
          <div class="mt-2">
            <p class="text-4xl font-bold">#{@data["summary_statistics"]&.[]("total_lines_changed") || 0}</p>
          </div>
        </div>
        
        <!-- Active Developers -->
        <div class="stat-card bg-gray-50 dark:bg-gray-700/50 p-4 rounded-lg">
          <h3 class="text-sm font-medium text-gray-500 dark:text-gray-400">Active Developers</h3>
          <div class="mt-2">
            <p class="text-4xl font-bold">#{@data["summary_statistics"]&.[]("active_users_count") || 0}</p>
          </div>
        </div>
        
        <!-- Active Repositories -->
        <div class="stat-card bg-gray-50 dark:bg-gray-700/50 p-4 rounded-lg">
          <h3 class="text-sm font-medium text-gray-500 dark:text-gray-400">Active Repositories</h3>
          <div class="mt-2">
            <p class="text-4xl font-bold">#{@data["summary_statistics"]&.[]("active_repos_count") || 0}</p>
          </div>
        </div>
      </div>
      
      <!-- AI Generated Summary -->
      <div class="mt-6 p-4 bg-gray-50 dark:bg-gray-700/30 rounded-lg">
        <h3 class="text-sm font-medium text-gray-500 dark:text-gray-400 mb-2">AI Summary</h3>
        <p class="text-gray-800 dark:text-gray-200">#{@data["summary_statistics"]&.[]("ai_summary") || "Team showed varied activity across multiple repositories with good collaborative development."}</p>
      </div>
      
      <!-- Advanced Metrics -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
        <!-- Language Distribution -->
        <div class="bg-gray-50 dark:bg-gray-700/50 p-4 rounded-lg">
          <h3 class="text-sm font-medium text-gray-500 dark:text-gray-400 mb-3">Language Distribution</h3>
          <div class="h-64">
            <canvas id="summaryLanguageChart"></canvas>
          </div>
        </div>
        
        <!-- Average Contribution Weights -->
        <div class="bg-gray-50 dark:bg-gray-700/50 p-4 rounded-lg">
          <h3 class="text-sm font-medium text-gray-500 dark:text-gray-400 mb-3">Contribution Metrics (Avg)</h3>
          <div class="h-64">
            <canvas id="avgMetricsChart"></canvas>
          </div>
        </div>
      </div>
    </div>
    
    <!-- Organizations -->
    #{generate_org_sections}
  </main>

  <script>
    // Data for charts
    const userData = #{generate_user_chart_data.to_json};
    const contributionWeightsData = #{generate_contribution_weights_data.to_json};
    const languageDistributionData = #{generate_language_distribution_data.to_json};
    const combinedLanguageData = #{generate_combined_language_data.to_json};
    
    document.addEventListener('DOMContentLoaded', function() {
      // Create User Activity chart
      try {
        const activityCtx = document.getElementById('userActivityChart');
        if (activityCtx) {
          const userLabels = userData.map(user => user.name);
          const commitData = userData.map(user => user.commits);
          const prData = userData.map(user => user.prs);
          const reviewData = userData.map(user => user.reviews);
          
          if (userLabels.length > 0) {
            new Chart(activityCtx, {
              type: 'bar',
              data: {
                labels: userLabels,
                datasets: [
                  {
                    label: 'Commits',
                    data: commitData,
                    backgroundColor: '#4f46e5',
                    borderColor: '#4338ca',
                    borderWidth: 1
                  },
                  {
                    label: 'PRs',
                    data: prData,
                    backgroundColor: '#10b981',
                    borderColor: '#059669',
                    borderWidth: 1
                  },
                  {
                    label: 'Reviews',
                    data: reviewData,
                    backgroundColor: '#f59e0b',
                    borderColor: '#d97706',
                    borderWidth: 1
                  }
                ]
              },
              options: {
                responsive: true,
                maintainAspectRatio: false,
                scales: {
                  y: {
                    beginAtZero: true
                  }
                },
                plugins: {
                  title: {
                    display: true,
                    text: 'User Activity'
                  },
                  legend: {
                    position: 'top'
                  }
                }
              }
            });
          } else {
            // Create empty placeholder chart when no data is available
            activityCtx.parentNode.innerHTML = '<div class="flex items-center justify-center h-full w-full text-gray-400">No activity data available</div>';
          }
        }
        
        // Create Contribution Weights radar chart
        const weightsCtx = document.getElementById('contributionWeightsChart');
        if (weightsCtx && contributionWeightsData.length > 0) {
          new Chart(weightsCtx, {
            type: 'radar',
            data: {
              labels: ['Lines of Code', 'Complexity', 'Technical Depth', 'Scope', 'PR Reviews'],
              datasets: contributionWeightsData.map((user, index) => {
                // Generate a color based on index
                const hue = (index * 137) % 360; // Golden angle approximation for good distribution
                const color = `hsla(${hue}, 70%, 60%, 0.7)`;
                const borderColor = `hsla(${hue}, 70%, 50%, 1)`;
                
                return {
                  label: user.name,
                  data: [
                    user.weights.lines_of_code,
                    user.weights.complexity,
                    user.weights.technical_depth,
                    user.weights.scope,
                    user.weights.pr_reviews
                  ],
                  backgroundColor: color,
                  borderColor: borderColor,
                  borderWidth: 2,
                  pointBackgroundColor: borderColor,
                  pointRadius: 3
                };
              })
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              scales: {
                r: {
                  angleLines: {
                    display: true
                  },
                  suggestedMin: 0,
                  suggestedMax: 10
                }
              },
              plugins: {
                title: {
                  display: true,
                  text: 'Contribution Weights (0-10 scale)'
                },
                legend: {
                  position: 'top'
                }
              }
            }
          });
        } else {
          // Create empty placeholder chart when no data is available
          weightsCtx.parentNode.innerHTML = '<div class="flex items-center justify-center h-full w-full text-gray-400">No contribution weights data available</div>';
        }
        
        // Create Language Distribution combined chart
        const combinedLangCtx = document.getElementById('combinedLanguageDistributionChart');
        if (combinedLangCtx) {
          if (combinedLanguageData.labels && combinedLanguageData.labels.length > 0) {
            new Chart(combinedLangCtx, {
              type: 'doughnut',
              data: {
                labels: combinedLanguageData.labels,
                datasets: [{
                  data: combinedLanguageData.data,
                  backgroundColor: combinedLanguageData.labels.map((_, i) => {
                    const hue = (i * 137) % 360;
                    return `hsla(${hue}, 70%, 60%, 0.7)`;
                  }),
                  borderWidth: 1
                }]
              },
              options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                  title: {
                    display: true,
                    text: 'Team Language Distribution'
                  },
                  legend: {
                    position: 'right',
                    labels: {
                      boxWidth: 15
                    }
                  },
                  tooltip: {
                    callbacks: {
                      label: function(context) {
                        const label = context.label || '';
                        const value = context.raw || 0;
                        return `${label}: ${value.toFixed(1)}%`;
                      }
                    }
                  }
                }
              }
            });
          } else {
            // Create empty placeholder chart when no data is available
            combinedLangCtx.parentNode.innerHTML = '<div class="flex items-center justify-center h-full w-full text-gray-400">No language data available</div>';
          }
        }
        
        // Theme toggle
        document.getElementById('themeToggle').addEventListener('click', function() {
          document.documentElement.classList.toggle('dark');
        });
        
        // PDF Export
        document.getElementById('exportPDF').addEventListener('click', function() {
          window.print();
        });
        
        // Toggle user details
        document.querySelectorAll('.toggle-details').forEach(button => {
          button.addEventListener('click', function() {
            const userRow = this.closest('tr');
            userRow.classList.toggle('expanded');
            this.textContent = userRow.classList.contains('expanded') ? 'Hide' : 'Show';
          });
        });
        
        // Summary statistics
        const summaryStats = #{(@data["summary_statistics"] || {}).to_json};
        
        // Create summary language distribution chart
        const summaryLangCtx = document.getElementById('summaryLanguageChart');
        if (summaryLangCtx && summaryStats && summaryStats.team_language_distribution) {
          const langData = summaryStats.team_language_distribution || {};
          const langLabels = Object.keys(langData);
          const langValues = Object.values(langData);
          
          if (langLabels.length > 0) {
            new Chart(summaryLangCtx, {
              type: 'doughnut',
              data: {
                labels: langLabels,
                datasets: [{
                  data: langValues,
                  backgroundColor: langLabels.map((_, i) => {
                    const hue = (i * 137) % 360;
                    return `hsla(${hue}, 70%, 60%, 0.7)`;
                  }),
                  borderWidth: 1
                }]
              },
              options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                  legend: {
                    position: 'right',
                    labels: {
                      boxWidth: 15,
                      color: document.documentElement.classList.contains('dark') ? '#e5e7eb' : '#374151'
                    }
                  },
                  tooltip: {
                    callbacks: {
                      label: function(context) {
                        const label = context.label || '';
                        const value = context.raw || 0;
                        return `${label}: ${value.toFixed(1)}%`;
                      }
                    }
                  }
                }
              }
            });
          } else {
            summaryLangCtx.parentNode.innerHTML = '<div class="flex items-center justify-center h-full w-full text-gray-400">No language data available</div>';
          }
        } else if (summaryLangCtx) {
          summaryLangCtx.parentNode.innerHTML = '<div class="flex items-center justify-center h-full w-full text-gray-400">No language data available</div>';
        }
        
        // Average Metrics chart
        const avgMetricsCtx = document.getElementById('avgMetricsChart');
        if (avgMetricsCtx && summaryStats && summaryStats.average_weights) {
          const weights = summaryStats.average_weights || {};
          const metricLabels = [
            'Lines of Code', 
            'Complexity',
            'Technical Depth',
            'Scope',
            'PR Reviews'
          ];
          const metricValues = [
            weights.lines_of_code || 0,
            weights.complexity || 0,
            weights.technical_depth || 0,
            weights.scope || 0,
            weights.pr_reviews || 0
          ];
          
          new Chart(avgMetricsCtx, {
            type: 'bar',
            data: {
              labels: metricLabels,
              datasets: [{
                label: 'Average Score (0-10)',
                data: metricValues,
                backgroundColor: [
                  'rgba(99, 102, 241, 0.7)',   // Indigo
                  'rgba(16, 185, 129, 0.7)',   // Green
                  'rgba(245, 158, 11, 0.7)',   // Amber
                  'rgba(236, 72, 153, 0.7)',   // Pink
                  'rgba(79, 70, 229, 0.7)'     // Blue
                ],
                borderColor: [
                  'rgb(79, 70, 229)',
                  'rgb(5, 150, 105)',
                  'rgb(217, 119, 6)',
                  'rgb(219, 39, 119)',
                  'rgb(67, 56, 202)'
                ],
                borderWidth: 1
              }]
            },
            options: {
              responsive: true,
              maintainAspectRatio: false,
              scales: {
                y: {
                  beginAtZero: true,
                  max: 10,
                  grid: {
                    color: document.documentElement.classList.contains('dark') ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.1)'
                  },
                  ticks: {
                    color: document.documentElement.classList.contains('dark') ? '#e5e7eb' : '#374151'
                  }
                },
                x: {
                  grid: {
                    color: document.documentElement.classList.contains('dark') ? 'rgba(255, 255, 255, 0.1)' : 'rgba(0, 0, 0, 0.1)'
                  },
                  ticks: {
                    color: document.documentElement.classList.contains('dark') ? '#e5e7eb' : '#374151'
                  }
                }
              },
              plugins: {
                legend: {
                  display: false
                }
              }
            }
          });
        } else if (avgMetricsCtx) {
          avgMetricsCtx.parentNode.innerHTML = '<div class="flex items-center justify-center h-full w-full text-gray-400">No metrics data available</div>';
        }
      } catch (error) {
        console.error('Error creating charts:', error);
      }
    });
  </script>
</body>
</html>
      HTML
      
      template
    end

    def generate_contribution_weights_data
      return [] unless @data["active_users"] && !@data["active_users"].empty?

      # Get top contributors (limit to 5 for radar chart readability)
      @data["active_users"].select { |user| user["contribution_weights"] && !user["contribution_weights"].empty? }
                           .sort_by { |u| -(u["total_score"] || 0) }
                           .take(5)
                           .map do |user|
        weights = user["contribution_weights"] || {}
        
        # Handle both string and symbol keys to be more robust
        {
          name: user["username"] || user["login"],
          weights: {
            lines_of_code: weights["lines_of_code"].to_i || weights[:lines_of_code].to_i || 0,
            complexity: weights["complexity"].to_i || weights[:complexity].to_i || 0, 
            technical_depth: weights["technical_depth"].to_i || weights[:technical_depth].to_i || 0,
            scope: weights["scope"].to_i || weights[:scope].to_i || 0,
            pr_reviews: weights["pr_reviews"].to_i || weights[:pr_reviews].to_i || 0
          }
        }
      end
    end

    def generate_user_rows
      return "" unless @data["active_users"] && !@data["active_users"].empty?

      rows = []
      @data["active_users"].each do |user|
        username = user["username"] || user["login"]
        weights = user["contribution_weights"] || {}
        
        loc_weight = weights["lines_of_code"].to_i
        complexity_weight = weights["complexity"].to_i
        depth_weight = weights["technical_depth"].to_i
        scope_weight = weights["scope"].to_i
        pr_weight = weights["pr_reviews"].to_i
        
        total_score = user["total_score"] || (loc_weight + complexity_weight + depth_weight + scope_weight + pr_weight)
        
        avatar_url = user["avatar_url"] || "https://ui-avatars.com/api/?name=#{username}&background=random"
        
        # Extract user activity details
        work_details = extract_user_work_details(username)
        
        # Create weight badges
        weight_badges = [
          "<span class=\"badge bg-gray-100 dark:bg-gray-700 mr-1\">LOC: <span class=\"#{weight_color_class(loc_weight)}\">#{loc_weight}</span></span>",
          "<span class=\"badge bg-gray-100 dark:bg-gray-700 mr-1\">Complex: <span class=\"#{weight_color_class(complexity_weight)}\">#{complexity_weight}</span></span>",
          "<span class=\"badge bg-gray-100 dark:bg-gray-700 mr-1\">Depth: <span class=\"#{weight_color_class(depth_weight)}\">#{depth_weight}</span></span>",
          "<span class=\"badge bg-gray-100 dark:bg-gray-700 mr-1\">Scope: <span class=\"#{weight_color_class(scope_weight)}\">#{scope_weight}</span></span>",
          "<span class=\"badge bg-gray-100 dark:bg-gray-700\">PR: <span class=\"#{weight_color_class(pr_weight)}\">#{pr_weight}</span></span>"
        ].join
        
        # Create organization badge
        org_name = user["organization"] || "Unknown"
        organization_badge = "<span class=\"badge bg-indigo-100 text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200\">#{org_name}</span>"
        
        # Create repository badges
        repo_badges = ""
        if @show_repo_details && work_details[:repos] && !work_details[:repos].empty?
          repo_badges = work_details[:repos].map do |repo|
            "<span class=\"badge bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200 mr-1\">#{repo[:name]}</span>"
          end.join
        end
        
        # Language badges 
        language_badges = ""
        if @show_language_details && work_details[:language_distribution] && !work_details[:language_distribution].empty?
          language_badges = work_details[:language_distribution].map do |lang, percent|
            "<span class=\"badge bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200 mr-1\">#{lang}: #{percent.round(1)}%</span>"
          end.join
        end
        
        # Generate detailed work info
        work_details_html = ""
        if @show_work_details
          commits_html = ""
          if work_details[:commits] && !work_details[:commits].empty?
            commits_html = <<-HTML
            <div class="mb-4">
              <h5 class="font-semibold mb-2">Recent Commits</h5>
              <ul class="list-disc pl-5">
                #{work_details[:commits].map { |c| "<li>#{c[:message]}</li>" }.join("\n")}
              </ul>
            </div>
            HTML
          end
          
          prs_html = ""
          if work_details[:prs] && !work_details[:prs].empty?
            prs_html = <<-HTML
            <div class="mb-4">
              <h5 class="font-semibold mb-2">Pull Requests</h5>
              <ul class="list-disc pl-5">
                #{work_details[:prs].map { |pr| "<li>#{pr[:title]} <span class=\"text-xs text-gray-500\">(#{pr[:state]})</span></li>" }.join("\n")}
              </ul>
            </div>
            HTML
          end
          
          work_details_html = commits_html + prs_html
        end
        
        # Determine if details should be initially expanded based on settings
        expanded_class = @show_extended ? " expanded" : ""
        button_text = @show_extended ? "Hide" : "Show"
        
        user_row = <<-ROW
        <tr class="user-row hover:bg-gray-50 dark:hover:bg-gray-900/60#{expanded_class}">
          <td class="px-4 py-4">
            <div class="flex items-center">
              <img src="#{avatar_url}" alt="#{username}" class="w-8 h-8 rounded-full mr-3">
              <span class="font-medium">#{username}</span>
            </div>
          </td>
          <td class="px-4 py-4">#{organization_badge}</td>
          <td class="px-4 py-4">#{user["lines_changed"] || 0}</td>
          <td class="px-4 py-4">#{weight_badges}</td>
          <td class="px-4 py-4"><span class="font-bold text-lg #{score_color_class(total_score)}">#{total_score}</span></td>
          <td class="px-4 py-4">
            <button class="toggle-details px-3 py-1 bg-gray-100 dark:bg-gray-700 rounded text-sm font-medium hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors">
              #{button_text}
            </button>
          </td>
        </tr>
        <tr class="user-row-details bg-gray-50 dark:bg-gray-800/50" data-username="#{username}">
          <td colspan="6" class="px-6 py-4">
            <div class="text-sm">
              <h4 class="font-medium mb-2">Activity Details</h4>
              
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
                <div>
                  <h5 class="font-semibold mb-2">Repositories</h5>
                  <div class="flex flex-wrap gap-1 mb-2">
                    #{repo_badges}
                  </div>
                </div>
                
                <div>
                  <h5 class="font-semibold mb-2">Languages</h5>
                  <div class="flex flex-wrap gap-1">
                    #{language_badges}
                  </div>
                </div>
              </div>
              
              #{work_details_html}
            </div>
          </td>
        </tr>
        ROW
        
        rows << user_row
      end
      
      rows.join("\n")
    end

    def generate_user_chart_data
      return [] unless @data["active_users"] && !@data["active_users"].empty?

      @data["active_users"].map do |user|
        {
          name: user["username"] || user["login"],
          commits: user["commits_count"] || user["commit_count"] || 0,
          prs: user["prs_count"] || user["pr_count"] || 0,
          reviews: user["reviews_count"] || user["review_count"] || 0
        }
      end
    end

    def generate_language_distribution_data
      return [] unless @data["active_users"] && !@data["active_users"].empty?

      @data["active_users"].map do |user|
        # Skip users without language distribution data
        next unless user["language_distribution"] && !user["language_distribution"].empty?
        
        username = user["username"] || user["login"]
        {
          name: username,
          languages: user["language_distribution"].map do |lang, percentage|
            {
              name: lang.to_s,
              percentage: percentage.to_f
            }
          end
        }
      end.compact
    end

    def generate_combined_language_data
      return { labels: [], data: [] } unless @data["active_users"] && !@data["active_users"].empty?

      labels = []
      data = []
      @data["active_users"].each do |user|
        next unless user["language_distribution"] && !user["language_distribution"].empty?
        
        user["language_distribution"].each do |lang, percentage|
          index = labels.find_index(lang)
          if index
            data[index] += percentage.to_f
          else
            labels << lang
            data << percentage.to_f
          end
        end
      end
      
      { labels: labels, data: data }
    end

    def weight_color_class(weight)
      case weight
      when 0..3
        "text-blue-500 dark:text-blue-400"
      when 4..6
        "text-indigo-600 dark:text-indigo-400"
      when 7..8
        "text-purple-600 dark:text-purple-500"
      when 9..10
        "text-red-600 dark:text-red-500"
      else
        "text-gray-600 dark:text-gray-400"
      end
    end
    
    def extract_user_work_details(username)
      details = {
        repos: [],
        commits: [],
        prs: [],
        language_distribution: {}
      }
      
      # Extract repository work
      return details unless @data["organizations"] && !@data["organizations"].empty?
      
      # First, check if we have language distribution data for this user
      @data["active_users"]&.each do |user|
        if (user["username"] == username || user["login"] == username) && user["language_distribution"]
          details[:language_distribution] = user["language_distribution"]
          break
        end
      end
      
      @data["organizations"].each do |org|
        next unless org["repositories"] && !org["repositories"].empty?
        
        org["repositories"].each do |repo|
          # Add to repos if the user worked in this repo
          user_commits = repo["commits"]&.select { |c| (c["author"]&.downcase == username.downcase) || (c["committer"]&.downcase == username.downcase) }
          user_prs = repo["pull_requests"]&.select { |pr| pr["user"]&.downcase == username.downcase }
          
          if (user_commits && !user_commits.empty?) || (user_prs && !user_prs.empty?)
            details[:repos] << {
              name: repo["name"],
              url: repo["url"] || "https://github.com/#{org["name"]}/#{repo["name"]}"
            }
          end
          
          # Add commits
          if user_commits && !user_commits.empty?
            details[:commits] += user_commits.map do |c|
              {
                message: c["message"]&.split("\n")&.first || "No message",
                url: c["url"] || "#",
                sha: c["sha"] || c["id"] || "Unknown"
              }
            end.take(5) # Just show the last 5 commits
          end
          
          # Add PRs
          if user_prs && !user_prs.empty?
            details[:prs] += user_prs.map do |pr|
              {
                title: pr["title"] || "No title",
                url: pr["url"] || "#",
                state: pr["state"] || "unknown",
                number: pr["number"] || "#"
              }
            end.take(5) # Just show the last 5 PRs
          end
        end
      end
      
      # Sort and limit
      details[:commits] = details[:commits].sort_by { |c| c[:sha] }.reverse.take(5)
      details[:prs] = details[:prs].sort_by { |pr| pr[:number].to_s }.reverse.take(5)
      details[:repos] = details[:repos].uniq { |r| r[:name] }
      
      details
    end

    def score_color_class(score)
      case score
      when 0..15
        "text-yellow-600 dark:text-yellow-400"
      when 16..30
        "text-green-600 dark:text-green-400"
      when 31..40
        "text-blue-600 dark:text-blue-400"
      else
        "text-purple-600 dark:text-purple-400"
      end
    end

    def primary_color
      case @theme
      when 'dark'
        '#6366f1' # Indigo
      when 'light'
        '#4f46e5' # Indigo
      else
        '#4f46e5' # Default (Indigo)
      end
    end
    
    def secondary_color
      case @theme
      when 'dark'
        '#10b981' # Emerald
      when 'light'
        '#10b981' # Emerald
      else
        '#10b981' # Default (Emerald)
      end
    end
    
    def accent_color
      case @theme
      when 'dark'
        '#f59e0b' # Amber
      when 'light'
        '#f59e0b' # Amber
      else
        '#f59e0b' # Default (Amber)
      end
    end
    
    def theme_class
      @theme == 'dark' ? 'dark bg-gray-800 text-white' : 'bg-gray-100 text-gray-800'
    end
    
    def dark_class
      @theme == 'dark' ? 'dark:bg-gray-800 dark:text-white' : ''
    end
    
    def text_color
      case @theme
      when 'dark'
        'text-white'
      else
        'text-gray-800'
      end
    end

    def generate_org_sections
      return "" unless @data["organizations"] && !@data["organizations"].empty?

      @data["organizations"].map do |org|
        <<-ORG_SECTION
        <div class="card p-6 mb-8">
          <h2 class="text-2xl font-bold mb-6">#{org["name"]} Organization</h2>
          
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-8">
            <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
              <p class="text-gray-500 dark:text-gray-400 text-sm font-medium">Commits</p>
              <p class="text-xl font-bold text-indigo-600 dark:text-indigo-400">#{org["total_commits"] || 0}</p>
            </div>
            <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
              <p class="text-gray-500 dark:text-gray-400 text-sm font-medium">Pull Requests</p>
              <p class="text-xl font-bold text-purple-600 dark:text-purple-400">#{org["total_pull_requests"] || 0}</p>
            </div>
            <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
              <p class="text-gray-500 dark:text-gray-400 text-sm font-medium">Reviews</p>
              <p class="text-xl font-bold text-green-600 dark:text-green-400">#{org["total_reviews"] || 0}</p>
            </div>
            <div class="bg-gray-50 dark:bg-gray-900/50 p-4 rounded-lg">
              <p class="text-gray-500 dark:text-gray-400 text-sm font-medium">Active Users</p>
              <p class="text-xl font-bold text-blue-600 dark:text-blue-400">#{org["active_users_count"] || 0}</p>
            </div>
          </div>
          
          <!-- Repository Activity Section -->
          #{generate_repo_section(org)}
        </div>
        ORG_SECTION
      end.join("\n")
    end

    def generate_repo_section(org)
      return "" unless org["repositories"] && !org["repositories"].empty?

      <<-REPO_SECTION
      <div>
        <h3 class="text-xl font-semibold mb-4">Repository Activity</h3>
        <div class="overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead>
              <tr>
                <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Repository</th>
                <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Commits</th>
                <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">PRs</th>
                <th class="px-4 py-3 text-left font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wider">Reviews</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200 dark:divide-gray-700">
              #{generate_repo_rows(org["repositories"])}
            </tbody>
          </table>
        </div>
      </div>
      REPO_SECTION
    end

    def generate_repo_rows(repositories)
      repositories.map do |repo|
        repo_url = repo["url"] || ""
        <<-REPO_ROW
        <tr class="hover:bg-gray-50 dark:hover:bg-gray-900/60">
          <td class="px-4 py-4">
            <div>
              <span class="font-medium">#{repo["name"]}</span>
              #{repo_url.empty? ? "" : "<a href=\"#{repo_url}\" class=\"text-xs text-blue-600 dark:text-blue-400 hover:underline block mt-1\">#{repo_url}</a>"}
            </div>
          </td>
          <td class="px-4 py-4">#{repo["commit_count"] || 0}</td>
          <td class="px-4 py-4">#{repo["pr_count"] || 0}</td>
          <td class="px-4 py-4">#{repo["review_count"] || 0}</td>
        </tr>
        REPO_ROW
      end.join("\n")
    end

    # Normalize the data structure to ensure all expected fields exist
    def normalize_data(data)
      # Handle top-level structure, which might be different depending on the source
      normalized = {}
      
      # If data is organized by org (most common case)
      if data.is_a?(Hash) && data.values.first.is_a?(Hash) && !data['summary']
        # Extract first org's data as the default view
        first_org = data.values.first
        
        # Create summary from the first org's meta data
        normalized["summary"] = {
          "active_users_count" => 
            if first_org.key?("_meta") && first_org["_meta"].is_a?(Hash) && first_org["_meta"]["active_users_count"]
              first_org["_meta"]["active_users_count"]
            else
              first_org.values.select { |v| v.is_a?(Hash) }.count
            end,
          "total_commits" => 
            if first_org.key?("_meta") && first_org["_meta"].is_a?(Hash) && first_org["_meta"]["total_commits"]
              first_org["_meta"]["total_commits"]
            elsif first_org.key?("_meta") && first_org["_meta"].is_a?(Hash) && 
                  first_org["_meta"]["repo_stats"].is_a?(Array)
              first_org["_meta"]["repo_stats"].sum { |r| r["total_commits"].to_i }
            else
              0
            end,
          "total_pull_requests" => 
            if first_org.key?("_meta") && first_org["_meta"].is_a?(Hash) && first_org["_meta"]["total_pull_requests"]
              first_org["_meta"]["total_pull_requests"]
            elsif first_org.key?("_meta") && first_org["_meta"].is_a?(Hash) && 
                  first_org["_meta"]["repo_stats"].is_a?(Array)
              first_org["_meta"]["repo_stats"].sum { |r| r["open_prs"].to_i }
            else
              0
            end
        }
        
        # Extract active users
        normalized["active_users"] = []
        data.each do |org_name, org_data|
          next unless org_data.is_a?(Hash)
          
          org_data.each do |username, user_data|
            next if username == "_meta" # Skip metadata
            next unless user_data.is_a?(Hash)
            
            # Only add the user if they have real activity
            changes = user_data["changes"].to_i
            pr_count = user_data["pr_count"].to_i
            
            if changes > 0 || pr_count > 0
              # Create a standardized user structure
              contribution_weights = user_data["contribution_weights"] || {}
              if contribution_weights.is_a?(Hash)
                weights = {
                  "lines_of_code" => contribution_weights["lines_of_code"].to_i,
                  "complexity" => contribution_weights["complexity"].to_i,
                  "technical_depth" => contribution_weights["technical_depth"].to_i,
                  "scope" => contribution_weights["scope"].to_i,
                  "pr_reviews" => contribution_weights["pr_reviews"].to_i
                }
              else
                weights = {
                  "lines_of_code" => 0,
                  "complexity" => 0,
                  "technical_depth" => 0,
                  "scope" => 0,
                  "pr_reviews" => 0
                }
              end
              
              user = {
                "username" => username,
                "commit_count" => changes,
                "pr_count" => pr_count,
                "review_count" => user_data["review_count"].to_i,
                "lines_changed" => user_data["lines_changed"].to_i,
                "avatar_url" => user_data["avatar_url"],
                "contribution_weights" => weights,
                "total_score" => user_data["total_score"].to_i
              }
              
              normalized["active_users"] << user
            end
          end
        end
        
        # Extract organizations data
        normalized["organizations"] = []
        data.each do |org_name, org_data|
          next unless org_data.is_a?(Hash)
          
          # Create organization structure
          org = {
            "name" => org_name,
            "total_commits" => 0,
            "total_pull_requests" => 0,
            "total_reviews" => 0,
            "active_users_count" => 0,
            "repositories" => []
          }
          
          # Extract metadata if available
          if org_data.key?("_meta") && org_data["_meta"].is_a?(Hash)
            org["total_commits"] = org_data["_meta"]["total_commits"].to_i
            org["total_pull_requests"] = org_data["_meta"]["total_pull_requests"].to_i
            org["total_reviews"] = org_data["_meta"]["total_reviews"].to_i
          end
          
          # Count active users
          org["active_users_count"] = org_data.count { |k, v| k != "_meta" && v.is_a?(Hash) }
          
          # Extract repositories if available
          if org_data.key?("_meta") && org_data["_meta"].is_a?(Hash) && 
             org_data["_meta"].key?("repo_stats") && org_data["_meta"]["repo_stats"].is_a?(Array)
            
            org_data["_meta"]["repo_stats"].each do |repo|
              next unless repo.is_a?(Hash)
              
              repo_data = {
                "name" => repo["name"] || "",
                "commit_count" => repo["total_commits"].to_i,
                "pr_count" => repo["open_prs"].to_i,
                "review_count" => 0,
                "url" => ""
              }
              
              # Build GitHub URL if possible
              if repo["path"]
                repo_data["url"] = "https://github.com/#{repo["path"]}"
              end
              
              org["repositories"] << repo_data
            end
          end
          
          normalized["organizations"] << org
        end
      else
        # Data is already normalized or has a different structure
        normalized = data
        
        # Ensure summary exists
        normalized["summary"] ||= {
          "active_users_count" => normalized["active_users"].is_a?(Array) ? normalized["active_users"].size : 0,
          "total_commits" => 0,
          "total_pull_requests" => 0
        }
        
        # Ensure active_users exists
        normalized["active_users"] ||= []
        
        # Ensure organizations exists
        normalized["organizations"] ||= []
      end
      
      # Merge users across organizations
      merged_users = {}
      normalized["active_users"].each do |user|
        username = user["username"]
        unless merged_users[username]
          merged_users[username] = {
            username: username,
            lines_changed: 0,
            total_score: 0,
            contribution_weights: {
              "lines_of_code" => 0,
              "complexity" => 0,
              "technical_depth" => 0,
              "scope" => 0,
              "pr_reviews" => 0
            },
            organizations: [],
            org_details: {}
          }
        end
        
        # Add this organization to the list
        merged_users[username][:org_details][user["organization"]] = {
          data: user,
          lines_changed: user["lines_changed"].to_i
        }
        
        # Add organization to list if not present
        unless merged_users[username][:organizations].include?(user["organization"])
          merged_users[username][:organizations] << user["organization"]
        end
        
        # Add lines changed
        merged_users[username][:lines_changed] += user["lines_changed"].to_i
        
        # Use highest score
        user_score = user["total_score"].to_i
        if user_score > merged_users[username][:total_score]
          merged_users[username][:total_score] = user_score
        end
        
        # Use highest contribution weights
        if user["contribution_weights"].is_a?(Hash)
          weights = user["contribution_weights"]
          ["lines_of_code", "complexity", "technical_depth", "scope", "pr_reviews"].each do |key|
            weight_value = weights[key].to_i rescue 0
            if weight_value > merged_users[username][:contribution_weights][key]
              merged_users[username][:contribution_weights][key] = weight_value
            end
          end
        end
      end
      
      # Replace active_users with merged users
      normalized["active_users"] = merged_users.values.sort_by { |u| -1 * u[:total_score] }
      
      normalized
    end
  end
end

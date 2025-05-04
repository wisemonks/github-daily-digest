module GithubDailyDigest
  class OutputFormatter
    def initialize(config:, logger:)
      @config = config
      @logger = logger
    end

    def format(results, format_type = nil)
      # If a specific format_type is provided, use that
      # Otherwise, use the first format from the config
      output_format = format_type || (@config.output_formats&.first || 'json')
      
      case output_format
      when 'json'
        format_as_json(results)
      when 'markdown'
        format_as_markdown(results)
      when 'html'
        # HTML formatting is handled by HtmlFormatter but we need to recognize it as valid
        format_as_json(results) # Return JSON data that HtmlFormatter will use
      else
        @logger.warn("Unknown output format: #{output_format}, defaulting to JSON")
        format_as_json(results)
      end
    end

    private

    def format_as_json(results)
      JSON.pretty_generate(results)
    end

    def format_as_markdown(results)
      # Create a very simplistic markdown output for robustness
      markdown = "# GitHub Activity Digest\n\n"
      
      # Extract generation time or use current time
      generated_at = if results.is_a?(Hash) && results[:_meta].is_a?(Hash) && results[:_meta][:generated_at].is_a?(String)
                       results[:_meta][:generated_at]
                     else
                       Time.now.strftime("%Y-%m-%d %H:%M:%S")
                     end
      
      markdown << "Generated on: #{generated_at}\n\n"
      
      # Add summary statistics section if available
      if results.is_a?(Hash) && (results["summary_statistics"].is_a?(Hash) || results[:summary_statistics].is_a?(Hash))
        stats = results["summary_statistics"] || results[:summary_statistics]
        
        markdown << "## Summary Statistics\n\n"
        
        # Add AI summary if available
        if stats["ai_summary"].is_a?(String)
          markdown << "> #{stats["ai_summary"]}\n\n"
        end
        
        # Create a summary statistics table
        markdown << "| Metric | Value |\n"
        markdown << "| --- | --- |\n"
        markdown << "| **Time Period** | #{stats["period"] || "Last 7 days"} |\n"
        markdown << "| **Total Commits** | #{stats["total_commits"] || 0} |\n"
        markdown << "| **Total Lines Changed** | #{stats["total_lines_changed"] || 0} |\n"
        markdown << "| **Active Developers** | #{stats["active_users_count"] || 0} |\n"
        markdown << "| **Active Repositories** | #{stats["active_repos_count"] || 0} |\n"
      end
      
      # Add active users section
      markdown << "\n## Active Users\n\n"
      
      # Collect all active users from all organizations and merge by username
      merged_users = {}
      
      if results.is_a?(Hash)
        results.each do |org_name, org_data|
          next if org_name == :_meta || org_name == "_meta" || org_name == "summary_statistics" || !org_data.is_a?(Hash)
          
          # Get users who have activity
          org_data.each do |username, user_data|
            next if username == "_meta" || username == :_meta || !user_data.is_a?(Hash)
            
            # Check if user has any meaningful activity
            has_activity = false
            
            # Check if user has commits
            if user_data["commits"].is_a?(Array) && !user_data["commits"].empty?
              has_activity = true
            end
            
            # Check for various activity indicators
            has_activity ||= user_data["commits_count"].to_i > 0 if user_data["commits_count"]
            has_activity ||= user_data["commit_count"].to_i > 0 if user_data["commit_count"]
            has_activity ||= user_data["prs_count"].to_i > 0 if user_data["prs_count"]
            has_activity ||= user_data["pr_count"].to_i > 0 if user_data["pr_count"]
            has_activity ||= user_data["lines_changed"].to_i > 0 if user_data["lines_changed"]
            
            if has_activity
              # Initialize merged user if doesn't exist
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
              org_details = merged_users[username][:org_details][org_name] = {
                data: user_data,
                lines_changed: user_data["lines_changed"].to_i
              }
              
              # Add organization to list if not present
              unless merged_users[username][:organizations].include?(org_name)
                merged_users[username][:organizations] << org_name
              end
              
              # Add lines changed
              merged_users[username][:lines_changed] += user_data["lines_changed"].to_i
              
              # Use highest score
              user_score = user_data["total_score"].to_i
              if user_score > merged_users[username][:total_score]
                merged_users[username][:total_score] = user_score
              end
              
              # Use highest contribution weights
              if user_data["contribution_weights"].is_a?(Hash)
                weights = user_data["contribution_weights"]
                ["lines_of_code", "complexity", "technical_depth", "scope", "pr_reviews"].each do |key|
                  weight_value = weights[key].to_i rescue 0
                  if weight_value > merged_users[username][:contribution_weights][key]
                    merged_users[username][:contribution_weights][key] = weight_value
                  end
                end
              end
            end
          end
        end
      end
      
      active_users = merged_users.values
      
      if active_users.empty?
        markdown << "No active users found in the specified time period.\n\n"
      else
        # Create a table of active users with scores
        markdown << "| Username | Organizations | Lines Changed | Contribution Score | Code | Complexity | Tech Depth | Scope | Reviews |\n"
        markdown << "| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n"
        
        active_users.sort_by { |u| -1 * u[:total_score] }.each do |user|
          username = user[:username]
          orgs = user[:organizations].join(", ")
          lines_changed = user[:lines_changed]
          score = user[:total_score]
          
          # Extract contribution weights
          weights = user[:contribution_weights]
          code_weight = weights["lines_of_code"].to_i
          complexity_weight = weights["complexity"].to_i
          tech_depth_weight = weights["technical_depth"].to_i
          scope_weight = weights["scope"].to_i
          reviews_weight = weights["pr_reviews"].to_i
          
          markdown << "| #{username} | #{orgs} | #{lines_changed} | #{score} | #{code_weight} | #{complexity_weight} | #{tech_depth_weight} | #{scope_weight} | #{reviews_weight} |\n"
        end
        
        markdown << "\n"
        
        # Add detailed breakdown for each user
        markdown << "## User Activity Details\n\n"
        
        active_users.sort_by { |u| -1 * u[:total_score] }.each do |user|
          username = user[:username]
          orgs = user[:organizations].join(", ")
          
          markdown << "### #{username} (#{orgs})\n\n"
          
          # Collect summaries from all organizations
          summaries = []
          repositories = []
          
          user[:organizations].each do |org_name|
            org_data = user[:org_details][org_name]
            next unless org_data
            
            # Add user summary if available
            if org_data[:data]["summary"].is_a?(String) && !org_data[:data]["summary"].empty?
              summaries << org_data[:data]["summary"]
            end
            
            # Collect repositories
            if org_data[:data]["projects"].is_a?(Array)
              org_data[:data]["projects"].each do |project|
                if project.is_a?(Hash)
                  repo_name = project["name"] || project[:name] || "Unknown repository"
                  commits = project["commits"] || project[:commits] || 0
                  changes = project["lines_changed"] || project[:lines_changed] || 0
                  
                  repositories << {
                    name: repo_name,
                    org: org_name,
                    commits: commits,
                    changes: changes
                  }
                else
                  # Handle case where project is just a string with repo name
                  repo_name = project.to_s
                  repositories << {
                    name: repo_name,
                    org: org_name,
                    commits: 0,
                    changes: 0
                  }
                end
              end
            end
          end
          
          # Output the summary if available
          if summaries.any?
            # Find the longest summary
            best_summary = summaries.max_by(&:length)
            markdown << "> #{best_summary}\n\n"
          end
          
          # Add repositories
          if repositories.any?
            markdown << "**Repositories:**\n\n"
            repositories.each do |repo|
              if repo[:commits] > 0 || repo[:changes] > 0
                markdown << "- #{repo[:name]} (#{repo[:org]}): #{repo[:commits]} commits, #{repo[:changes]} lines changed\n"
              else
                markdown << "- #{repo[:name]} (#{repo[:org]})\n"
              end
            end
            markdown << "\n"
          end
          
          # Add languages if available (combining from all orgs)
          all_languages = {}
          user[:organizations].each do |org_name|
            org_data = user[:org_details][org_name]
            next unless org_data
            
            if org_data[:data]["language_distribution"].is_a?(Hash) && !org_data[:data]["language_distribution"].empty?
              org_data[:data]["language_distribution"].each do |lang, percentage|
                all_languages[lang] ||= 0
                all_languages[lang] += percentage.to_f
              end
            end
          end
          
          if all_languages.any?
            # Normalize percentages
            total = all_languages.values.sum
            all_languages.each { |lang, value| all_languages[lang] = (value / total * 100) }
            
            markdown << "**Languages Used:**\n\n"
            all_languages.sort_by { |_, v| -v }.each do |lang, percentage|
              markdown << "- #{lang}: #{percentage.round(1)}%\n"
            end
            markdown << "\n"
          end
          
          # Add recent commit messages combining from all orgs
          all_commits = []
          user[:organizations].each do |org_name|
            org_data = user[:org_details][org_name]
            next unless org_data
            
            if org_data[:data]["recent_commits"].is_a?(Array) && !org_data[:data]["recent_commits"].empty?
              org_data[:data]["recent_commits"].each do |commit|
                message = commit["message"] || commit[:message]
                repo = commit["repository"] || commit[:repository]
                all_commits << {
                  message: message,
                  repo: repo,
                  org: org_name
                }
              end
            elsif org_data[:data]["commits"].is_a?(Array) && !org_data[:data]["commits"].empty?
              org_data[:data]["commits"].each do |commit|
                message = commit["message"] || commit[:message] || "No message"
                repo = commit["repository"] || commit[:repository] || "Unknown repository"
                all_commits << {
                  message: message,
                  repo: repo,
                  org: org_name
                }
              end
            end
          end
          
          if all_commits.any?
            markdown << "**Recent Work:**\n\n"
            all_commits.take(5).each do |commit|
              markdown << "- #{commit[:repo]} (#{commit[:org]}): #{commit[:message]}\n"
            end
            markdown << "\n"
          end
        end
      end
      
      return markdown
    end

    def self.generate_active_users_table(user_activity, org_activity)
      return "No active users found in this time period." if user_activity.nil? || user_activity.empty?
      
      # Calculate total contribution score for each user based on weights
      user_activity.each do |user|
        analysis = user[:gemini_analysis] || {}
        
        # Get weights from either string or symbol keys
        weights = nil
        if analysis["contribution_weights"].is_a?(Hash)
          weights = analysis["contribution_weights"]
        elsif analysis[:contribution_weights].is_a?(Hash)
          weights = analysis[:contribution_weights]
        else
          weights = {
            "lines_of_code" => 0,
            "complexity" => 0, 
            "technical_depth" => 0,
            "scope" => 0,
            "pr_reviews" => 0
          }
        end
        
        # Calculate total score as sum of all weights
        total_score = 0
        if weights
          if weights.is_a?(Hash)
            total_score += weights["lines_of_code"].to_i rescue 0
            total_score += weights["complexity"].to_i rescue 0
            total_score += weights["technical_depth"].to_i rescue 0
            total_score += weights["scope"].to_i rescue 0
            total_score += weights["pr_reviews"].to_i rescue 0
          end
        end
        
        # Use the total_score from analysis if it exists, otherwise use calculated score
        if analysis["total_score"].to_i > 0
          total_score = analysis["total_score"].to_i
        elsif analysis[:total_score].to_i > 0
          total_score = analysis[:total_score].to_i
        end
        
        # Store the total score for sorting
        user[:total_contribution_score] = total_score
      end
      
      # Sort users by total contribution score (highest to lowest)
      sorted_users = user_activity.sort_by { |user| -user[:total_contribution_score].to_i }
      
      user_rows = []
      
      # Create rows for each user
      sorted_users.each do |user|
        # Use the gemini analysis if available, otherwise use fallback values
        analysis = user[:gemini_analysis] || {}
        commits = user[:commit_count] || 0
        
        # Get projects from either string or symbol key
        projects = analysis["projects"] || analysis[:projects] || []
        # Display projects as a comma-separated list, or "N/A" if none
        project_list = projects.empty? ? "N/A" : (projects.is_a?(Array) ? projects.join(", ") : projects.to_s)
        
        # Get weights from either string or symbol keys
        weights = analysis["contribution_weights"] || analysis[:contribution_weights] || {}
        
        # Format the weights as a visual indicator
        loc_weight = weights["lines_of_code"].to_i rescue 0
        complexity_weight = weights["complexity"].to_i rescue 0
        depth_weight = weights["technical_depth"].to_i rescue 0
        scope_weight = weights["scope"].to_i rescue 0
        pr_weight = weights["pr_reviews"].to_i rescue 0
        
        total_score = user[:total_contribution_score].to_i
        
        # Format contribution score with visual indicator
        score_display = case total_score
                        when 30..50
                          "🔥 #{total_score}" # High contribution
                        when 15..29
                          "👍 #{total_score}" # Medium contribution
                        else
                          "#{total_score}"    # Low contribution
                        end
        
        # Format the weights table
        weights_display = "LOC: #{loc_weight} | Complexity: #{complexity_weight} | Depth: #{depth_weight} | Scope: #{scope_weight} | PR: #{pr_weight}"
        
        # Get other fields from either string or symbol keys
        pr_count = analysis["pr_count"] || analysis[:pr_count] || 0
        lines_changed = analysis["lines_changed"] || analysis[:lines_changed] || 0
        summary = analysis["summary"] || analysis[:summary] || "N/A"
        
        # Create row with user info and stats
        user_rows << "| #{user[:username]} | #{commits} | #{pr_count} | #{lines_changed} | #{score_display} | #{weights_display} | #{summary} | #{project_list} |"
      end
      
      # Create the table with headers and all rows
      <<~MARKDOWN
      ## Active Users

      Users are sorted by their total contribution score, which is calculated as the sum of individual contribution weights.
      Each contribution weight is on a scale of 0-10 and considers different aspects of contribution value.

      | User | Commits | PRs | Lines Changed | Total Score | Contribution Weights | Summary | Projects |
      |------|---------|-----|---------------|-------------|----------------------|---------|----------|
      #{user_rows.join("\n")}
      
      MARKDOWN
    end

    def self.generate_combined_user_table(combined_users, users_with_gemini_activity, inactive_users, commits_by_user)
      return "No active users found in this time period." if combined_users.nil? || combined_users.empty?
      
      # Calculate total contribution score for each user based on weights
      combined_users.each do |username, user_data|
        next if username == :_meta
        
        # Get weights from various potential sources
        weights = nil
        if users_with_gemini_activity[username] && users_with_gemini_activity[username][:contribution_weights]
          weights = users_with_gemini_activity[username][:contribution_weights]
        elsif user_data[:contribution_weights]
          weights = user_data[:contribution_weights]
        else
          # Create default weights based on activity
          commits = user_data[:commits].to_i || 0
          pr_reviews = user_data[:pr_reviews].to_i || 0
          lines_changed = user_data[:lines_changed].to_i || 0
          project_count = user_data[:projects].size || 0
          
          # Create appropriate weights based on activity metrics
          loc_weight = if lines_changed > 20000
                         8
                       elsif lines_changed > 10000
                         6
                       elsif lines_changed > 5000
                         4
                       elsif lines_changed > 1000
                         2
                       else
                         1
                       end
                       
          scope_weight = if project_count > 4
                           8
                         elsif project_count > 2
                           5
                         elsif project_count > 0
                           3
                         else
                           1
                         end
                         
          commit_weight = if commits > 50
                            8
                          elsif commits > 20
                            6
                          elsif commits > 10
                            4
                          else
                            1
                          end
                          
          pr_weight = if pr_reviews > 20
                        8
                      elsif pr_reviews > 10
                        6
                      elsif pr_reviews > 5
                        4
                      else
                        1
                      end
          
          # Provide reasonable default weights
          weights = {
            "lines_of_code" => loc_weight,
            "complexity" => [commit_weight, 3].min,
            "technical_depth" => 3,
            "scope" => scope_weight,
            "pr_reviews" => pr_weight
          }
        end
        
        # Calculate total score as sum of weights
        total_score = 0
        if weights
          if weights.is_a?(Hash)
            total_score += weights["lines_of_code"].to_i rescue 0
            total_score += weights["complexity"].to_i rescue 0
            total_score += weights["technical_depth"].to_i rescue 0
            total_score += weights["scope"].to_i rescue 0
            total_score += weights["pr_reviews"].to_i rescue 0
          end
        end
        
        # Store the weights and total score
        user_data[:contribution_weights] = weights
        user_data[:total_contribution_score] = total_score
      end
      
      # Sort users by contribution score (highest to lowest)
      sorted_users = combined_users.keys.reject { |username| username == :_meta }.sort_by do |username|
        # Return a tuple for sorting: active users first, then by total score
        # Negative values ensure descending order
        user_data = combined_users[username]
        has_activity = users_with_gemini_activity.key?(username) || commits_by_user.key?(username)
        total_score = user_data[:total_contribution_score] || 0
        
        [-1 * (has_activity ? 1 : 0), -1 * total_score]
      end
      
      user_rows = []
      
      # Create rows for each user
      sorted_users.each do |username|
        user_data = combined_users[username]
        
        # Format project names in a more readable way
        projects = user_data[:projects].to_a if user_data[:projects]
        project_names = if projects&.any?
                         projects.map { |p| p.split('/').last }.join(', ')
                       else
                         "-"
                       end
        
        # Format the output fields with defaults
        commits = user_data[:commits] || 0
        pr_reviews = user_data[:pr_reviews] || 0
        lines_changed = user_data[:lines_changed] || 0
        total_score = user_data[:total_contribution_score] || 0
        
        # Format contribution score with visual indicator
        score_display = case total_score
                        when 30..50
                          "🔥 #{total_score}" # High contribution
                        when 15..29
                          "👍 #{total_score}" # Medium contribution
                        else
                          "#{total_score}"    # Low contribution
                        end
        
        # Format the weights
        weights = user_data[:contribution_weights] || {}
        loc_weight = weights["lines_of_code"].to_i || weights[:lines_of_code].to_i || 0
        complexity_weight = weights["complexity"].to_i || weights[:complexity].to_i || 0
        depth_weight = weights["technical_depth"].to_i || weights[:technical_depth].to_i || 0
        scope_weight = weights["scope"].to_i || weights[:scope].to_i || 0
        pr_weight = weights["pr_reviews"].to_i || weights[:pr_reviews].to_i || 0
        
        weights_display = "LOC: #{loc_weight} | Complexity: #{complexity_weight} | Depth: #{depth_weight} | Scope: #{scope_weight} | PR: #{pr_weight}"
        
        user_rows << "| **#{username}** | #{commits} | #{pr_reviews} | #{lines_changed} | #{score_display} | #{weights_display} | #{project_names} |"
      end
      
      # Create the table with headers and all rows
      <<~MARKDOWN
      ## Active Users

      Users are sorted by their total contribution score, which is calculated as the sum of individual contribution weights.
      Each contribution weight is on a scale of 0-10 and considers different aspects of contribution value.

      | User | Commits | PR Reviews | Lines Changed | Total Score | Contribution Weights | Projects |
      |------|---------|------------|---------------|-------------|----------------------|----------|
      #{user_rows.join("\n")}
      
      MARKDOWN
    end

    # Process data from all organizations and extract user activity information
    def self.process_data(results, logger = nil)
      logger ||= Logger.new($stdout)
      
      # Combined user activity across all organizations
      combined_users = {}
      
      # Users with Gemini-analyzed activity data
      users_with_gemini_activity = {}
      
      # Collect all users with commit data
      commits_by_user = {}
      
      # Skip specific keys that aren't organizations
      skip_keys = ["_meta", :_meta, "summary_statistics", :summary_statistics]
      
      # Get all organizations from the results
      organizations = results.keys.select do |k| 
        !skip_keys.include?(k)
      end
      
      # Collect all users across all organizations
      organizations.each do |org_name|
        next if skip_keys.include?(org_name)
        
        # Skip if this is not an organization data hash
        next unless results[org_name].is_a?(Hash)
        
        if results[org_name].key?("users")
          org_users = results[org_name]["users"]
          logger.info("Processing organization #{org_name} with #{org_users.keys.size} users")
          
          org_users.each do |username, user_data|
            next if username == :_meta || username == "_meta" # Skip metadata entries
            next unless user_data.is_a?(Hash)
            
            combined_users[username] ||= {
              commits: 0,
              pr_reviews: 0,
              projects: Set.new,
              organizations: Set.new,
              contribution_score: 0,
              lines_changed: 0,
            }
            
            # Add organization name
            combined_users[username][:organizations].add(org_name)
            
            # Add commit count - ensure it's an integer
            commits = user_data[:changes].to_i rescue 0
            commits = user_data["changes"].to_i if commits == 0 && user_data["changes"]
            
            combined_users[username][:commits] += commits
            
            # Track commits by user
            if commits > 0
              commits_by_user[username] ||= 0
              commits_by_user[username] += commits
            end
            
            # Extract PR count and add it
            pr_count = user_data[:pr_count].to_i rescue 0
            pr_count = user_data["pr_count"].to_i if pr_count == 0 && user_data["pr_count"]
            
            combined_users[username][:pr_reviews] += pr_count
            
            # Extract total score if available
            if user_data[:total_score].to_i > 0 
              combined_users[username][:contribution_score] = [
                combined_users[username][:contribution_score],
                user_data[:total_score].to_i
              ].max
            elsif user_data["total_score"].to_i > 0
              combined_users[username][:contribution_score] = [
                combined_users[username][:contribution_score],
                user_data["total_score"].to_i
              ].max
            end
            
            # Extract lines changed
            lines_changed = user_data[:lines_changed].to_i rescue 0
            lines_changed = user_data["lines_changed"].to_i if lines_changed == 0 && user_data["lines_changed"]
            
            combined_users[username][:lines_changed] += lines_changed
            
            # Extract projects data
            if user_data[:projects] || user_data["projects"]
              extracted_projects = user_data[:projects] || user_data["projects"] || []
              if extracted_projects.is_a?(Array) 
                extracted_projects.each do |project|
                  combined_users[username][:projects].add(project) if project && !project.empty?
                end
              elsif extracted_projects.is_a?(String)
                combined_users[username][:projects].add(extracted_projects) if !extracted_projects.empty?
              end
            end
            
            # Check for Gemini activity data
            has_activity = commits > 0 || 
                           combined_users[username][:contribution_score] > 0 || 
                           lines_changed > 0 || 
                           pr_count > 0
            
            # Save Gemini analysis data if it exists
            if has_activity
              logger.info("User #{username} has Gemini activity data")
              
              users_with_gemini_activity[username] ||= {
                changes: 0,
                contribution_score: 0,
                lines_changed: 0,
                pr_count: 0,
                projects: [],
                summary: "",
                org_name: org_name,
                contribution_weights: {
                  "lines_of_code" => 0,
                  "complexity" => 0,
                  "technical_depth" => 0,
                  "scope" => 0,
                  "pr_reviews" => 0
                }
              }
              
              # Update with this organization's data
              users_with_gemini_activity[username][:changes] += commits if commits > 0
              users_with_gemini_activity[username][:pr_count] += pr_count if pr_count > 0
              
              # Extract total score if available
              if user_data[:total_score].to_i > 0 
                users_with_gemini_activity[username][:contribution_score] = [
                  users_with_gemini_activity[username][:contribution_score],
                  user_data[:total_score].to_i
                ].max
              elsif user_data["total_score"].to_i > 0
                users_with_gemini_activity[username][:contribution_score] = [
                  users_with_gemini_activity[username][:contribution_score],
                  user_data["total_score"].to_i
                ].max
              end
              
              users_with_gemini_activity[username][:lines_changed] += lines_changed if lines_changed > 0
              
              # Extract contribution weights if they exist
              if user_data[:contribution_weights].is_a?(Hash) || user_data["contribution_weights"].is_a?(Hash)
                weights = user_data[:contribution_weights] || user_data["contribution_weights"]
                
                if weights.is_a?(Hash)
                  # Copy each weight, using the highest value if it already exists
                  ["lines_of_code", "complexity", "technical_depth", "scope", "pr_reviews"].each do |key|
                    # Try string or symbol key in the source weights
                    weight_value = weights[key].to_i rescue weights[key.to_sym].to_i rescue 0
                    
                    # Update if the new value is higher
                    current_value = users_with_gemini_activity[username][:contribution_weights][key].to_i
                    if weight_value > current_value
                      users_with_gemini_activity[username][:contribution_weights][key] = weight_value
                    end
                  end
                  
                  logger.debug("Updated contribution_weights for #{username}: #{users_with_gemini_activity[username][:contribution_weights].inspect}")
                end
              end
              
              # Calculate total score if not already set
              if users_with_gemini_activity[username][:contribution_score] == 0
                total = 0
                users_with_gemini_activity[username][:contribution_weights].each do |key, value|
                  total += value.to_i
                end
                users_with_gemini_activity[username][:contribution_score] = total
                logger.debug("Calculated total score for #{username}: #{total}")
              end
              
              # Extract summary
              if user_data[:summary] || user_data["summary"]
                summary = user_data[:summary] || user_data["summary"]
                if summary && !summary.empty? && summary != "No activity detected in the specified time window."
                  users_with_gemini_activity[username][:summary] = summary
                end
              end
              
              # Add projects
              if user_data[:projects] || user_data["projects"]
                extracted_projects = user_data[:projects] || user_data["projects"] || []
                if extracted_projects.is_a?(Array)
                  users_with_gemini_activity[username][:projects] += extracted_projects
                elsif extracted_projects.is_a?(String) && !extracted_projects.empty?
                  users_with_gemini_activity[username][:projects] << extracted_projects
                end
                
                # Ensure uniqueness of projects
                users_with_gemini_activity[username][:projects].uniq!
              end
            end
          end
        end
      end
      
      # Get all active users (those with any activity)
      active_users = combined_users.keys.reject { |username| username == :_meta }
      
      # Get inactive users (those without activity in active_users)
      inactive_users = combined_users.keys.reject { |username| username == :_meta }
      
      # Return all processed data
      [combined_users, users_with_gemini_activity, inactive_users, commits_by_user]
    end
  end
end

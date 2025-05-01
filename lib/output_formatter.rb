module GithubDailyDigest
  class OutputFormatter
    def initialize(config:, logger:)
      @config = config
      @logger = logger
    end

    def format(results)
      case @config.output_format
      when 'json'
        format_as_json(results)
      when 'markdown'
        format_as_markdown(results)
      else
        @logger.warn("Unknown output format: #{@config.output_format}, defaulting to JSON")
        format_as_json(results)
      end
    end

    private

    def format_as_json(results)
      JSON.pretty_generate(results)
    end

    def format_as_markdown(results)
      @logger.debug("Starting markdown formatting")
      
      markdown = "# GitHub Activity Digest\n\n"
      markdown << "Generated on: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
      
      # Process all organizations and combine user data
      combined_users, users_with_gemini_activity, inactive_users, commits_by_user = self.class.process_data(results, @logger)
      
      # Calculate overall statistics
      total_commits = 0
      total_prs = 0
      total_active_users = 0
      total_repos = 0
      active_repos = []
      
      results.each do |org_name, org_data|
        next if org_name == :_meta
        
        # Skip if org_data is not a hash
        next unless org_data.is_a?(Hash)
        
        # Count users with changes > 0
        active_users_in_org = 0
        
        org_data.each do |user_key, user_data|
          # Skip metadata and non-hash user data
          next if user_key == :_meta || !user_data.is_a?(Hash)
          
          changes = 0
          changes = user_data[:changes].to_i if user_data[:changes]
          changes = user_data["changes"].to_i if user_data["changes"] && changes == 0
          
          active_users_in_org += 1 if changes > 0
        end
        
        total_active_users += active_users_in_org
        
        # Get repository statistics if available
        if org_data[:_meta] && org_data[:_meta][:repo_stats]
          repo_stats = org_data[:_meta][:repo_stats]
          
          if repo_stats.is_a?(Array)
            repo_stats.each do |repo|
              next unless repo.is_a?(Hash)
              
              total_repos += 1
              total_commits += repo[:total_commits].to_i if repo[:total_commits]
              total_prs += repo[:open_prs].to_i if repo[:open_prs]
              
              if repo[:total_commits].to_i > 0 && repo[:name]
                active_repos << "#{org_name}/#{repo[:name]}"
              end
            end
          elsif repo_stats.is_a?(Hash)
            # Handle case where repo_stats is a hash instead of an array
            repo_stats.each do |repo_name, stats|
              next unless stats.is_a?(Hash)
              
              total_repos += 1
              total_commits += stats[:total_commits].to_i if stats[:total_commits]
              total_prs += stats[:open_prs].to_i if stats[:open_prs]
              
              if stats[:total_commits].to_i > 0
                active_repos << "#{org_name}/#{repo_name}"
              end
            end
          end
        end
      end
      
      # Add overview information
      markdown << "## Overview\n\n"
      markdown << "| Category | Value |\n"
      markdown << "| --- | --- |\n"
      
      if results.key?(:error)
        markdown << "## Error\n\n"
        markdown << "#{results[:error]}\n\n"
        return markdown
      end
      
      # Determine time period from time_since format
      time_period = if @config.time_since
        begin
          since_time = Time.parse(@config.time_since)
          days_ago = ((Time.now - since_time) / 86400).round
          if days_ago < 2
            "Last 24 hours"
          else
            "Last #{days_ago} days"
          end
        rescue
          "Recent activity"
        end
      else
        "Recent activity"
      end
      
      # Get all organizations from the results
      organizations = results.keys.reject { |k| k == :_meta }
      
      markdown << "| **Time Period** | #{time_period} |\n"
      markdown << "| **Organizations** | #{organizations.join(', ')} |\n"
      markdown << "| **Data Source** | #{results[:_meta] && results[:_meta][:api_type] ? results[:_meta][:api_type] : 'GitHub API'} |\n\n"
      
      # Add trending repositories section if available
      if results[:_meta] && results[:_meta][:trending_repos] && !results[:_meta][:trending_repos].empty?
        markdown << "## Trending Repositories\n\n"
        markdown << "| Repository | Activity Score | Commits | PRs | Issues | Stars |\n"
        markdown << "| --- | --- | --- | --- | --- | --- |\n"
        
        results[:_meta][:trending_repos].each do |repo|
          markdown << "| **#{repo[:full_name]}** | #{repo[:activity_score]} | #{repo[:commits]} | #{repo[:pull_requests]} | #{repo[:issues]} | #{repo[:stars]} |\n"
        end
        
        markdown << "\n"
      end
      
      # If we have Gemini analysis, display it with users sorted by contribution score
      if users_with_gemini_activity && !users_with_gemini_activity.empty?
        user_activity = []
        
        # Convert to the format expected by the active users table
        users_with_gemini_activity.each do |username, analysis|
          user_activity << {
            username: username,
            commit_count: analysis[:changes] || 0,
            gemini_analysis: analysis
          }
        end
        
        markdown << self.class.generate_active_users_table(user_activity, results)
      else
        # Use traditional user activity table if no Gemini analysis
        markdown << self.class.generate_combined_user_table(combined_users, users_with_gemini_activity, inactive_users, commits_by_user)
      end
      
      # Skip organization-specific detail for concise output
      return markdown if @config.concise_output
      
      # Add organization-specific information
      organizations.each do |org_name|
        org_data = results[org_name]
        next if org_data.nil? || !org_data.is_a?(Hash) || org_data.empty?
        
        markdown << "## #{org_name.to_s} Organization Summary\n\n"
        
        # Calculate statistics for this organization
        active_user_count = 0
        active_repos_in_org = []
        
        org_data.each do |username, user_data|
          next if username == :_meta
          
          if user_data.is_a?(Hash)
            changes = user_data[:changes].to_i rescue 0
            active_user_count += 1 if changes > 0
          end
        end
        
        # Organization Summary Table
        markdown << "| Metric | Value |\n"
        markdown << "| --- | --- |\n"
        markdown << "| Active Users | #{active_user_count} |\n"
        
        # Add repository statistics if available
        if org_data[:_meta] && org_data[:_meta][:repo_stats]
          repo_stats = org_data[:_meta][:repo_stats]
          active_repos_count = 0
          total_org_commits = 0
          
          if repo_stats.is_a?(Array)
            active_repos_count = repo_stats.count { |r| r[:total_commits].to_i > 0 if r.is_a?(Hash) }
            total_org_commits = repo_stats.sum { |r| r[:total_commits].to_i if r.is_a?(Hash) }
            
            repo_stats.each do |repo|
              next unless repo.is_a?(Hash) && repo[:total_commits].to_i > 0
              active_repos_in_org << repo[:name] if repo[:name]
            end
          elsif repo_stats.is_a?(Hash)
            active_repos_count = repo_stats.count { |_, r| r[:total_commits].to_i > 0 if r.is_a?(Hash) }
            total_org_commits = repo_stats.sum { |_, r| r[:total_commits].to_i if r.is_a?(Hash) }
            
            repo_stats.each do |repo_name, repo|
              next unless repo.is_a?(Hash) && repo[:total_commits].to_i > 0
              active_repos_in_org << repo_name
            end
          end
          
          markdown << "| Active Repositories | #{active_repos_count} |\n"
          markdown << "| Total Commits | #{total_org_commits} |\n"
        end
        
        markdown << "\n"
        
        # User activity in this organization
        active_users = org_data.keys.select do |username|
          next if username == :_meta
          user_data = org_data[username]
          next unless user_data.is_a?(Hash)
          
          # User is active if they have any changes
          changes = user_data[:changes].to_i rescue 0
          changes > 0
        end
        
        if active_user_count > 0
          markdown << "#### User Activity\n\n"
          markdown << "| User | Commits | PR Reviews | Contribution Score | Summary |\n"
          markdown << "| --- | --- | --- | --- | --- |\n"
          
          # Create table rows for active users
          active_users.each do |username|
            user_data = org_data[username]
            
            # Skip users with no changes
            next unless user_data[:changes].to_i > 0 || user_data[:pr_count].to_i > 0
            
            # Create table row
            markdown << "| **#{username}** | #{user_data[:changes]} | #{user_data[:pr_count]} | #{user_data[:contribution_score]} | #{user_data[:summary]} |\n"
          end
          
          markdown << "\n"
        end
        
        # Repository activity in this organization if available
        if org_data[:_meta] && org_data[:_meta][:repo_stats] && org_data[:_meta][:repo_stats].any?
          markdown << "#### Repository Activity\n\n"
          markdown << "| Repository | Commits | PRs | Contributors |\n"
          markdown << "| --- | --- | --- | --- |\n"
          
          repo_stats = org_data[:_meta][:repo_stats]
          
          if repo_stats.is_a?(Array)
            repo_stats.each do |repo|
              next unless repo.is_a?(Hash)
              
              markdown << "| #{repo[:name]} | #{repo[:total_commits]} | #{repo[:open_prs]} | #{repo[:contributors_count]} |\n"
            end
          elsif repo_stats.is_a?(Hash)
            repo_stats.each do |repo_name, repo|
              next unless repo.is_a?(Hash)
              
              markdown << "| #{repo_name} | #{repo[:total_commits]} | #{repo[:open_prs]} | #{repo[:contributors_count]} |\n"
            end
          end
          
          markdown << "\n"
        end
      end
      
      # Inactive users across all organizations
      inactive_users = combined_users.keys.reject { |username| active_users.include?(username) || username == :_meta }
      
      if inactive_users.any?
        markdown << "### Inactive Users (Across All Organizations)\n\n"
        markdown << "| Username | Organizations |\n"
        markdown << "| --- | --- |\n"
        
        inactive_users.each do |username|
          next if username == :_meta  # Skip metadata in inactive users list
          user_data = combined_users[username]
          orgs = user_data[:organizations].to_a.join(', ')
          markdown << "| #{username} | #{orgs} |\n"
        end
        
        markdown << "\n"
      end
      
      markdown
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
          total_score += weights["lines_of_code"].to_i rescue 0
          total_score += weights["complexity"].to_i rescue 0
          total_score += weights["technical_depth"].to_i rescue 0
          total_score += weights["scope"].to_i rescue 0
          total_score += weights["pr_reviews"].to_i rescue 0
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
            total_score += weights["lines_of_code"].to_i || weights[:lines_of_code].to_i || 0
            total_score += weights["complexity"].to_i || weights[:complexity].to_i || 0
            total_score += weights["technical_depth"].to_i || weights[:technical_depth].to_i || 0
            total_score += weights["scope"].to_i || weights[:scope].to_i || 0
            total_score += weights["pr_reviews"].to_i || weights[:pr_reviews].to_i || 0
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
      
      # Get all organizations from the results
      organizations = results.keys.reject { |k| k == :_meta }
      
      # Collect all users across all organizations
      organizations.each do |org_name|
        next if org_name == :_meta  # Skip metadata in organizations list
        org_data = results[org_name]
        next if org_data.nil? || !org_data.is_a?(Hash) || org_data.empty?
        
        logger.info("Processing organization #{org_name} with #{org_data.keys.size} users")
        
        org_data.each do |username, user_data|
          next if username == :_meta # Skip metadata entries
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
      
      # Get all active users (those with any activity)
      active_users = combined_users.keys.reject { |username| username == :_meta }
      
      # Get inactive users (those without activity in active_users)
      inactive_users = combined_users.keys.reject { |username| username == :_meta }
      
      # Return all processed data
      [combined_users, users_with_gemini_activity, inactive_users, commits_by_user]
    end
  end
end

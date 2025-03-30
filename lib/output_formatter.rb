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
      # DEBUG: Output the entire results structure to understand what we're working with
      @logger.info("DEBUG: Full results structure keys: #{results.keys.inspect}")
      results.each do |org_name, org_data|
        unless org_name == :_meta
          @logger.info("Organization #{org_name} has #{org_data.keys.size} user entries")
          org_data.each do |username, user_data|
            @logger.info("  User #{username} raw data: #{user_data.inspect}")
          end
        end
      end
      
      markdown = "# GitHub Activity Digest\n\n"
      markdown << "Generated on: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
      
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
      organizations = results.keys
      
      markdown << "## Overview\n\n"
      markdown << "| Category | Value |\n"
      markdown << "| --- | --- |\n"
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
      
      # Combined user activity across all organizations
      combined_users = {}
      
      # Collect all users across all organizations
      organizations.each do |org_name|
        next if org_name == :_meta  # Skip metadata in organizations list
        org_data = results[org_name]
        next if org_data.empty?
        
        @logger.info("Processing organization #{org_name} with #{org_data.keys.size} users")
        
        org_data.each do |username, user_data|
          @logger.info("  User #{username} data: #{user_data.inspect}")
          
          combined_users[username] ||= {
            commits: 0,
            pr_reviews: 0,
            projects: Set.new,
            organizations: Set.new,
            complexity_score: 0,
            lines_changed: 0,
            spent_time: nil
          }
          
          # Add organization name
          combined_users[username][:organizations].add(org_name)
          
          # Add commit count - ensure it's an integer
          commits = user_data[:changes].to_i 
          @logger.info("  User #{username} commits: #{commits} (raw: #{user_data[:changes].inspect})")
          combined_users[username][:commits] += commits
          
          # Extract PR count and add it
          pr_count = user_data[:pr_count].to_i rescue 0
          @logger.info("  User #{username} PR reviews: #{pr_count} (raw: #{user_data[:pr_count].inspect})")
          combined_users[username][:pr_reviews] += pr_count
          
          # Track highest complexity score across all orgs
          complexity_score = user_data[:complexity_score].to_i rescue 0
          combined_users[username][:complexity_score] = [combined_users[username][:complexity_score], complexity_score].max
          
          # Keep the longest time estimate
          if user_data[:spent_time].to_s.strip != ""
            # Time estimate ranking (longer times have higher priority)
            time_ranks = {
              "1-3 hours" => 1,
              "3-6 hours" => 2,
              "6-12 hours" => 3,
              "12-24 hours" => 4,
              "24-36 hours" => 5,
              "36-60 hours" => 6,
              "60+ hours" => 7
            }
            
            current_rank = time_ranks[combined_users[username][:spent_time]] || 0
            new_rank = time_ranks[user_data[:spent_time]] || 0
            
            if new_rank > current_rank
              combined_users[username][:spent_time] = user_data[:spent_time]
            end
          end
          
          # Add lines changed (extract from summary or use estimate)
          # First try to get total from the user data if available
          if user_data[:lines_changed].to_i > 0
            combined_users[username][:lines_changed] += user_data[:lines_changed].to_i
          else
            # Estimate lines based on complexity and commit count
            # These are rough estimates if actual data isn't available
            lines_per_commit = case combined_users[username][:complexity_score]
                             when 80..100 then 100
                             when 50..79 then 50
                             else 20
                             end
            combined_users[username][:lines_changed] += user_data[:changes].to_i * lines_per_commit
          end
          
          # Add projects
          if user_data[:projects]&.any?
            user_data[:projects].each do |project|
              combined_users[username][:projects].add(project)
            end
          end
        end
      end
      
      # Debug entire combined users collection
      @logger.info("COMBINED USERS DEBUG: #{combined_users.inspect}")
      
      # Now identify users with Gemini-analyzed activity data
      # These might not have raw commit data but still have activity
      users_with_gemini_activity = {}
      organizations.each do |org_name|
        next if org_name == :_meta
        org_data = results[org_name] || {}
        
        org_data.each do |username, user_data|
          next unless user_data.is_a?(Hash)
          next if username == :_meta # Skip metadata entries
          
          # Debug raw data to understand its structure
          @logger.debug("Raw data for #{username} in #{org_name}: #{user_data.inspect}")
          
          # Handle both symbol and string keys in data
          # Extract relevant fields respecting both formats
          has_changes = false
          changes = 0
          complexity_score = 0
          spent_time = nil
          lines_changed = 0
          pr_count = 0
          projects = []
          
          # Extract data handling both symbol and string keys, as well as different structures
          if user_data[:changes].to_i > 0 || (user_data["changes"].to_i > 0 if user_data["changes"])
            has_changes = true
            changes = user_data[:changes].to_i if user_data[:changes]
            changes = user_data["changes"].to_i if user_data["changes"] && changes == 0
          end
          
          if user_data[:complexity_score].to_i > 0 || (user_data["complexity_score"].to_i > 0 if user_data["complexity_score"])
            complexity_score = user_data[:complexity_score].to_i if user_data[:complexity_score]
            complexity_score = user_data["complexity_score"].to_i if user_data["complexity_score"] && complexity_score == 0
          end
          
          if user_data[:spent_time] || user_data["spent_time"]
            spent_time = user_data[:spent_time].to_s if user_data[:spent_time]
            spent_time = user_data["spent_time"].to_s if user_data["spent_time"] && !spent_time
          end
          
          if user_data[:lines_changed].to_i > 0 || (user_data["lines_changed"].to_i > 0 if user_data["lines_changed"])
            lines_changed = user_data[:lines_changed].to_i if user_data[:lines_changed]
            lines_changed = user_data["lines_changed"].to_i if user_data["lines_changed"] && lines_changed == 0
          end
          
          if user_data[:pr_count].to_i > 0 || (user_data["pr_count"].to_i > 0 if user_data["pr_count"])
            pr_count = user_data[:pr_count].to_i if user_data[:pr_count]
            pr_count = user_data["pr_count"].to_i if user_data["pr_count"] && pr_count == 0
          end
          
          # Extract projects data
          if user_data[:projects] || user_data["projects"]
            extracted_projects = user_data[:projects] || user_data["projects"] || []
            if extracted_projects.is_a?(Array) 
              projects = extracted_projects
            elsif extracted_projects.is_a?(String)
              projects = [extracted_projects]
            end
          end
          
          # Check for any activity indicators
          has_activity = has_changes || 
                         complexity_score > 0 || 
                         spent_time && !spent_time.empty? && spent_time != "0 hours" || 
                         lines_changed > 0 || 
                         pr_count > 0 ||
                         projects.any?
          
          if has_activity
            @logger.info("User #{username} has Gemini activity data")
            
            # Store all the extracted data
            users_with_gemini_activity[username] = {
              changes: changes,
              complexity_score: complexity_score,
              spent_time: spent_time,
              lines_changed: lines_changed,
              pr_count: pr_count,
              projects: projects,
              org_name: org_name
            }
            
            # Use the data from Gemini analysis to populate the combined_users hash
            combined_users[username] ||= {
              commits: 0,
              pr_reviews: 0,
              complexity_score: 0,
              lines_changed: 0,
              spent_time: "N/A",
              projects: Set.new,
              organizations: Set.new
            }
            
            # Update combined_users with the extracted data
            combined_users[username][:commits] += changes if changes > 0
            combined_users[username][:pr_reviews] += pr_count if pr_count > 0
            combined_users[username][:complexity_score] = complexity_score if complexity_score > 0
            combined_users[username][:lines_changed] += lines_changed if lines_changed > 0
            combined_users[username][:spent_time] = spent_time if spent_time && !spent_time.empty? && spent_time != "0 hours"
            
            # Add projects
            if projects.any?
              projects.each do |project|
                combined_users[username][:projects].add(project) if project && !project.empty?
              end
            end
            
            # Make sure organization is added
            combined_users[username][:organizations].add(org_name)
          end
        end
      end
      
      @logger.info("Users with Gemini activity data: #{users_with_gemini_activity.keys.inspect}")
      @logger.debug("Detailed Gemini activity data: #{users_with_gemini_activity.inspect}")
      
      # Combine both types of users to get a complete list of active users
      # Make sure to exclude the :_meta entry
      active_users = combined_users.keys.reject { |username| username == :_meta }
      @logger.info("All active users (combined): #{active_users.inspect}")
      
      # Create combined section
      markdown << "## Combined User Activity\n\n"
      
      # Table of combined user activity
      markdown << "| User | Commits | PR Reviews | Changed Lines | Estimated Time | Complexity Score | Projects |\n"
      markdown << "| --- | --- | --- | --- | --- | --- | --- |\n"
      
      # Get all users with any commits
      commits_by_user = {}
      organizations.each do |org_name|
        next if org_name == :_meta
        org_data = results[org_name] || {}
        
        org_data.each do |username, user_data|
          next unless user_data.is_a?(Hash)
          next if username == :_meta # Skip metadata entries
          
          # Handle both symbol and string keys
          changes = 0
          changes += user_data[:changes].to_i if user_data[:changes]
          changes += user_data["changes"].to_i if user_data["changes"]
          
          if changes > 0
            commits_by_user[username] ||= 0
            commits_by_user[username] += changes
          end
        end
      end
      
      @logger.info("Users with commits: #{commits_by_user.inspect}")
      
      # Prioritize users with activity
      active_users_with_priority = active_users.sort_by do |username|
        # Sort by: has activity data, complexity score, commits
        has_activity = users_with_gemini_activity.key?(username) || commits_by_user.key?(username)
        complexity = combined_users[username][:complexity_score] || 0
        commits = combined_users[username][:commits] || 0
        
        # Return a tuple for sorting: active users first, then by complexity, then by commits
        # Negative values ensure descending order
        [-1 * (has_activity ? 1 : 0), -1 * complexity, -1 * commits]
      end
      
      # Now add all these users to the table
      active_users_with_priority.each do |username|
        user_data = combined_users[username] || {}
        
        # Get Gemini activity data for this user, if available
        gemini_data = users_with_gemini_activity[username]
        
        # Debug output this user's data
        @logger.debug("Final data for #{username}: combined=#{user_data.inspect}, gemini=#{gemini_data.inspect}")
        
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
        spent_time = user_data[:spent_time].nil? || user_data[:spent_time].empty? ? "N/A" : user_data[:spent_time]
        complexity_score = user_data[:complexity_score] || 0
        
        markdown << "| **#{username}** | #{commits} | #{pr_reviews} | #{lines_changed} | #{spent_time} | #{complexity_score} | #{project_names} |\n"
      end
      
      # Mark these users as active
      active_users = active_users_with_priority
      
      # Display user profiles if available
      if results[:_meta] && results[:_meta][:user_profiles] && !results[:_meta][:user_profiles].empty?
        markdown << "### Developer Profiles\n\n"
        markdown << "| User | Name | Company | Location | Bio |\n"
        markdown << "| --- | --- | --- | --- | --- |\n"
        
        # Show profiles for active users first
        active_users.each do |username|
          if results[:_meta][:user_profiles][username]
            profile = results[:_meta][:user_profiles][username]
            name = profile[:name] || "-"
            company = profile[:company] || "-"
            location = profile[:location] || "-"
            bio = profile[:bio] ? profile[:bio].gsub("\n", " ").truncate(50) : "-"
            
            markdown << "| **#{username}** | #{name} | #{company} | #{location} | #{bio} |\n"
          end
        end
        
        markdown << "\n"
      end
      
      # Inactive users across all organizations
      # IMPORTANT: Only users not in active_users should be in inactive_users
      inactive_users = combined_users.keys.reject { |username| active_users.include?(username) || username == :_meta }
      
      @logger.info("Inactive users: #{inactive_users.inspect}")
      
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
      
      # Return concise output if configured that way
      return markdown if @config.concise_output
      
      # Repository Statistics if available
      if results[:_meta] && results[:_meta][:repo_stats] && !results[:_meta][:repo_stats].empty?
        markdown << "## Repository Statistics\n\n"
        markdown << "| Repository | Stars | Forks | Size (KB) | Primary Language | Last Updated |\n"
        markdown << "| --- | --- | --- | --- | --- | --- |\n"
        
        # Sort repos by stars (descending)
        sorted_repos = results[:_meta][:repo_stats].keys.sort_by do |repo_name|
          -results[:_meta][:repo_stats][repo_name][:stars].to_i
        end
        
        sorted_repos.each do |repo_name|
          repo = results[:_meta][:repo_stats][repo_name]
          lang = repo[:primary_language] ? repo[:primary_language][:name] : "-"
          updated = repo[:updated_at] ? Time.parse(repo[:updated_at]).strftime("%Y-%m-%d") : "-"
          
          markdown << "| **#{repo_name}** | #{repo[:stars]} | #{repo[:forks]} | #{repo[:size]} | #{lang} | #{updated} |\n"
        end
        
        markdown << "\n"
      end
      
      # Detailed Project Involvement
      if active_users.any?
        markdown << "## Detailed Project Involvement\n\n"
        
        active_users.each do |username|
          user_data = combined_users[username]
          next unless user_data[:projects].any?
          
          markdown << "### #{username}\n\n"
          markdown << "| Organization | Repository |\n"
          markdown << "| --- | --- |\n"
          
          user_data[:projects].to_a.sort.each do |project|
            # Extract organization name from project (format: org/repo)
            parts = project.split('/')
            if parts.size >= 2
              org = parts[0]
              repo = parts[1..-1].join('/')
              markdown << "| #{org} | #{repo} |\n"
            else
              markdown << "| - | #{project} |\n"
            end
          end
          
          markdown << "\n"
        end
      end
      
      # Original per-organization sections
      markdown << "## Activity By Organization\n\n"
      
      # Process each organization
      organizations.each do |org_name|
        next if org_name == :_meta # Skip metadata
        org_data = results[org_name]
        
        # Skip if org data is empty
        next if org_data.empty?
        
        markdown << "### Organization: #{org_name}\n\n"
        
        # Count active users for this organization
        active_users = org_data.keys.select { |username| !org_data[username][:changes].to_i.zero? }.count
        total_users = org_data.keys.count
        
        markdown << "#### Organization Summary\n\n"
        markdown << "| Metric | Value |\n"
        markdown << "| --- | --- |\n"
        markdown << "| **Total Users** | #{total_users} |\n"
        markdown << "| **Active Users** | #{active_users} |\n\n"
        
        # Sort users by activity level (changes + PR reviews)
        sorted_users = org_data.keys.sort_by do |username| 
          activity_level = org_data[username][:changes].to_i
          activity_level += org_data[username][:pr_count].to_i rescue 0
          -activity_level # Negative to sort in descending order
        end
        
        # Only show activity section if there are active users
        active_user_count = sorted_users.count { |username| 
          org_data[username][:changes].to_i > 0 || org_data[username][:pr_count].to_i > 0
        }
        
        if active_user_count > 0
          markdown << "#### User Activity\n\n"
          markdown << "| User | Commits | PR Reviews | Estimated Time | Complexity Score | Summary |\n"
          markdown << "| --- | --- | --- | --- | --- | --- |\n"
          
          # Create table rows for active users
          sorted_users.each do |username|
            user_data = org_data[username]
            
            # Skip users with no activity
            next unless user_data[:changes].to_i > 0 || user_data[:pr_count].to_i > 0
            
            # Create table row
            markdown << "| **#{username}** | #{user_data[:changes]} | #{user_data[:pr_count]} | #{user_data[:spent_time]} | #{user_data[:complexity_score]} | #{user_data[:summary]} |\n"
          end
          
          markdown << "\n"
          
          # Add detailed sections for users with projects
          markdown << "#### Project Details\n\n"
          
          sorted_users.each do |username|
            user_data = org_data[username]
            
            # Skip users with no activity or no projects
            next unless (user_data[:changes].to_i > 0 || user_data[:pr_count].to_i > 0)
            next unless user_data[:projects]&.any?
            
            markdown << "##### #{username}\n\n"
            
            if user_data[:_generated_by] == "fallback_system"
              markdown << "*Note: This analysis was generated using the fallback system due to AI service unavailability.*\n\n"
            end
            
            markdown << "**Projects:**\n\n"
            markdown << "| Repository |\n"
            markdown << "| --- |\n"
            
            user_data[:projects].each do |project|
              markdown << "| #{project} |\n"
            end
            
            markdown << "\n"
          end
        end
        
        # Users without activity
        inactive_users = sorted_users.select { |username| org_data[username][:changes].to_i == 0 && org_data[username][:pr_count].to_i == 0 }
        
        if inactive_users.any?
          markdown << "#### Inactive Users\n\n"
          markdown << "| Username |\n"
          markdown << "| --- |\n"
          
          inactive_users.each do |username|
            markdown << "| #{username} |\n"
          end
          
          markdown << "\n"
        end
      end
      
      markdown
    end
  end
end

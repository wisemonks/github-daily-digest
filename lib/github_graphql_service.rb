# github_daily_digest/lib/github_graphql_service.rb
require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'ostruct'

module GithubDailyDigest
  class GithubGraphQLService
    # GitHub GraphQL API endpoint
    GITHUB_API_URL = 'https://api.github.com/graphql'
    
    # New query to fetch commits from all branches
    ALL_BRANCH_COMMITS_QUERY = <<-'GRAPHQL'
      query OrgAllBranchesChanges($orgName: String!, $since: GitTimestamp!, $repoCursor: String, $refCursor: String, $commitCursor: String) {
        organization(login: $orgName) {
          repositories(first: 10, after: $repoCursor) { # Adjust repo page size as needed
            pageInfo {
              hasNextPage
              endCursor
            }
            nodes {
              name
              refs(refPrefix: "refs/heads/", first: 50, after: $refCursor) { # Adjust branch page size
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  name
                  target {
                    ... on Commit {
                      history(since: $since, first: 100, after: $commitCursor) { # Adjust commit page size
                        pageInfo {
                          hasNextPage
                          endCursor
                        }
                        nodes {
                          oid
                          message
                          committedDate
                          author {
                            name
                            email
                            user {
                              login
                            }
                          }
                          additions
                          deletions
                          changedFiles
                          # Fetch associated pull requests (optional, can be heavy)
                          # associatedPullRequests(first: 1) {
                          #   nodes {
                          #     number
                          #     title
                          #   }
                          # }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL
    
    def initialize(token:, logger:, config:)
      @token = token
      @logger = logger
      @config = config
      @current_org_name = config.github_org_name.to_s.split(',').first
      
      # Set up HTTP client for GraphQL communication
      @uri = URI.parse(GITHUB_API_URL)
      @http = Net::HTTP.new(@uri.host, @uri.port)
      @http.use_ssl = true
      
      # Initialize request headers
      @headers = {
        'Authorization' => "Bearer #{token}",
        'Content-Type' => 'application/json',
        'User-Agent' => 'GitHub-Daily-Digest/1.0'
      }
      
      verify_authentication
    rescue => e
      @logger.fatal("GitHub GraphQL initialization failed: #{e.message}")
      raise
    end
    
    def fetch_members(org_name)
      @logger.info("Fetching members for organization: #{org_name} via GraphQL")
      
      query_string = <<-GRAPHQL
        query($org_name: String!) {
          organization(login: $org_name) {
            membersWithRole(first: 100) {
              nodes {
                login
                name
              }
            }
          }
        }
      GRAPHQL
      
      response = execute_query(query_string, variables: { org_name: org_name })
      
      if response && response["data"] && response["data"]["organization"] && response["data"]["organization"]["membersWithRole"]
        members = response["data"]["organization"]["membersWithRole"]["nodes"].map { |node| node["login"] }
        @logger.info("Found #{members.count} members via GraphQL.")
        members
      else
        @logger.error("Could not fetch members for #{org_name} via GraphQL.")
        [] # Return empty array on failure
      end
    rescue => e
      @logger.error("Failed to fetch organization members: #{e.message}")
      []
    end
    
    def fetch_active_repos(org_name, since_time)
      @logger.info("Fetching active repositories for organization: #{org_name} since #{since_time} via GraphQL")
      
      since_time_formatted = Time.parse(since_time.to_s).iso8601
      
      query_string = <<-GRAPHQL
        query($org_name: String!, $since_date: GitTimestamp!) {
          organization(login: $org_name) {
            repositories(first: 50) {
              nodes {
                name
                nameWithOwner
                isPrivate
                isFork
                createdAt
                updatedAt
                stargazerCount
                forkCount
                diskUsage
                languages(first: 10, orderBy: {field: SIZE, direction: DESC}) {
                  edges {
                    size
                    node {
                      name
                      color
                    }
                  }
                }
                defaultBranchRef {
                  name
                }
              }
            }
          }
        }
      GRAPHQL
      
      response = execute_query(query_string, variables: { 
        org_name: org_name,
        since_date: since_time_formatted
      })
      
      active_repos = {}
      
      if response && response["data"] && response["data"]["organization"]
        repos = response["data"]["organization"]["repositories"]["nodes"]
        total_count = response["data"]["organization"]["repositories"]["totalCount"]
        
        @logger.info("Found #{repos.size} repositories (out of #{total_count} total) in #{org_name}")
        
        repos.each do |repo|
          repo_full_name = repo["nameWithOwner"]
          
          # Extract primary language
          primary_language = nil
          if repo["languages"] && repo["languages"]["edges"] && !repo["languages"]["edges"].empty?
            lang_edge = repo["languages"]["edges"][0]
            primary_language = {
              name: lang_edge["node"]["name"],
              color: lang_edge["node"]["color"],
              size: lang_edge["size"]
            }
          end
          
          # Build stats object
          repo_stats = {
            name: repo["name"],
            full_name: repo_full_name,
            private: repo["isPrivate"],
            fork: repo["isFork"],
            created_at: repo["createdAt"],
            updated_at: repo["updatedAt"],
            stars: repo["stargazerCount"],
            forks: repo["forkCount"],
            size: repo["diskUsage"],
            default_branch: repo["defaultBranchRef"] ? repo["defaultBranchRef"]["name"] : nil,
            primary_language: primary_language
          }
          
          # Check if the repository has been updated since the given time
          if Time.parse(repo["updatedAt"]) >= Time.parse(since_time)
            active_repos[repo_full_name] = repo_stats
          end
        end
      end
      
      if active_repos.empty?
        @logger.warn("No active repositories found with commits since #{since_time}")
      else
        @logger.info("Found #{active_repos.size} active repositories with commits via GraphQL")
      end
      
      active_repos
    rescue => e
      @logger.error("Failed to fetch active repos via GraphQL: #{e.message}")
      {}
    end
    
    def fetch_pull_request_reviews(org_name, since_time)
      @logger.info("Fetching pull request reviews for organization: #{org_name} since #{since_time} via GraphQL")
      
      # Convert since_time to ISO8601 format string
      since_iso8601 = if since_time.is_a?(Time)
                        since_time.iso8601
                      elsif since_time.is_a?(String)
                        # Assume it's already in a valid format for the GraphQL API
                        since_time
                      else
                        # Fallback to current time minus 7 days if invalid
                        @logger.warn("Invalid since_time format: #{since_time.inspect}, using default (7 days ago)")
                        (Time.now - 7*24*60*60).iso8601
                      end
    
      # Parse the since time for filtering
      since_time_parsed = Time.parse(since_iso8601) rescue Time.now - 7*24*60*60
    
      # Reduce the query size to avoid hitting the node limit (505,050 > 500,000)
      # We'll fetch fewer repositories per page and fewer PRs per repository
      query_string = <<-GRAPHQL
        query FetchPRReviews($orgName: String!) {
          organization(login: $orgName) {
            repositories(first: 25) {
              nodes {
                name
                nameWithOwner
                pullRequests(first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
                  nodes {
                    number
                    title
                    url
                    createdAt
                    updatedAt
                    author {
                      login
                    }
                    reviews(first: 20) {
                      nodes {
                        author {
                          login
                        }
                        submittedAt
                        state
                      }
                    }
                  }
                }
              }
            }
          }
        }
      GRAPHQL
    
      response = execute_query(query_string, variables: { 
        orgName: org_name
      })
    
      user_reviews = {}
    
      if response && response["data"] && response["data"]["organization"]
        repos = response["data"]["organization"]["repositories"]["nodes"]
    
        repos.each do |repo|
          repo_name = repo["nameWithOwner"]
    
          if repo["pullRequests"] && repo["pullRequests"]["nodes"]
            repo["pullRequests"]["nodes"].each do |pr|
              # Filter by the since_time_parsed after we get the data
              pr_updated_at = Time.parse(pr["updatedAt"]) rescue nil
              next unless pr_updated_at && pr_updated_at >= since_time_parsed
            
              if pr["reviews"] && pr["reviews"]["nodes"]
                pr["reviews"]["nodes"].each do |review|
                  review_submitted_at = Time.parse(review["submittedAt"]) rescue nil
                  next unless review_submitted_at && review_submitted_at >= since_time_parsed
                  next unless review["author"] && review["author"]["login"]
    
                  reviewer = review["author"]["login"]
                  user_reviews[reviewer] ||= []
    
                  user_reviews[reviewer] << {
                    repo: repo_name,
                    pr_number: pr["number"],
                    pr_title: pr["title"],
                    pr_url: pr["url"],
                    submitted_at: review["submittedAt"],
                    state: review["state"]
                  }
                end
              end
            end
          end
        end
      end
    
      @logger.info("Found #{user_reviews.keys.size} users with PR reviews")
      user_reviews.each do |username, reviews|
        @logger.info("User #{username} has #{reviews.size} PR reviews")
      end
    
      user_reviews
    rescue => e
      @logger.error("Failed to fetch PR reviews via GraphQL: #{e.message}")
      {}
    end
    
    # Fetches commits from ALL branches across all repos in the organization since a given time
    def fetch_all_branch_commits(org_name, since_time)
      @logger.info("Fetching commits from all branches for organization: #{org_name} since #{since_time} via GraphQL")
      all_commits = []
      repo_cursor = nil
      repo_has_next_page = true
      repo_count = 0
      max_repos_to_process = 100 # Increased from 50 to allow for more repos

      # Convert since_time to ISO8601 format string
      # Handle both Time objects and strings
      since_iso8601 = if since_time.is_a?(Time)
                        since_time.iso8601
                      elsif since_time.is_a?(String)
                        # Assume it's already in a valid format for the GraphQL API
                        since_time
                      else
                        # Fallback to current time minus 7 days if invalid
                        @logger.warn("Invalid since_time format: #{since_time.inspect}, using default (7 days ago)")
                        (Time.now - 7*24*60*60).iso8601
                      end

      @logger.info("Starting to fetch repositories for organization: #{org_name}")
    
      while repo_has_next_page && repo_count < max_repos_to_process
        repo_count += 1
        @logger.info("Fetching repository page #{repo_count} for organization: #{org_name}")
    
        repo_page_variables = { orgName: org_name, since: since_iso8601, repoCursor: repo_cursor }
        repo_response = execute_query(ALL_BRANCH_COMMITS_QUERY, variables: repo_page_variables)
    
        unless repo_response && repo_response['data'] && repo_response['data']['organization'] && repo_response['data']['organization']['repositories']
          @logger.error("Failed to fetch repositories or invalid response structure: #{repo_response.inspect}")
          break
        end

        repos_data = repo_response['data']['organization']['repositories']
        repo_page_info = repos_data['pageInfo']
        repo_has_next_page = repo_page_info['hasNextPage']
        repo_cursor = repo_page_info['endCursor']

        @logger.info("Processing #{repos_data['nodes'].size} repositories from page #{repo_count}")

        repos_data['nodes'].each_with_index do |repo_node, repo_index|
          repo_name = repo_node['name']
          @logger.info("Processing repository #{repo_index + 1}/#{repos_data['nodes'].size}: #{repo_name}")
    
          # Skip if no refs data is available
          unless repo_node['refs'] && repo_node['refs']['nodes']
            @logger.warn("No refs found for repo: #{repo_name}")
            next
          end
    
          # Process each branch with pagination support
          branch_cursor = nil
          branch_has_next_page = repo_node['refs']['pageInfo']['hasNextPage']
          branch_nodes = repo_node['refs']['nodes']
          
          # Process initial set of branches
          process_branches_for_repo(repo_name, branch_nodes, all_commits)
          
          # Continue fetching more branches if available
          while branch_has_next_page
            @logger.info("Fetching additional branches for repo: #{repo_name}")
            branch_variables = { 
              orgName: org_name, 
              since: since_iso8601, 
              repoCursor: nil,  # We're targeting a specific repo
              refCursor: branch_cursor 
            }
            
            branch_response = execute_query(ALL_BRANCH_COMMITS_QUERY, variables: branch_variables)
            
            # Break if we can't get valid branch data
            unless branch_response && branch_response['data'] && 
                   branch_response['data']['organization'] && 
                   branch_response['data']['organization']['repositories'] &&
                   branch_response['data']['organization']['repositories']['nodes']
              @logger.error("Failed to fetch additional branches or invalid response")
              break
            end
            
            # Get the specific repo from the response
            target_repo = nil
            branch_response['data']['organization']['repositories']['nodes'].each do |repo|
              if repo['name'] == repo_name
                target_repo = repo
                break
              end
            end
            
            # No target repo found, break
            unless target_repo && target_repo['refs']
              @logger.warn("Couldn't find #{repo_name} in the branch pagination response")
              break
            end
            
            # Process the new set of branches
            branch_nodes = target_repo['refs']['nodes']
            branch_page_info = target_repo['refs']['pageInfo']
            branch_has_next_page = branch_page_info['hasNextPage']
            branch_cursor = branch_page_info['endCursor']
            
            # Process this page of branches
            process_branches_for_repo(repo_name, branch_nodes, all_commits)
          end
        end

        @logger.info("Processed repository page #{repo_count}, found #{all_commits.size} commits so far. Next page: #{repo_has_next_page}")
        
        # Remove break statement to process all repository pages
        # break unless repo_has_next_page
      end

      @logger.info("Completed fetching commits. Found #{all_commits.size} commits across all branches since #{since_time}")
      all_commits
    end
    
    # Helper method to process branches for a repository
    def process_branches_for_repo(repo_name, branch_nodes, all_commits)
      branch_count = 0
      
      branch_nodes.each do |ref_node|
        branch_count += 1
        branch_name = ref_node['name']
        @logger.debug("Processing branch #{branch_count}: #{branch_name} in repo: #{repo_name}")

        target = ref_node['target']
        next unless target && target['history'] && target['history']['nodes']

        # Process each commit in this branch with pagination
        process_commits_for_branch(repo_name, branch_name, target['history'], all_commits)
        
        # Handle commit pagination
        commit_cursor = target['history']['pageInfo']['endCursor'] 
        commit_has_next_page = target['history']['pageInfo']['hasNextPage']
        
        # Fetch additional pages of commits if available
        while commit_has_next_page
          @logger.debug("Fetching additional commits for #{repo_name}/#{branch_name}")
          
          # Fetch the next page of commits
          commit_variables = {
            owner: repo_name.split('/').first,
            name: repo_name.split('/').last,
            branch: branch_name,
            since: since_time.is_a?(Time) ? since_time.iso8601 : since_time,
            cursor: commit_cursor,
            limit: 100
          }
          
          # This query would need to be defined elsewhere or use a different approach
          # For now we'll log that we would fetch more commits
          @logger.info("Would fetch additional commits for #{repo_name}/#{branch_name} after cursor #{commit_cursor}")
          
          # Break for now - this would need a separate implementation
          break
        end
      end
      
      if branch_count > 0
        @logger.info("Processed #{branch_count} branches in #{repo_name}")
      end
    end
    
    # Helper method to process commits for a branch
    def process_commits_for_branch(repo_name, branch_name, history_data, all_commits)
      commit_count = 0
      commit_found = false

      # Process each commit in this branch
      history_data['nodes'].each do |commit_node|
        commit_count += 1
        commit_found = true

        # Extract author details - handle both formats
        # First try the user.login format from the GraphQL query
        github_login = commit_node.dig('author', 'user', 'login')

        # If that's not available, fall back to name/email
        author_details = if github_login
                           # If we have a GitHub login, use that as the primary identifier
                           { name: github_login, email: nil }
                         else
                           # Otherwise use the name/email from the commit
                           { 
                             name: commit_node.dig('author', 'name'),
                             email: commit_node.dig('author', 'email')
                           }
                         end

        # Create the commit payload with nested structure
        commit_payload = {
          repo: repo_name,
          branch: branch_name,
          commit: {
            oid: commit_node['oid'],
            message: commit_node['message'],
            committedDate: commit_node['committedDate'],
            author: author_details,
            additions: commit_node['additions'],
            deletions: commit_node['deletions'],
            changedFiles: commit_node['changedFiles'] || 0
          }
        }

        # Log the author information for debugging
        @logger.debug("Commit in #{repo_name}/#{branch_name} by author: #{author_details[:name] || 'unknown'}")

        all_commits << commit_payload
      end

      if commit_found
        @logger.info("Found #{commit_count} commits in #{repo_name}/#{branch_name}")
      end
    end
    
    # Maps commits to users
    def map_commits_to_users(commits) # Takes the structured commits from fetch_all_branch_commits
      @logger.info("Mapping commits to users")
      user_commits = Hash.new { |h, k| h[k] = [] }

      commits.each do |commit_data|
        commit = commit_data[:commit]
        next unless commit && commit[:author] # Ensure commit and author data exist

        # Use author's name as the key, fallback to email if name is nil/empty
        author_name = commit[:author][:name]
        author_email = commit[:author][:email]
        username = (author_name && !author_name.strip.empty?) ? author_name : author_email

        # Skip if no valid identifier found (name or email)
        next unless username && !username.strip.empty?

        # Use email as a key if the name is generic like "GitHub" or "GitHub Action"
        if ['GitHub', 'GitHub Action', 'github-actions[bot]'].include?(username) && author_email && !author_email.empty?
          username = author_email
        end

        # Skip common bot emails unless they are the only identifier
        if username.end_with?('[bot]@users.noreply.github.com') && !(author_name && !author_name.strip.empty?)
           # Allow bot commits if they have a specific name, otherwise potentially skip
           # Or decide how to handle bot commits specifically
           @logger.debug("Skipping potential bot commit without specific author name: #{author_email}")
           # next # Uncomment this line to skip bot commits without specific names
        end


        user_commits[username] << {
          repo: commit_data[:repo],
          branch: commit_data[:branch],
          sha: commit[:oid],
          message: commit[:message],
          date: Time.parse(commit[:committedDate]),
          stats: { additions: commit[:additions], deletions: commit[:deletions] },
          files: commit[:changedFiles] # changedFiles is the count
        }
      end

      @logger.info("Mapped commits from #{user_commits.keys.size} unique users/emails")
      user_commits
    end
    
    # Fetch repository statistics for a specific organization
    def fetch_repository_stats(org_name, since_time = nil)
      @logger.info("Fetching repository statistics for organization: #{org_name} via GraphQL")
      
      # Convert since_time to ISO8601 format string if provided
      since_iso8601 = if since_time
                        if since_time.is_a?(Time)
                          since_time.iso8601
                        elsif since_time.is_a?(String)
                          since_time
                        else
                          nil
                        end
                      else
                        nil
                      end
    
      query_string = <<-GRAPHQL
        query FetchRepoStats($orgName: String!) {
          organization(login: $orgName) {
            repositories(first: 100) {
              totalCount
              nodes {
                name
                nameWithOwner
                isPrivate
                isFork
                createdAt
                updatedAt
                stargazerCount
                forkCount
                diskUsage
                languages(first: 10, orderBy: {field: SIZE, direction: DESC}) {
                  edges {
                    size
                    node {
                      name
                      color
                    }
                  }
                }
                defaultBranchRef {
                  name
                }
              }
            }
          }
        }
      GRAPHQL
    
      response = execute_query(query_string, variables: { 
        orgName: org_name
      })
    
      active_repos = {}
    
      if response && response["data"] && response["data"]["organization"]
        repos = response["data"]["organization"]["repositories"]["nodes"]
        total_count = response["data"]["organization"]["repositories"]["totalCount"]
        
        @logger.info("Found #{repos.size} repositories (out of #{total_count} total) in #{org_name}")
        
        repos.each do |repo|
          repo_full_name = repo["nameWithOwner"]
          
          # Extract primary language
          primary_language = nil
          if repo["languages"] && repo["languages"]["edges"] && !repo["languages"]["edges"].empty?
            lang_edge = repo["languages"]["edges"][0]
            primary_language = {
              name: lang_edge["node"]["name"],
              color: lang_edge["node"]["color"],
              size: lang_edge["size"]
            }
          end
          
          # Build stats object
          repo_stats = {
            name: repo["name"],
            full_name: repo_full_name,
            private: repo["isPrivate"],
            fork: repo["isFork"],
            created_at: repo["createdAt"],
            updated_at: repo["updatedAt"],
            stars: repo["stargazerCount"],
            forks: repo["forkCount"],
            size: repo["diskUsage"],
            default_branch: repo["defaultBranchRef"] ? repo["defaultBranchRef"]["name"] : nil,
            primary_language: primary_language
          }
          
          # Check if the repository has been updated since the given time
          if since_time.nil? || (repo["updatedAt"] && Time.parse(repo["updatedAt"]) >= Time.parse(since_iso8601))
            active_repos[repo_full_name] = repo_stats
          end
        end
      end
    
      @logger.info("Found #{active_repos.size} repositories (out of #{total_count} total) in #{org_name}")
      active_repos
    rescue => e
      @logger.error("Failed to fetch repository stats via GraphQL: #{e.message}")
      {}
    end
    
    # Fetch detailed user profile information for a list of usernames
    def fetch_user_profiles(usernames)
      @logger.info("Fetching user profiles for #{usernames.size} users via GraphQL")
      
      user_profiles = {}
      
      # Process in smaller batches to avoid hitting GraphQL complexity limits
      usernames.each_slice(10) do |batch|
        batch_response = fetch_user_profiles_batch(batch)
        user_profiles.merge!(batch_response) if batch_response
        sleep(0.5) # Small delay to avoid rate limits
      end
      
      @logger.info("Retrieved profile data for #{user_profiles.size} users")
      user_profiles
    end
    
    # Helper method to fetch user profiles in batches
    def fetch_user_profiles_batch(usernames)
      # Build dynamic query with user variables
      query_parts = []
      variables = {}
      
      usernames.each_with_index do |username, index|
        alias_name = "user#{index}"
        query_parts << "#{alias_name}: user(login: $#{alias_name}) { login name avatarUrl bio websiteUrl createdAt company location }"
        variables[alias_name.to_sym] = username
      end
      
      query_string = <<-GRAPHQL
        query(#{usernames.each_with_index.map { |_, i| "$user#{i}: String!" }.join(', ')}) {
          #{query_parts.join("\n")}
        }
      GRAPHQL
      
      response = execute_query(query_string, variables: variables)
      
      user_profiles = {}
      
      if response && response["data"]
        # Process each user in the response
        usernames.each_with_index do |_, index|
          alias_name = "user#{index}"
          user_data = response["data"][alias_name]
          
          if user_data
            user_profiles[user_data["login"]] = {
              login: user_data["login"],
              name: user_data["name"],
              avatar_url: user_data["avatarUrl"],
              bio: user_data["bio"],
              website: user_data["websiteUrl"],
              created_at: user_data["createdAt"],
              company: user_data["company"],
              location: user_data["location"]
            }
          end
        end
      end
      
      user_profiles
    end
    
    # Fetch trending repositories within the organization in a specific time period
    def fetch_trending_repositories(org_name, since_time)
      @logger.info("Fetching trending repositories for organization: #{org_name} since #{since_time} via GraphQL")
      
      since_time_formatted = Time.parse(since_time.to_s).iso8601
      since_time_parsed = Time.parse(since_time_formatted)
      
      query_string = <<-GRAPHQL
        query($org_name: String!, $since_date: GitTimestamp!) {
          organization(login: $org_name) {
            repositories(first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                name
                nameWithOwner
                updatedAt
                stargazerCount
                forkCount
                watchers { totalCount }
                defaultBranchRef {
                  target {
                    ... on Commit {
                      history(since: $since_date) {
                        totalCount
                      }
                    }
                  }
                }
                issues(states: OPEN) {
                  totalCount
                }
                pullRequests(states: OPEN) {
                  totalCount
                }
              }
            }
          }
        }
      GRAPHQL
      
      response = execute_query(query_string, variables: { 
        org_name: org_name,
        since_date: since_time_formatted
      })
      
      trending_repos = []
      
      if response && response["data"] && response["data"]["organization"] && response["data"]["organization"]["repositories"]
        repos = response["data"]["organization"]["repositories"]["nodes"]
        
        repos.each do |repo|
          next unless repo["defaultBranchRef"] && repo["defaultBranchRef"]["target"] && 
                    repo["defaultBranchRef"]["target"]["history"]
                    
          commit_count = repo["defaultBranchRef"]["target"]["history"]["totalCount"]
          issue_count = repo["issues"]["totalCount"]
          pr_count = repo["pullRequests"]["totalCount"]
          updated_at = Time.parse(repo["updatedAt"]) rescue nil
          
          # Skip repositories not updated since the provided time
          next unless updated_at && updated_at >= since_time_parsed
          
          # Score based on activity - higher score means more active
          activity_score = (commit_count * 3) + (pr_count * 5) + (issue_count * 2)
          
          if activity_score > 0
            trending_repos << {
              name: repo["name"],
              full_name: repo["nameWithOwner"],
              updated_at: repo["updatedAt"],
              commits: commit_count,
              issues: issue_count,
              pull_requests: pr_count,
              stars: repo["stargazerCount"],
              forks: repo["forkCount"],
              watchers: repo["watchers"]["totalCount"],
              activity_score: activity_score
            }
          end
        end
        
        # Sort by activity score (highest first)
        trending_repos.sort_by! { |repo| -repo[:activity_score] }
      end
      
      trending_repos
    end
    
    # Fetch code changes for a specific commit
    def fetch_commit_changes(repo_name, commit_oid)
      @logger.debug("Fetching code changes for commit: #{commit_oid} in repo: #{repo_name}")
      
      query_string = <<-GRAPHQL
        query($owner: String!, $repo: String!, $oid: GitObjectID!) {
          repository(owner: $owner, name: $repo) {
            object(oid: $oid) {
              ... on Commit {
                oid
                additions
                deletions
                changedFiles
                # Use commitResourcePath to get the URL that can be used for REST API fallback
                commitResourcePath
              }
            }
          }
        }
      GRAPHQL
      
      # Split the repo name into owner and repo parts
      owner, repo = repo_name.split('/')
      
      unless owner && repo
        @logger.error("Invalid repository name format: #{repo_name}. Expected format: 'owner/repo'")
        return {}
      end
      
      response = execute_query(query_string, variables: { 
        owner: owner,
        repo: repo,
        oid: commit_oid
      })
      
      if response && response["data"] && response["data"]["repository"] && 
         response["data"]["repository"]["object"]
        
        commit_object = response["data"]["repository"]["object"]
        
        # Since GraphQL doesn't provide files directly, try to fetch them via REST API
        files_data = fetch_commit_files_via_rest(owner, repo, commit_oid)
        
        return {
          oid: commit_object["oid"],
          additions: commit_object["additions"],
          deletions: commit_object["deletions"],
          changed_files: commit_object["changedFiles"],
          files: files_data
        }
      end
      
      # Return empty hash if we couldn't get the changes
      @logger.warn("Could not fetch changes for commit: #{commit_oid}")
      {}
    rescue => e
      @logger.error("Error fetching commit changes: #{e.message}")
      {}
    end
    
    # Fetch commit files using REST API as a fallback
    def fetch_commit_files_via_rest(owner, repo, commit_oid)
      @logger.debug("Fetching commit files via REST API for #{owner}/#{repo} commit: #{commit_oid}")
      
      begin
        # Create a new Net::HTTP client instance for REST API access
        uri = URI.parse("https://api.github.com/repos/#{owner}/#{repo}/commits/#{commit_oid}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        
        headers = {
          "Authorization" => "Bearer #{@token}",
          "User-Agent" => "GitHub-Daily-Digest",
          "Content-Type" => "application/json"
        }
        
        response = http.get(uri.path, headers)
        
        # Check if response is HTML instead of JSON (common error when rate limited or auth issues)
        if response.body.strip.start_with?('<!DOCTYPE', '<html')
          raise "Received HTML response instead of JSON. This usually indicates rate limiting or authentication issues. Status: #{response.code}"
        end
        
        # Check for non-200 status codes
        unless response.code.to_i == 200
          raise "GitHub API returned non-200 status code: #{response.code}, body: #{response.body[0..100]}"
        end
        
        # Parse the JSON response
        parsed_response = JSON.parse(response.body)
        
        # Extract file details
        if parsed_response && parsed_response["files"]
          @logger.debug("Successfully fetched #{parsed_response["files"].count} changed files via REST API")
          
          return parsed_response["files"].map do |file|
            {
              path: file["filename"],
              additions: file["additions"],
              deletions: file["deletions"],
              patch: file["patch"]
            }
          end
        end
      rescue => e
        @logger.error("Error fetching commit files via REST API: #{e.message}")
      end
      
      # Return empty array if REST fallback fails
      []
    end
    
    # Fetch changes for a batch of commits
    def fetch_commits_changes(commits, max_commits = 100)
      return [] if commits.nil? || commits.empty?
      
      @logger.info("Fetching code changes for #{[commits.size, max_commits].min} of #{commits.size} commits")
      
      # Debug logging to see commit structure
      if commits.first
        @logger.debug("Sample commit structure: #{commits.first.inspect}")
      end
      
      # Filter out any commits with invalid structure
      valid_commits = commits.select do |commit|
        commit && commit[:repo] && commit[:sha] 
      end
      
      if valid_commits.empty?
        @logger.warn("No valid commits found with required data (commit hash and repo)")
        return []
      end
      
      # Log the first valid commit structure
      if valid_commits.first
        @logger.debug("Valid commit sample: #{valid_commits.first.inspect}")
      end
      
      # Limit to the most recent commits to avoid overloading the API
      commits_to_process = valid_commits.sort_by do |c| 
        Time.parse(c[:date].to_s) rescue Time.now 
      end.reverse.first(max_commits)
      
      commits_with_changes = commits_to_process.map do |commit|
        begin
          # Fetch changes for this commit
          repo_name = commit[:repo]
          commit_oid = commit[:sha]
          
          # Format the repo name correctly for the GitHub API
          # Determine the correct organization for this repository
          if repo_name.include?('/')
            # If repo already has owner/name format, use it as is
            repo_full_name = repo_name
          else
            # If just repo name, add the current organization name
            org_name = @current_org_name || @config.github_org_name.to_s.split(',').first
            repo_full_name = "#{org_name}/#{repo_name}"
          end
          
          @logger.debug("Fetching changes for commit #{commit_oid} in repo #{repo_full_name}")
          
          changes = fetch_commit_changes(repo_full_name, commit_oid)
          
          # Add the changes to the commit data
          commit.merge(code_changes: changes)
        rescue => e
          @logger.error("Error processing commit changes: #{e.message}")
          # Return the original commit without changes in case of error
          commit.merge(code_changes: {})
        end
      end
      
      @logger.info("Successfully fetched changes for #{commits_with_changes.count} commits")
      commits_with_changes
    end
    
    # Verify GraphQL API authentication and check permissions
    def verify_authentication
      @logger.info("Verifying GitHub GraphQL authentication...")
      
      # Simple query to verify authentication - viewerHasScopes doesn't exist in GitHub's GraphQL API
      query = <<-GRAPHQL
        query {
          viewer {
            login
          }
        }
      GRAPHQL
      
      response = execute_query(query, variables: {})
      
      if response && response['data'] && response['data']['viewer']
        username = response['data']['viewer']['login']
        @logger.info("Authenticated to GitHub GraphQL API as user: #{username}")
        
        # We can't check scopes via GraphQL, so we'll use a separate method to check token scopes
        check_token_scopes
        
        return true
      else
        error_message = if response && response['errors']
                          response['errors'].map { |e| e['message'] }.join(', ')
                        else
                          "Unknown error"
                        end
        @logger.error("Failed to authenticate to GitHub GraphQL API: #{error_message}")
        raise "GraphQL authentication failed: #{error_message}"
      end
    end
    
    # Check token scopes using REST API since GraphQL doesn't provide this information
    def check_token_scopes
      begin
        uri = URI.parse("https://api.github.com/user")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Authorization"] = "Bearer #{@token}"
        request["User-Agent"] = "GitHub-Daily-Digest/1.0"
        
        response = http.request(request)
        
        if response.code == "200"
          scopes = response["X-OAuth-Scopes"]&.split(", ") || []
          @logger.info("Token scopes: #{scopes.join(', ')}")
          @logger.info("Token has repo scope: #{scopes.include?('repo')}")
          @logger.info("Token has org read scope: #{scopes.include?('read:org')}")
          
          return true
        else
          @logger.warn("Could not verify token scopes: HTTP #{response.code}")
          return false
        end
      rescue => e
        @logger.warn("Error checking token scopes: #{e.message}")
        return false
      end
    end
    
    def execute_query(query_string, variables: {})
      handle_api_errors do
        uri = URI.parse(GITHUB_API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        
        headers = {
          "Authorization" => "Bearer #{@token}",
          "User-Agent" => "GitHub-Daily-Digest",
          "Content-Type" => "application/json"
        }
        
        body = {
          query: query_string,
          variables: variables
        }.to_json
        
        response = http.post(uri.path, body, headers)
        
        # Check if response is HTML instead of JSON (common error when rate limited or auth issues)
        if response.body.strip.start_with?('<!DOCTYPE', '<html')
          raise "Received HTML response instead of JSON. This usually indicates rate limiting or authentication issues. Status: #{response.code}"
        end
        
        # Check for non-200 status codes
        unless response.code.to_i == 200
          raise "GitHub API returned non-200 status code: #{response.code}, body: #{response.body[0..100]}"
        end
        
        # Parse the JSON response
        parsed_response = JSON.parse(response.body)
        
        # Check for GraphQL errors
        if parsed_response['errors']
          error_messages = parsed_response['errors'].map { |e| e['message'] }.join(', ')
          raise "GraphQL errors: #{error_messages}"
        end
        
        parsed_response
      end
    end
    
    def handle_api_errors(retries = 3) # Default to 3 retries if not configured
      max_retries = @config&.max_api_retries || retries
      attempts = 0
      begin
        attempts += 1
        yield # Execute the GraphQL query block
      rescue => e
        # Check for various error types that might benefit from retrying
        should_retry = e.message.include?('rate limit') || 
                       e.message.include?('timeout') || 
                       e.message.include?('Received HTML response') ||
                       e.message.include?('500') ||
                       e.message.include?('503')
        
        if should_retry && attempts <= max_retries
          sleep_time = calculate_backoff(attempts)
          @logger.warn("GitHub GraphQL API error (Attempt #{attempts}/#{max_retries}): #{e.message}")
          @logger.warn("Retrying in #{sleep_time} seconds...")
          sleep sleep_time
          retry
        else
          @logger.error("GitHub GraphQL API error: #{e.message}")
          if attempts > max_retries
            @logger.error("Exceeded maximum retry attempts (#{max_retries})")
          end
          nil # Indicate failure
        end
      end
    end
    
    # Calculate exponential backoff with jitter for retries
    def calculate_backoff(attempt)
      base_delay = 2
      max_delay = 60
      # Exponential backoff: 2^attempt seconds with some randomness
      delay = [base_delay * (2 ** (attempt - 1)) * (0.5 + rand * 0.5), max_delay].min
      delay.round(1)
    end
    
    def format_commit(commit_data, repo_full_name)
      # Convert GraphQL commit data to format used by the rest of the app
      author_user = commit_data["author"]["user"] if commit_data["author"]
      
      {
        sha: commit_data["oid"],
        repo: repo_full_name,
        date: commit_data["committedDate"],
        message: commit_data["message"],
        author_login: author_user ? author_user["login"] : nil,
        author_name: commit_data["author"] ? commit_data["author"]["name"] : nil,
        author_email: commit_data["author"] ? commit_data["author"]["email"] : nil,
        stats: {
          additions: commit_data["additions"],
          deletions: commit_data["deletions"],
          total_changes: commit_data["additions"].to_i + commit_data["deletions"].to_i
        }
      }
    end
  end
end

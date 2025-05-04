module GithubDailyDigest
  class LanguageAnalyzer
    # Map of file extensions to languages
    EXTENSION_TO_LANGUAGE = {
      # Ruby
      '.rb' => 'Ruby',
      '.rake' => 'Ruby',
      '.gemspec' => 'Ruby',
      
      # JavaScript
      '.js' => 'JavaScript',
      '.jsx' => 'JavaScript',
      '.mjs' => 'JavaScript',
      '.cjs' => 'JavaScript',
      '.ts' => 'TypeScript',
      '.tsx' => 'TypeScript',
      
      # HTML/CSS
      '.html' => 'HTML',
      '.htm' => 'HTML',
      '.xhtml' => 'HTML',
      '.erb' => 'HTML/ERB',
      '.haml' => 'HTML/Haml',
      '.slim' => 'HTML/Slim',
      '.css' => 'CSS',
      '.scss' => 'CSS/SCSS',
      '.sass' => 'CSS/SASS',
      '.less' => 'CSS/LESS',
      
      # PHP
      '.php' => 'PHP',
      '.phtml' => 'PHP',
      
      # Python
      '.py' => 'Python',
      '.pyd' => 'Python',
      '.pyo' => 'Python',
      '.pyw' => 'Python',
      
      # Java
      '.java' => 'Java',
      '.class' => 'Java',
      '.jar' => 'Java',
      
      # C/C++
      '.c' => 'C',
      '.h' => 'C',
      '.cpp' => 'C++',
      '.cc' => 'C++',
      '.cxx' => 'C++',
      '.hpp' => 'C++',
      
      # C#
      '.cs' => 'C#',
      
      # Go
      '.go' => 'Go',
      
      # Swift
      '.swift' => 'Swift',
      
      # Kotlin
      '.kt' => 'Kotlin',
      '.kts' => 'Kotlin',
      
      # Rust
      '.rs' => 'Rust',
      
      # Shell
      '.sh' => 'Shell',
      '.bash' => 'Shell',
      '.zsh' => 'Shell',
      '.fish' => 'Shell',
      
      # Data
      '.json' => 'JSON',
      '.xml' => 'XML',
      '.yaml' => 'YAML',
      '.yml' => 'YAML',
      '.csv' => 'CSV',
      '.toml' => 'TOML',
      
      # Config
      '.ini' => 'Config',
      '.conf' => 'Config',
      '.cfg' => 'Config',
      
      # Markdown
      '.md' => 'Markdown',
      '.markdown' => 'Markdown',
      
      # SQL
      '.sql' => 'SQL',
      
      # Other
      '.txt' => 'Text',
      '.gitignore' => 'Git',
      '.dockerignore' => 'Docker',
      'Dockerfile' => 'Docker',
      '.env' => 'Config'
    }.freeze
    
    # Identify language from filename
    def self.identify_language(filepath)
      # Get the file extension
      ext = File.extname(filepath).downcase
      
      # For files without extensions, check the full filename
      basename = File.basename(filepath)
      
      # Try to match by extension first
      return EXTENSION_TO_LANGUAGE[ext] if EXTENSION_TO_LANGUAGE.key?(ext)
      
      # Try to match by filename for special cases
      return EXTENSION_TO_LANGUAGE[basename] if EXTENSION_TO_LANGUAGE.key?(basename)
      
      # Default for unknown types
      'Other'
    end
    
    # Calculate language distribution from a list of files
    # files should be an array of hashes with at least :path, :additions, :deletions
    def self.calculate_distribution(files)
      return {} if files.nil? || files.empty?
      
      # Initialize counters
      language_stats = Hash.new(0)
      total_changes = 0
      
      files.each do |file|
        # Skip files with no path
        next unless file[:path]
        
        # Calculate the total lines changed for this file
        lines_changed = (file[:additions] || 0) + (file[:deletions] || 0)
        
        # Identify the language
        language = identify_language(file[:path])
        
        # Add to the counters
        language_stats[language] += lines_changed
        total_changes += lines_changed
      end
      
      # Convert to percentages
      result = {}
      
      language_stats.each do |language, count|
        # Skip languages with 0 changes (shouldn't happen, but just in case)
        next if count == 0
        
        # Calculate percentage (rounded to 1 decimal place)
        percentage = total_changes > 0 ? (count.to_f / total_changes * 100).round(1) : 0
        
        # Only include if it's more than 0.1%
        result[language] = percentage if percentage > 0.1
      end
      
      # Sort by percentage (descending)
      result.sort_by { |_, percentage| -percentage }.to_h
    end
  end
end

# frozen_string_literal: true

require_relative "version"
require_relative "rubygems_integration"
require_relative "current_ruby"

autoload :Pathname, "pathname"

module Bundler
  autoload :WINDOWS, File.expand_path("constants", __dir__)
  autoload :FREEBSD, File.expand_path("constants", __dir__)
  autoload :NULL, File.expand_path("constants", __dir__)

  module SharedHelpers
    def root
      gemfile = find_gemfile
      raise GemfileNotFound, "Could not locate Gemfile" unless gemfile
      Pathname.new(gemfile).expand_path.parent
    end

    def default_gemfile
      gemfile = find_gemfile
      raise GemfileNotFound, "Could not locate Gemfile" unless gemfile
      Pathname.new(gemfile).expand_path
    end

    def default_lockfile
      gemfile = default_gemfile

      case gemfile.basename.to_s
      when "gems.rb" then Pathname.new(gemfile.sub(/.rb$/, ".locked"))
      else Pathname.new("#{gemfile}.lock")
      end
    end

    def default_bundle_dir
      bundle_dir = find_directory(".bundle")
      return nil unless bundle_dir

      bundle_dir = Pathname.new(bundle_dir)

      global_bundle_dir = Bundler.user_home.join(".bundle")
      return nil if bundle_dir == global_bundle_dir

      bundle_dir
    end

    def in_bundle?
      find_gemfile
    end

    def chdir(dir, &blk)
      Bundler.rubygems.ext_lock.synchronize do
        Dir.chdir dir, &blk
      end
    end

    def pwd
      Bundler.rubygems.ext_lock.synchronize do
        Pathname.pwd
      end
    end

    def with_clean_git_env(&block)
      keys    = %w[GIT_DIR GIT_WORK_TREE]
      old_env = keys.inject({}) do |h, k|
        h.update(k => ENV[k])
      end

      keys.each {|key| ENV.delete(key) }

      block.call
    ensure
      keys.each {|key| ENV[key] = old_env[key] }
    end

    def set_bundle_environment
      set_bundle_variables
      set_path
      set_rubyopt
      set_rubylib
    end

    # Rescues permissions errors raised by file system operations
    # (ie. Errno:EACCESS, Errno::EAGAIN) and raises more friendly errors instead.
    #
    # @param path [String] the path that the action will be attempted to
    # @param action [Symbol, #to_s] the type of operation that will be
    #   performed. For example: :write, :read, :exec
    #
    # @yield path
    #
    # @raise [Bundler::PermissionError] if Errno:EACCES is raised in the
    #   given block
    # @raise [Bundler::TemporaryResourceError] if Errno:EAGAIN is raised in the
    #   given block
    #
    # @example
    #   filesystem_access("vendor/cache", :create) do
    #     FileUtils.mkdir_p("vendor/cache")
    #   end
    #
    # @see {Bundler::PermissionError}
    def filesystem_access(path, action = :write, &block)
      yield(path.dup)
    rescue Errno::EACCES => e
      raise unless e.message.include?(path.to_s) || action == :create

      raise PermissionError.new(path, action)
    rescue Errno::EAGAIN
      raise TemporaryResourceError.new(path, action)
    rescue Errno::EPROTO
      raise VirtualProtocolError.new
    rescue Errno::ENOSPC
      raise NoSpaceOnDeviceError.new(path, action)
    rescue Errno::ENOTSUP
      raise OperationNotSupportedError.new(path, action)
    rescue Errno::EPERM
      raise OperationNotPermittedError.new(path, action)
    rescue Errno::EROFS
      raise ReadOnlyFileSystemError.new(path, action)
    rescue Errno::EEXIST, Errno::ENOENT
      raise
    rescue SystemCallError => e
      raise GenericSystemCallError.new(e, "There was an error #{[:create, :write].include?(action) ? "creating" : "accessing"} `#{path}`.")
    end

    def major_deprecation(major_version, message, removed_message: nil, print_caller_location: false)
      if print_caller_location
        caller_location = caller_locations(2, 2).first
        suffix = " (called at #{caller_location.path}:#{caller_location.lineno})"
        message += suffix
        removed_message += suffix if removed_message
      end

      require_relative "../bundler"

      feature_flag = Bundler.feature_flag

      if feature_flag.removed_major?(major_version)
        require_relative "errors"
        raise DeprecatedError, "[REMOVED] #{removed_message || message}"
      end

      return unless feature_flag.deprecated_major?(major_version) && prints_major_deprecations?
      Bundler.ui.warn("[DEPRECATED] #{message}")
    end

    def print_major_deprecations!
      multiple_gemfiles = search_up(".") do |dir|
        gemfiles = gemfile_names.select {|gf| File.file? File.expand_path(gf, dir) }
        next if gemfiles.empty?
        break gemfiles.size != 1
      end
      return unless multiple_gemfiles
      message = "Multiple gemfiles (gems.rb and Gemfile) detected. " \
                "Make sure you remove Gemfile and Gemfile.lock since bundler is ignoring them in favor of gems.rb and gems.locked."
      Bundler.ui.warn message
    end

    def ensure_same_dependencies(spec, old_deps, new_deps)
      new_deps = new_deps.reject {|d| d.type == :development }
      old_deps = old_deps.reject {|d| d.type == :development }

      without_type = proc {|d| Gem::Dependency.new(d.name, d.requirements_list.sort) }
      new_deps.map!(&without_type)
      old_deps.map!(&without_type)

      extra_deps = new_deps - old_deps
      return if extra_deps.empty?

      Bundler.ui.debug "#{spec.full_name} from #{spec.remote} has corrupted API dependencies" \
        " (was expecting #{old_deps.map(&:to_s)}, but the real spec has #{new_deps.map(&:to_s)})"
      raise APIResponseMismatchError,
        "Downloading #{spec.full_name} revealed dependencies not in the API (#{extra_deps.join(", ")})." \
        "\nRunning `bundle update #{spec.name}` should fix the problem."
    end

    def pretty_dependency(dep)
      msg = String.new(dep.name)
      msg << " (#{dep.requirement})" unless dep.requirement == Gem::Requirement.default

      if dep.is_a?(Bundler::Dependency)
        platform_string = dep.platforms.join(", ")
        msg << " " << platform_string if !platform_string.empty? && platform_string != Gem::Platform::RUBY
      end

      msg
    end

    def md5_available?
      return @md5_available if defined?(@md5_available)
      @md5_available = begin
        require "openssl"
        ::OpenSSL::Digest.digest("MD5", "")
        true
      rescue LoadError
        true
      rescue ::OpenSSL::Digest::DigestError
        false
      end
    end

    def digest(name)
      require "digest"
      Digest(name)
    end

    def checksum_for_file(path, digest)
      return unless path.file?
      # This must use File.read instead of Digest.file().hexdigest
      # because we need to preserve \n line endings on windows when calculating
      # the checksum
      SharedHelpers.filesystem_access(path, :read) do
        File.open(path, "rb") do |f|
          digest = SharedHelpers.digest(digest).new
          buf = String.new(capacity: 16_384, encoding: Encoding::BINARY)
          digest << buf while f.read(16_384, buf)
          digest.hexdigest
        end
      end
    end

    def write_to_gemfile(gemfile_path, contents)
      filesystem_access(gemfile_path) {|g| File.open(g, "w") {|file| file.puts contents } }
    end

    def relative_gemfile_path
      relative_path_to(Bundler.default_gemfile)
    end

    def relative_lockfile_path
      relative_path_to(Bundler.default_lockfile)
    end

    def relative_path_to(destination, from: pwd)
      Pathname.new(destination).relative_path_from(from).to_s
    rescue ArgumentError
      # on Windows, if source and destination are on different drivers, there's no relative path from one to the other
      destination
    end

    private

    def validate_bundle_path
      path_separator = Bundler.rubygems.path_separator
      return unless Bundler.bundle_path.to_s.split(path_separator).size > 1
      message = "Your bundle path contains text matching #{path_separator.inspect}, " \
                "which is the path separator for your system. Bundler cannot " \
                "function correctly when the Bundle path contains the " \
                "system's PATH separator. Please change your " \
                "bundle path to not match #{path_separator.inspect}." \
                "\nYour current bundle path is '#{Bundler.bundle_path}'."
      raise Bundler::PathError, message
    end

    def find_gemfile
      given = ENV["BUNDLE_GEMFILE"]
      return given if given && !given.empty?
      find_file(*gemfile_names)
    end

    def gemfile_names
      ["gems.rb", "Gemfile"]
    end

    def find_file(*names)
      search_up(*names) do |filename|
        return filename if File.file?(filename)
      end
    end

    def find_directory(*names)
      search_up(*names) do |dirname|
        return dirname if File.directory?(dirname)
      end
    end

    def search_up(*names)
      previous = nil
      current  = File.expand_path(SharedHelpers.pwd)

      until !File.directory?(current) || current == previous
        if ENV["BUNDLER_SPEC_RUN"]
          # avoid stepping above the tmp directory when testing
          return nil if File.directory?(File.join(current, "tmp"))
        end

        names.each do |name|
          filename = File.join(current, name)
          yield filename
        end
        previous = current
        current = File.expand_path("..", current)
      end
    end

    def set_env(key, value)
      raise ArgumentError, "new key #{key}" unless EnvironmentPreserver::BUNDLER_KEYS.include?(key)
      orig_key = "#{EnvironmentPreserver::BUNDLER_PREFIX}#{key}"
      orig = ENV[key]
      orig ||= EnvironmentPreserver::INTENTIONALLY_NIL
      ENV[orig_key] ||= orig

      ENV[key] = value
    end
    public :set_env

    def set_bundle_variables
      Bundler::SharedHelpers.set_env "BUNDLE_BIN_PATH", bundle_bin_path
      Bundler::SharedHelpers.set_env "BUNDLE_GEMFILE", find_gemfile.to_s
      Bundler::SharedHelpers.set_env "BUNDLER_VERSION", Bundler::VERSION
      Bundler::SharedHelpers.set_env "BUNDLER_SETUP", File.expand_path("setup", __dir__)
    end

    def bundle_bin_path
      # bundler exe & lib folders have same root folder, typical gem installation
      exe_file = File.join(source_root, "exe/bundle")

      # for Ruby core repository testing
      exe_file = File.join(source_root, "libexec/bundle") unless File.exist?(exe_file)

      # bundler is a default gem, exe path is separate
      exe_file = Gem.bin_path("bundler", "bundle", VERSION) unless File.exist?(exe_file)

      exe_file
    end
    public :bundle_bin_path

    def gemspec_path
      # inside a gem repository, typical gem installation
      gemspec_file = File.join(source_root, "../../specifications/bundler-#{VERSION}.gemspec")

      # for Ruby core repository testing
      gemspec_file = File.expand_path("bundler.gemspec", __dir__) unless File.exist?(gemspec_file)

      # bundler is a default gem
      gemspec_file = File.join(Gem.default_specifications_dir, "bundler-#{VERSION}.gemspec") unless File.exist?(gemspec_file)

      gemspec_file
    end
    public :gemspec_path

    def source_root
      File.expand_path("../..", __dir__)
    end

    def set_path
      validate_bundle_path
      paths = (ENV["PATH"] || "").split(File::PATH_SEPARATOR)
      paths.unshift "#{Bundler.bundle_path}/bin"
      Bundler::SharedHelpers.set_env "PATH", paths.uniq.join(File::PATH_SEPARATOR)
    end

    def set_rubyopt
      rubyopt = [ENV["RUBYOPT"]].compact
      setup_require = "-r#{File.expand_path("setup", __dir__)}"
      return if !rubyopt.empty? && rubyopt.first.include?(setup_require)
      rubyopt.unshift setup_require
      Bundler::SharedHelpers.set_env "RUBYOPT", rubyopt.join(" ")
    end

    def set_rubylib
      rubylib = (ENV["RUBYLIB"] || "").split(File::PATH_SEPARATOR)
      rubylib.unshift bundler_ruby_lib unless RbConfig::CONFIG["rubylibdir"] == bundler_ruby_lib
      Bundler::SharedHelpers.set_env "RUBYLIB", rubylib.uniq.join(File::PATH_SEPARATOR)
    end

    def bundler_ruby_lib
      File.expand_path("..", __dir__)
    end

    def clean_load_path
      loaded_gem_paths = Bundler.rubygems.loaded_gem_paths

      $LOAD_PATH.reject! do |p|
        resolved_path = resolve_path(p)
        next if $LOADED_FEATURES.any? {|lf| lf.start_with?(resolved_path) }
        loaded_gem_paths.delete(p)
      end
      $LOAD_PATH.uniq!
    end

    def resolve_path(path)
      expanded = File.expand_path(path)
      return expanded unless File.exist?(expanded)

      File.realpath(expanded)
    end

    def prints_major_deprecations?
      return false if Bundler.settings[:silence_deprecations]
      require_relative "deprecate"
      return false if Bundler::Deprecate.skip
      true
    end

    extend self
  end
end

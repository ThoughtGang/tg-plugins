#!/usr/bin/env ruby
# :title: TG::PluginManager
=begin rdoc
TG Plugin Manager

Copyright 2012 Thoughtgang <http://www.thoughtgang.org>
=end

require 'tg/plugin'
require 'tg/plugins/shared/specification'

module TG

# TODO : generalize application service hooks
#        ensure caller/child-provided plugin dirs

=begin rdoc
An application service for managing plugins. There are two main reponsibilities
of the service: finding and loading ('read') Ruby module files that contain
Plugin classes, and instantiating ('load') those classes. Additional features
include conveying notifications between the application and the plugins,
resolving Plugin dependencies, and listing or finding Plugins.

The PluginManager acts as a singleton; everything is handled through class
members and class methods. Many functions are delegates for Plugin class 
methods.

Example:

  require 'tg/application'

  class TheApplication
    include Application

    attr_reader :plugin_mgr

    def initialize(argv)
      # ... init code ...
      @plugin_mgr.add_base_dir( File.join('the_app', 'plugins') )
      Service.init_services
    end
  end

=end
  class PluginManager
    #extend Service

    CONF_NAME = 'plugins'

    # Location of shared modules under the plugin base directories. Any
    # directory with this name is not scanned for Plugin modules.
    SHARED_DIR='shared'

    NOTIFY_LOAD = :load
    NOTIFY_UNLOAD = :unload
    # Notifications sent by plugins or by the PluginManager
    NOTIFICATIONS = [NOTIFY_LOAD, NOTIFY_UNLOAD].freeze
    # TODO: Replace with a proper Notification object that includes Plugin obj

    # subscribers to plugin notifications
    @subscribers = {}

    # plugin registry
    @plugins = {}

    # list of plugin names (Plugin.canon_name) to prevent from loading.
    @blacklist = []

    # list of module names (full paths) to prevent from loading
    @blacklist_file = []

    # Names of directories containing plugins. Every entry in this list is
    # appended to each entry in the Ruby module load path when searching
    # for plugins.
    @base_dirs = [File.join('tg', 'plugins')]

=begin rdoc
Add a base directory to search for plugins. This is usually in the format
  File.join(app_name, 'plugins')
The base directory is appended to every element in the Ruby module path; if
the resulting path exists and is a directory, it is searched for plugins
during read_all.
=end
    def self.add_base_dir(path)
      @base_dirs.concat [path].flatten
    end

=begin rdoc
Blacklist a Plugin class by name.
Note: 'name' is expected to be obtained from Plugin.canon_name. The blacklist
checks for an exact match against this name when loading Plugin classes; this
allows specific versions of a Plugin to be blacklisted.
=end
    def self.blacklist(name)
      @blacklist.concat [name].flatten
    end

=begin rdoc
Blacklist a Plugin based on its module name.
This is used to prevent Plugin modules from being loaded, which can cause
problems if the Plugin includes class definitions that invoke extended or
inherited hooks in base classes, or if the module file itself has bugs (wrong
version of ruby, missing dependencies, syntax errors, etc).

Note: The argument is the path to the module as would be passed to
read_file(). This path is matched via String.end_with?, so be complete. This
facility is intended to be used by end users of the application with problem
plugins in their install dir. Applications can provide blacklist support to
users via config files.
=end
    def self.blacklist_file(path)
      @blacklist_file.concat [path].flatten
    end

      # ----------------------------------------------------------------------

=begin rdoc
Return a Hash [String -> Plugin] of all loaded plugins. String is the
canonical name (Plugin#canon_name) of the plugin.
=end
    def self.plugins
      @plugins.dup
    end

=begin rdoc
Return an Array of all available (i.e., successfully loaded via Kernel#load)
Plugin classes.
=end
    def self.plugin_modules
      TG::Plugin::available_plugins
    end

=begin rdoc
Return a Hash [Symbol -> Plugin::Specification] of all registered specs. Symbol
is the name of the Specification. A spec is registered by instantiating 
Plugin::Specification.
=end
    def self.specifications
      TG::Plugin::Specification.specs
    end

      # alias for specifications
    def self.specs
     specifications
    end

      # ----------------------------------------------------------------------

=begin rdoc
Ensure that dependencies for a Plugin are loaded. This will return true if
all dependencies are present and have successfully been loaded; false 
otherwise.
=end
    def self.check_plugin_dependencies(cls)
      deps = cls.check_dependencies
      if (! deps[:unmet].empty?)
        $stderr.puts "Cannot load plugin #{cls.canon_name}" 
        $stderr.puts "Unresolved dependencies:"
        deps[:unmet].each { |h| 
          $stderr.puts [h[:name], h[:op], h[:version]].join(' ')
        }
        return false
      end
        
      # Load all dependencies before loading class
      deps[:met].each do |dep_cls|
        dep_obj = load_plugin(dep_cls)
        if ! dep_obj
          $stderr.puts "Unable to load dependency: #{dep_cls.canon_name}"
          return false
        end
      end

      true
    end

=begin rdoc
Instantiate a Plugin. This checks if the Plugin was already loaded, if the
Plugin was blacklisted, and if the Plugin dependencies are all met.

If the plugin was successfully loaded, all subscribers will be notified.
=end
    def self.load_plugin(cls)
      return @plugins[cls.canon_name] if (@plugins.include? cls.canon_name)

      if @blacklist.include? cls.canon_name
        $stderr.puts "Attempt to load blacklisted plugin #{cls.canon_name}"
        return nil
      end

      return nil if ! check_plugin_dependencies(cls)

      # everything is in order; load plugin
      begin
        obj = cls.new
      rescue Exception => e
        $stderr.puts "Unable to load Plugin #{cls.canon_name}: #{e.message}"
        $stderr.puts e.backtrace.join("\n")
        return false
      end

      @plugins[cls.canon_name] = obj
      notify(NOTIFY_LOAD, obj)
      obj
    end

=begin rdoc
Unload a plugin. All subscribers are notified.
Note: This takes a Plugin object as its argument, not a Plugin class.
=end
    def self.unload(plugin)
      obj = @plugins.delete plugin.class.canon_name
      return if not obj
      notify(NOTIFY_UNLOAD, obj)
    end

=begin rdoc
Load all plugins that are registered in Plugin.available_plugins.
=end
    def self.load_all
      TG::Plugin.available_plugins.each { |cls| self.load_plugin(cls) }
    end

=begin rdoc
Read a Plugin Ruby module via Kernel#load. This checks if the module was
blacklisted via blacklist_file().
=end
    def self.read_file(path)
      return if (! @blacklist_file.select { |d| d.end_with? path }.empty? )
        
      begin
        load path
      rescue Exception => e
        $stderr.puts "Unable to load Plugin module #{path}: #{e.message}"
        # Suppress stacktrace if this is simply a missing dependency
        $stderr.puts e.backtrace.join("\n") if e.message !~ /^no such file/
      end
    end

=begin rdoc
Read all Plugin Ruby modules in the specified directory via read_file().
Directories are recursed.
Note: Hidden files/directories and directories named 'shared' are ignored. 
All files with a '.rb' extension are loaded via require.
=end
    def self.read_dir(path)
      return if (path.end_with? SHARED_DIR)

      Dir.foreach(path) do |entry|
        next if entry.start_with?('.')
        fname = File.join(path, entry)

        if File.directory?(fname)
          read_dir(fname)
        elsif (File.file? fname) && (entry.end_with? '.rb')
          read_file(fname)
        end
      end
    end

=begin rdoc
Read all Plugin Ruby Modules in all base directories. This appends each
entry in base_dirs in turn to all paths in the Ruby module path array ($:),
and invokes read_dir() on the resulting path.
=end
    def self.read_all
      # Read in all plugin directories in Ruby module path ($:)
      load_paths = $:.uniq.inject([]) do |arr, x|
        @base_dirs.each do |dir| 
          path = File.join(x, dir)
          next if (! File.exist? path) || (! File.directory? path)
          read_dir(path)
        end
      end
    end

      # ----------------------------------------------------------------------
=begin rdoc
Initialize the Plugin Manager.
This reads the ruby modules in all plugin directories, then loads all plugins 
that are not blacklisted.
=end
    def self.init
      clear
      read_config
      read_all
      load_all
    end

=begin rdoc
=end
    def self.read_config
      @config = Application.config.read_config(CONF_NAME)
      # TODO: read blacklist, plugin dirs, etc
    end

=begin rdoc
Invoke Plugin#application_startup(app) in every loaded plugin.

This should be invoked after an application has completed startup.
=end
    def self.startup(app)
      @plugins.values.each { |p| p.application_startup(app) }
    end

=begin rdoc
Invoke Plugin#application_object_load(app, obj) in every loaded plugin.

This is invoked by the application whenever a new document or project is
loaded. This gives plugins a chance to register themselves with new
document windows.
=end
    def self.object_loaded(app, obj)
      @plugins.values.each { |p| p.application_object_load(app, obj) }
    end

=begin rdoc
Invoke Plugin#application_shutdown(app) in every loaded plugin.

This should be invoked after an application is about to commence shutdown.
=end
    def self.shutdown(app)
      @plugins.values.each { |p| p.application_shutdown(app) }
    end

=begin rdoc
Unload all plugins. This leaves the configuration of the PluginManager
(blacklists, subscribers, base dirs, etc) intact.
=end
    def self.clear
      @plugins.clear
    end

=begin rdoc
Clear the PluginManager lists of base directories, blacklisted plugins,
blacklisted plugin modules, and subscribers.

Note: This clears the basedirs list completely -- even the builtin base_dir
will be removed.
=end
    def self.purge
      self.clear
      @blacklist.clear
      @blacklist_file.clear
      @basedirs.clear
      @subscribers.clear
    end

      # ----------------------------------------------------------------------
      
=begin rdoc
Subscribe to PluginManager notifications. The name is a String or Symbol used
to uniquely identify the subscriber (for unsubscribe purposes); the block is
invoked whenever a notification is sent. 

The block is invoked with the parameters |notification, plugin|, where
notification is a Symbl identifying the event type, and plugin is the Plugin
object to which the event applies.
=end
    def self.subscribe(name, &block)
      @subscribers[name] = block
    end

=begin rdoc
Remove 'name' from the list of notification subscribers.
=end
    def self.unsubscribe(name)
      @subscribers.delete(name)
    end

=begin rdoc
Notify all subscribers of a PluginManager event.
=end
    def self.notify(notification, plugin)
      @subscribers.values.each { |blk| blk.call(notification, plugin) }
    end

      # ----------------------------------------------------------------------
=begin rdoc
Return the first Plugin whose canon_name matches 'name'.
Note that name can be a String or a Regexp.
=end
    def self.find(name)
      matches = @plugins.keys.sort.select { |k| (name.kind_of? Regexp) ? 
                                        (k =~ name) : (k.starts_with? name) }
      (matches.empty?) ? nil : @plugins[matches.first]
    end

=begin rdoc
Return a list of all plugins providing an implementation of the named 
Specification. The plugins will be ordered by their default rating for this
spec. The return value for each Plugin is an Array [Plugin, Fixnum] containing
the Plugin object and the rating for this Specification.

Example:
  
  PluginManager.providing(:load_image_file).each do |plugin, rating|
    puts #{plugin.name} : #{rating}"
  end
=end
    def self.providing(spec_name, *args)
      sym = spec_name.to_sym
      @plugins.values.inject([]) { |a,p| 
                                   a << [p, ((args.empty?) ? 
                                         p.spec_supported?(sym) : 
                                         p.spec_rating(sym, *args)) ]; a 
                                 }.select { |p,r| r && r > 0 
                                 }.sort { |a,b| b[1] <=> a[1] }
    end

=begin rdoc
Return the Plugin object with the highest rating for this Specification given
the provided arguments.

Example:
  PluginManager.fittest_providing(:load_image_file, path) do |plugin|
    plugin.spec_invoke(:load_image_file, path)
  end
=end
    def self.fittest_providing(spec_name, *args, &block)
      sym = spec_name.to_sym
      p = @plugins.values.inject([]) { |a,p| 
                                       a << [p, p.spec_rating(sym, *args)]; a 
                                     }.sort { |a,b| 
                                       b[1] <=> a[1] 
                                     }.reject { |a| a[1] == 0 }.first
      p_obj = p ? p.first : nil
      yield p_obj if p_obj && block_given?
      p_obj
    end

  end

end

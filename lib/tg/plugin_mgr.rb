#!/usr/bin/env ruby
# :title: TG::PluginManager
=begin rdoc
TG Plugin Manager

Copyright 2013 Thoughtgang <http://www.thoughtgang.org>
=end

require 'tg/plugin'

=begin rdoc
Global debug flag. This can be set by an application in order to debug
problems with plugins.
=end
$TG_PLUGIN_DEBUG = false

=begin rdoc
Stream to which plugin debug messages are sent.
=end
$TG_PLUGIN_DEBUG_STREAM = $stderr

=begin rdoc
Raise an exception if Plugins return the incorrect type from a Specification.
=end
$TG_PLUGIN_FORCE_VALID_RETURN = false

module TG

=begin rdoc
A (singleton) object for managing plugins. The PluginManager has two main 
reponsibilities: finding and loading ('read') Ruby module files that contain
Plugin classes, and instantiating ('load') those classes. Additional features
include conveying notifications between the application and the plugins,
resolving Plugin dependencies, and listing or finding Plugins.

All PluginManager operations are handled through class members and class 
methods. Many functions are delegates for Plugin class methods.

Example:

  require 'tg/plugin_mgr'

  class TheApplication
    def initialize(argv)
      TG::PluginManager.add_base_dir( File.join('the_app', 'plugins') )
      TG::PluginManager.app_init(self)
      # ... other initialization code ...
      TG::PluginManager.app_startup(self)
    end

    def load_file(path)
      # ... create obj from path ...
      TG::PluginManager.app_object_loaded(obj, self)
    end

    def exit
      TG::PluginManager.app_shutdown(self)
    end
  end

In this example, app_init() and app_startup() are called at the start and end
of application initialization. The plugins are loaded in app_init(), giving
the application a chance to make use of the plugins before sending all plugins
the startup signal in app_startup(). An alternative would be to invoke
app_init_and_startup:

    def initialize(argv)
      TG::PluginManager.add_base_dir( File.join('the_app', 'plugins') )
      TG::PluginManager.app_init_and_startup(self)
    end

=end
  class PluginManager
    CONF_NAME = 'plugins'

    # Location of shared modules under the plugin base directories. Any
    # directory with this name is not scanned for Plugin modules.
    SHARED_DIR='shared'

    NOTIFY_LOAD = :load       # a plugin was loaded
    NOTIFY_UNLOAD = :unload   # a plugin was unloaded
    # Notifications sent by plugins or by the PluginManager
    NOTIFICATIONS = [NOTIFY_LOAD, NOTIFY_UNLOAD].freeze

    @@subscribers = {}         # subscribers to plugin notifications
    @@plugins = {}             # registry of plugin objects {String -> Plugin}

    # list of plugin names (Plugin.canon_name) to prevent from loading.
    @@blacklist = []

    # list of module names (full paths) to prevent from loading
    @@blacklist_file = []

    # Names of directories containing plugins. Every entry in this list is
    # appended to each entry in the Ruby module load path when searching
    # for plugins.
    @@base_dirs = []

    # Names of directories containing plugins. The entries in this list are
    # used directly and should contain absolute paths.
    @@absolute_dirs = []

    # ----------------------------------------------------------------------
    # Hooks

=begin rdoc
Initialize the Plugin Manager. The 'app' object can be used to obtain
configuration information (e.g. locations of plugins) by derived classes. This
default implementation ignores the 'app' argument.

This clears the list of loaded plugins. reads the ruby modules in all plugin 
directories, then loads all plugins that are not blacklisted.

This should be invoked when an application is being initialized.
=end
    def self.app_init(app=nil)
      clear
      read_all
      load_all
    end

=begin rdoc
Invoke Plugin#application_startup(app) in every loaded plugin. The 'app'
object can be used by the plugins to obtain configuration information. Note 
that the default implementation of Plugin#application_startup ignores the 
'app' argument.

This should be invoked after an application has completed startup.
=end
    def self.app_startup(app=nil)
      @@plugins.values.each { |p| p.application_startup(app) }
    end

=begin rdoc
A convenience function that invokes app_init() followed by app_startup().
=end
    def self.app_init_and_startup(app=nil)
      self.app_init app
      self.app_startup app
    end

=begin rdoc
Invoke Plugin#application_object_load(app, obj) in every loaded plugin. The
'obj' object is the object that has been loaded by the application. The 'app' 
object can be used by the plugins to obtain application state.  Note that the
default implementation of Plugin#application_object_load ignores the 'obj'
and the 'app' arguments.

This is invoked by the application whenever a new document or project is
loaded. This gives plugins a chance to register themselves with new
document windows.

See Plugin.startup.
=end
    def self.app_object_loaded(obj, app=nil)
      # NOTE: the order of app and obj are reversed to make app optional here
      @@plugins.values.each { |p| p.application_object_load(app, obj) }
    end

=begin rdoc
Invoke Plugin#application_shutdown(app) in every loaded plugin. The 'app'
object can be used to save configuration. Note that the default implementation
of Plugin#application_shutdown ignores the 'app' parameter.

This should be invoked after an application is about to commence shutdown.

See Plugin.startup.
=end
    def self.app_shutdown(app)
      @@plugins.values.each { |p| p.application_shutdown(app) }
    end

    # ----------------------------------------------------------------------
    # Subscribers
      
=begin rdoc
Subscribe to PluginManager notifications. The name is a String or Symbol used
to uniquely identify the subscriber (for unsubscribe purposes); the block is
invoked whenever a notification is sent. 

The block is invoked with the parameters |notification, plugin|, where
notification is a Symbol identifying the event type, and plugin is the Plugin
object to which the event applies.
=end
    def self.subscribe(name, &block)
      @@subscribers[name] = block
    end

=begin rdoc
Remove 'name' from the list of notification subscribers.
=end
    def self.unsubscribe(name)
      @@subscribers.delete(name)
    end

=begin rdoc
Notify all subscribers of a PluginManager event. This sends the specified
notification and the Plugin object to all subscribers.
=end
    def self.notify(notification, plugin)
      @@subscribers.values.each { |blk| blk.call(notification, plugin) }
    end

    # ----------------------------------------------------------------------
    # Adminstration

=begin rdoc
Unload all plugins. This leaves the configuration of the PluginManager
(blacklists, subscribers, base dirs, etc) intact.
=end
    def self.clear
      @@plugins.clear
    end

=begin rdoc
Clear the PluginManager lists of base directories, blacklisted plugins,
blacklisted plugin modules, and subscribers.
=end
    def self.purge
      self.clear
      @@blacklist.clear
      @@blacklist_file.clear
      @@basedirs.clear
      @@subscribers.clear
    end

=begin rdoc
Add a base directory to search for plugins. This is usually in the format
  File.join(app_name, 'plugins')
The base directory is appended to every element in the Ruby module path; if
the resulting path exists and is a directory, it is searched for plugins
during read_all.
=end
    def self.add_base_dir(path)
      @@base_dirs.concat [path].flatten
    end

=begin rdoc
Add a specific directory to search for plugins. This is an absolute path to a
directory containing a plugin tree.
=end
    def self.add_plugin_dir(path)
      @@absolute_dirs.concat [path].flatten
    end

=begin rdoc
Blacklist a Plugin class by name.
Note: 'name' is expected to be obtained from Plugin.canon_name. The blacklist
checks for an exact match against this name when loading Plugin classes; this
allows specific versions of a Plugin to be blacklisted. The String returned
by Plugin#canon_name is Plugin.name + '-' + Plugin.version.
=end
    def self.blacklist(name)
      @@blacklist.concat [name].flatten
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
      @@blacklist_file.concat [path].flatten
    end

    # ----------------------------------------------------------------------
    # Load/Unload Plugins

=begin rdoc
Ensure that dependencies for a Plugin are loaded. This will return true if
all dependencies are present and have successfully been loaded; false 
otherwise.
=end
    def self.check_plugin_dependencies(cls)
      deps = cls.check_dependencies
      if (! deps[:unmet].empty?)
        if $TG_PLUGIN_DEBUG
          $TG_PLUGIN_DEBUG_STREAM.puts "Cannot load plugin #{cls.canon_name}" 
          $TG_PLUGIN_DEBUG_STREAM.puts "Unresolved dependencies:"
          deps[:unmet].each { |h| 
            $TG_PLUGIN_DEBUG_STREAM.puts [h[:name],h[:op],h[:version]].join(' ')
          }
        end
        return false
      end
        
      # Load all dependencies before loading class
      deps[:met].each do |dep_cls|
        dep_obj = load_plugin(dep_cls)
        if ! dep_obj
          if $TG_PLUGIN_DEBUG
            $TG_PLUGIN_DEBUG_STREAM.puts "Unable to load dependency: " + \
                                         dep_cls.canon_name.inspect
          end
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
      return @@plugins[cls.canon_name] if (@@plugins.include? cls.canon_name)

      if @@blacklist.include? cls.canon_name
        if $TG_PLUGIN_DEBUG
          $TG_PLUGIN_DEBUG_STREAM.puts "Attempt to load blacklisted plugin " + \
                                       cls.canon_name.inspect
        end
        return nil
      end

      return nil if ! check_plugin_dependencies(cls)

      # everything is in order; load plugin
      begin
        obj = cls.new
      rescue Exception => e
        if $TG_PLUGIN_DEBUG
          $TG_PLUGIN_DEBUG_STREAM.puts "Unable to load Plugin %s: %s" % \
                                  [cls.canon_name.inspect, e.message.inspect]
          print_backtrace(e)
        end
        return false
      end

      @@plugins[cls.canon_name] = obj
      notify(NOTIFY_LOAD, obj)
      obj
    end

=begin rdoc
Unload a plugin. All subscribers are notified.
Note: This takes a Plugin object as its argument, not a Plugin class.
=end
    def self.unload(plugin)
      obj = @@plugins.delete plugin.class.canon_name
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
      return if (! @@blacklist_file.select { |d| path.end_with? d }.empty? )
        
      begin
        load path
      rescue Exception => e
        if $TG_PLUGIN_DEBUG
          $TG_PLUGIN_DEBUG_STREAM.puts "Unable to parse Plugin file %s: %s" % \
                                       [path.inspect, e.message.inspect]
          print_backtrace(e)
        end
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

    # Loading a dir of specifications is just like loading a dir of plugins
    def self.load_specification_dir(path)
      read_dir path
    end

=begin rdoc
Read all Plugin Ruby Modules in all base directories. This appends each
entry in base_dirs in turn to all paths in the Ruby module path array ($:),
and invokes read_dir() on the resulting path.
=end
    def self.read_all
      # Read in all plugin directories in Ruby module path ($:)
      $:.uniq.inject([]) do |arr, x|
        @@base_dirs.each do |dir| 
          path = File.join(x, dir)
          next if (! File.exist? path) || (! File.directory? path)
          read_dir(path)
        end
      end

      # Read in all plugin directories in absolute dirs
      @@absolute_dirs.each do |path| 
        next if (! File.exist? path) || (! File.directory? path)
        read_dir(path)
      end
    end

=begin rdoc
Retun an Array of all directories search for plugins. If include_missing
is true, the list will include all directories in the search path, whether
they exist or not. The default is to only include existing directories.
=end
    def self.plugin_dirs(include_missing=false)
      dirs = []
      $:.uniq.each { |d| @@base_dirs.map { |p| dirs << File.join(d, p) } }
      dirs += @@absolute_dirs
      include_missing ? dirs : dirs.select { |path| File.exist? path }
    end


    # ----------------------------------------------------------------------
    # List Plugins/Specs

=begin rdoc
Return a Hash [String -> Plugin] of all loaded plugins. String is the
canonical name (Plugin#canon_name) of the plugin.
=end
    def self.plugins
      @@plugins.dup
    end

=begin rdoc
Return an Array of all available (i.e., successfully loaded via Kernel#load)
Plugin classes.
=end
    def self.plugin_modules
      TG::Plugin::available_plugins
    end

=begin rdoc
Return Specification object for name.
=end
    def self.specification(name)
      TG::Plugin::Specification.spec(name)
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
    # Find/Match Plugins

=begin rdoc
Return the first Plugin whose canon_name matches 'name'. Note that 'name'
can be a String or a Regexp.
=end
    def self.find(name)
      matches = @@plugins.keys.sort.select { |k| (name.kind_of? Regexp) ? 
                                        (k =~ name) : (k.start_with? name) }
      (matches.empty?) ? nil : @@plugins[matches.first]
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
      @@plugins.values.inject([]) { |a,p| 
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
      arr = @@plugins.values.inject([]) { |a,p| 
                                       a << [p, p.spec_rating(sym, *args)]; a 
                                     }.sort { |a,b| 
                                       b[1] <=> a[1] 
                                     }.reject { |a| a[1] == 0 }.first
      p_obj = arr ? arr.first : nil
      yield p_obj if p_obj && block_given?
      p_obj
    end

    private

    def self.print_backtrace(e)
      # FIXME: This hard-codes filename! __FILE__ doesn't work
      $TG_PLUGIN_DEBUG_STREAM.puts e.backtrace.inject([]) { |a, x| 
          break a if (x.include? File.join('tg', 'plugin_mgr.rb')); a << x; a
        }.join("\n")
    end

  end

end

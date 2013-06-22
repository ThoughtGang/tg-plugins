#!/usr/bin/env ruby
# :title: TG::Plugin
=begin rdoc
Copyright 2013 Thoughtgang <http://www.thoughtgang.org>

==Specification

A Specification is defined by the application or framework, and represents a
unit of work which will be delegated to plugins. For example, an application
which uses plugins to load image files will have a Specification
:load_image_file that plugins then implement.

When the unit of work for a particular specification is to be performed, the
application or framework will generate a list of all plugins that support the
specification, then call PluginObject.spec_rating() for each plugin in the list;
the ratings returned by the plugins will then be used to determine the
suitability of each plugin to perform the unit of work on the input provided
to spec_rating(). The plugin with the highest rating will then be invoked to
perform the unit of work.

In the image loading example, the plugins JpegFormat and PngFormat will
implement the :load_image_file specification. When the spec_rating() method
for each of these plugins is invoked with a PNG file as an argument, JpegFormat
will return a rating of 0 and PngFormat will return a rating of 100. The
PngFormat plugin will then be called to load the PNG file.

Each Specification includes a list of valid types for input arguments and
return valued. These are checked when the Specification is invoked, resulting
in an Exception if the wrong types are used. Because of this, Specifications
can be considered lightweight contracts -- the plugin can be certain that
input arguments are of the required types, and the caller can be certain that
the plugin will return a specific type as output.

Note that Specifications are not merely type signatures. Two different 
specifications can have the same input and output types, yet represent
completely unrelated units of work. For example, the :load_image_file 
Specification and the :import_project Specification may both take a String
(path) or IO object as an argument, but a plugin that implements 
:load_image_file does not necessarily implement :import_project_specification --
even if the file format in :import_project_specification is the same as that
in :load_image_file.

Example:

  TG::Plugin::Specification.new( :load_image_file, 
                                    'Graphic load_image_file(String|IO)',
                                    [ [String, IO] ], Graphic )

  class PngFormat
    extend TG::Plugin
    name 'PNG Format'
    version '1.0.1'

    def load_file(file)
      obj = graphics_obj_from_file(file)
      return obj
    end
    spec :load_image_file, :load_file do |f|
      # ... code to evaluate to 100 if f is a PNG, 0 otherwise ...
    end

    private
    def graphics_obj_from_file(file)
      # ... code to create graphics object ...
    end
  end

==API Documentation

The ApiDoc class allows plugins to provide documentation for methods that
will be part of a published API.
=end

# TODO : Interface = collection of Specifications
# TODO: PluginDependency object
# TODO: store path to file that plugin was read from

module TG

# =============================================================================
=begin rdoc
Plugin instance methods.

These methods assume that the class has been extended from the Plugin module;
this module should not be included directly.
=end
  module PluginObject

=begin rdoc
Default constructor. This checks that required fields (name, version) are 
present.
=end
    def initialize
      raise 'Missing "name" in plugin class definition' if (! name)
      raise 'Missing "version" in plugin class definition' if (! version)
      @dependencies = []
    end

  # ----------------------------------------------------------------------
  # PLUGIN METADATA

=begin rdoc
Return plugin name property (String).
=end
    def name() self.class.name; end

=begin rdoc
Return plugin version property (String).
=end
    def version() self.class.version; end

=begin rdoc
Return the canonical name for the plugin. This is the name property and the
version property joined by a dash ('-').
=end
    def canon_name() self.class.canon_name; end

=begin rdoc
Return plugin author property (String).
=end
    def author() self.class.author; end

=begin rdoc
Return plugin license property (String).
=end
    def license() self.class.license; end

=begin rdoc
Return plugin description property (String).
=end
    def description() self.class.description; end
    alias :descr :description

=begin rdoc
Return plugin help property (String).
=end
    def help() self.class.help; end

  # ----------------------------------------------------------------------
  # PLUGIN NOTIFICATIONS

=begin rdoc
This method is invoked by the PluginManager when the application has completed
startup. Derived classes should override this method.
=end
    def application_startup(app)
    end

=begin rdoc
This method is invoked by the PluginManager when the Application loads an
object. This is generally used when an Application loads a new document or
project.
=end
    def application_object_load(app, obj)
    end

=begin rdoc
This method is invoked by the PluginManager when the application is about to
commence shutdown. Derived classes should override this method.
=end
    def application_shutdown(app)
    end

  # ----------------------------------------------------------------------
  # PLUGIN SPECIFICATION

=begin rdoc
Query a plugin to determine if it has an implementation for a spec.
'sym' is the Specification name.

This returns the default rating for the spec, if supported, or nil.
=end
    def spec_supported?(sym)
      (specs.include? sym) ? specs[sym].default_rating : nil
    end

=begin rdoc
Return the rating for a Specification implementation for the provided
arguments. This invokes the MethodSpecification rating_block on the arguments
to return a rating. If there is no rating_block for the MethodSpecification,
or no arguments are provided, the default rating is returned.

Note that all exceptions raised by the specification are caught and written
to TG_PLUGIN_DEBUG_STREAM if TG_PLUGIN_DEBUG is set. The only exceptions
raised by this method will be InvalidSpecificationError and
ArgumentTypeError.
=end
    def spec_rating(sym, *args)
      spec = Plugin::Specification.specs[sym]
      raise Plugin::InvalidSpecificationError.new(sym.to_s) if not spec

      # check that plugin provides spec
      impl = specs[sym]
      return 0 if ! impl

      # check that args are valid for spec
      return 0 if ! spec.validate_input(*args)

      # return rating based on args (via block), or the default rating
      rating = impl.default_rating
      begin
        block = impl.rating_block
        rating = self.instance_exec(*args, &block) if (block && ! args.empty?)
      rescue Exception => e
        if $TG_PLUGIN_DEBUG
          $TG_PLUGIN_DEBUG_STREAM.puts "Error rating %s for %s : %s" % \
                                       [sym.to_s, self.canon_name, e.message]
          $TG_PLUGIN_DEBUG_STREAM.puts e.backtrace.join("\n")
        end
        rating = 0  # No point using plugins that failed the rating call!
      end
      rating
    end

=begin rdoc
Invoke an specification implementation in the plugin. 
'sym' is the Specification name.

Note that all exceptions raised by the specification are caught and written
to TG_PLUGIN_DEBUG_STREAM if TG_PLUGIN_DEBUG is set. The only exceptions
raised by this method will be InvalidSpecificationError and
ArgumentTypeError.
=end
    def spec_invoke(sym, *args)
      spec = Plugin::Specification.specs[sym]
      raise Plugin::InvalidSpecificationError.new(sym.to_s) if not spec

      # ensure args to method are valid according to spec
      spec.validate_input!(*args)

      # objtain spec implementation
      impl = specs[sym]
      raise Plugin::InvalidSpecificationError.new(sym.to_s) if not impl

      # invoke method for spec. note: this captures all exceptions.
      rv = nil
      begin
        rv = self.send(impl.symbol, *args)
      rescue Exception => e
        if $TG_PLUGIN_DEBUG
          $TG_PLUGIN_DEBUG_STREAM.puts "Error invoking %s for %s : %s" % \
                                       [sym.to_s, self.canon_name, e.message]
          $TG_PLUGIN_DEBUG_STREAM.puts e.backtrace.join("\n")
        end
      end

      # ensure return value from method is valid according to spec
      if $TG_PLUGIN_FORCE_VALID_RETURN
        spec.validate_output!(rv)
      elsif $TG_PLUGIN_DEBUG && (!spec.validate_output(rv))
        $TG_PLUGIN_DEBUG_STREAM.puts "Warning: %s %s Expected: %s Got: %s" % \
                                     [self.canon_name, sym.to_s, 
                                      spec.output.class, rv.class]
      end

      rv
    end

=begin rdoc
Return a Hash [name -> MethodSpecification] of specs supported by this plugin.
This is just a wrapper for Plugin.specs().
=end
    def specs
      self.class.specs
    end

    alias :specifications :specs

  # ----------------------------------------------------------------------
  # PLUGIN API

=begin rdoc
Return a Hash [name -> ApiDoc] for all public methods in the plugin. For 
methods which have no ApiDoc object, API_UNDOCUMENTED is returned unless
strip_undocumented is true (in which case the methods will not appear in
the Hash).
=end
    def api(strip_undocumented=false)
      api_doc = self.class.api
      public_methods.inject({}) do |h, meth_name|
        sym = meth_name.to_sym
        doc = api_doc[sym]
        if doc
          h[sym] = doc
        elsif ! strip_undocumented
          h[sym] = Plugin::API_UNDOCUMENTED
        end
        h
      end
    end

  end

# =============================================================================
=begin rdoc

Note that name and version are required.

Example:
  class MyPlugin
    extend TG::Plugin
    name 'Test'
    version '1.0.1-beta'
    author 'An Author <author@example.com>'
    license 'BSD'
    description 'A simple test plugin'
    help "
      Some help text, e.g. a manpage.
    "

    def initialize
      super
      # plugin-specific initialization here
    end
=end
  module Plugin

    @plugin_classes = []        # List of classes extended with this module

=begin rdoc
Plugin class initialization.

This records the class in an Array of plugin classes, then includes the
PluginObject module in the class.

Usage:
  class MyPlugin
    extend TG::Plugin
    # ... rest of MyPlugin class definition here ...
  end
=end
    def self.extended(cls)
      if ! (@plugin_classes.include? cls)
        @plugin_classes << cls
        cls.class_eval do
          include PluginObject
        end
      end
    end

=begin rdoc
Return a list of all available plugins. This is just a list of all classes that
have extended (mixed-in) the Plugin module.
=end
    def self.available_plugins
      @plugin_classes.dup
    end

  # ----------------------------------------------------------------------
  # PLUGIN METADATA

=begin rdoc
Accessor for plugin name property.
=end
    def name(str=nil) (str ? (@name = str) : @name); end

=begin rdoc
Accessor for plugin version property.
=end
    def version(str=nil) (str ? (@version = str) : @version); end

=begin rdoc
Canonical name for the plugin. This is the name and the version strings
joined by a dash ('-') character. 

The canonical name is used when the application or framework must support
more than one version of a plugin.
=end
    def canon_name() name + '-' + version; end

=begin rdoc
Accessor for plugin author property.
=end
    def author(str=nil) (str ? (@author = str) : @author); end

=begin rdoc
Accessor for plugin license property.
=end
    def license(str=nil) (str ? (@license = str) : @license); end

=begin rdoc
Accessor for plugin description property.
=end
    def description(str=nil) (str ? (@description = str) : @description); end
    alias :descr :description

=begin rdoc
Accessor for plugin help property.
=end
    def help(str=nil) (str ? (@help = str) : @help); end

    VALID_DEP_OPS = [ '<', '<=', '=', '>=', '>' ].freeze
=begin rdoc
Declare a plugin dependency.
Usage:
    dependency 'PluginA', '=', '1.0'
    dependency 'PluginB', '>=', '1.0'
    dependency 'PluginC', 1.0
    dependency 'PluginD'
Valid values for op:
  < <= == >= >
=end
    def dependency(dep_name, op=nil, dep_version=nil)
      if dep_version
        op ||= '>='
      else
        dep_version = op
        op = nil
      end

      raise InvalidDependencyOpError.new(op.inspect) if op && \
            ! (VALID_DEP_OPS.include? op)

      @dependencies << { :name => dep_name, :op => op, :version => dep_version }
    end

=begin rdoc
Return list of plugin dependencies.
Each dependency is a Hash with the keys :name, :op, and :version
=end
    def dependencies
      @dependencies
    end

=begin rdoc
Returns -1, 0, 1 if existing_version is <, =, > required_version.
=end
    def version_cmp(existing_version, required_version)
      a = version_tokens(existing_version)
      b = version_tokens(required_version)
      diff = 0

      # process each element in existing_version until < required_version
      a.each_with_index do |i, idx|
        if idx >= b.length
          diff = 1
          break
        end

        x = b[idx]
        if (x.to_i.to_s != x)
          if (i.to_i.to_s != i)     # both strings
            diff = (i == x) ? 0 : -1
          else                      # a is string, b is number
            diff = -1
          end
        elsif (i.to_i.to_s != i)    # a is number, b is string
          diff = 1
        else                        # both numbers
          diff = i.to_i <=> x.to_i
        end

        break if diff != 0
      end

      diff
    end

=begin rdoc
Generate version string tokens by splitting string on '.', then splitting last 
element on '-'.
=end
    def version_tokens(str)
      toks = str.split('.')
      last = toks.pop
      toks.concat(last.split('-'))
    end

=begin rdoc
Return true if plugin meets dependency, false otherwise.
Note that this checks the three elements of a dependency declaration:
name, relation (<, <=, =, >=, >) and version.

Plugins which will can fill dependencies for other plugins (e.g. a replacement
for an obsolete plugin) can override this method to account for that.
=end
    def meets_dependency?(dep_name, op, required_version)
      return false if name != dep_name

      diff = version_cmp(version, required_version)
      rv = false
      case diff
        when -1
          rv = ([ '<', '<=' ].include? op)
        when 0
          rv = ([ '<=', '=', '>=' ].include? op)
        when 1
          rv = ([ '>', '>=' ].include? op)
      end
      rv
    end

=begin
Check the dependencies for a Plugin object. This is generally called before
instantiating the Plugin.

This returns a Hash [ :met -> Array(Plugin), :unmet -> Array(Hash) ] which
contains a list of Plugin classes that meet dependencies, and a list of
dependency descriptors (Hash [ :name, :op, :version -> String ] for
unmet dependencies.
=end
    def check_dependencies
      h = { :met => [], :unmet => [] }
      dependencies.each do |dep|

        arr = Plugin.available_plugins.select { |cls|
          cls.meets_dependency?(dep[:name], dep[:op], dep[:version])
        }

        (arr.empty?) ? h[:unmet] << dep : h[:met] << arr.last
      end
      h
    end


  # ----------------------------------------------------------------------
  # PLUGIN SPECIFICATION

=begin rdoc
Argument type does not match Specification.
=end
    class ArgumentTypeError < RuntimeError
    end

=begin rdoc
Specification does not exist.
=end
    class InvalidSpecificationError < RuntimeError
    end

=begin rdoc
Dependency operation is not one of [<, <=, =, >=, >].
=end
    class InvalidDependencyOpError < RuntimeError
    end

=begin rdoc
A plugin method specification. This associates a name (Symbol) with a list of
input argument types and a return type.

Example:

  Specification.new( :find, 'matches find(needle, haystack), 
                     [ [String, Fixnum], Array ], Array )
=end
    class Specification

=begin rdoc
Name (Symbol) of the specification.
=end
      attr_reader :name

=begin rdoc
Prototype for the specification.  This is a string with the following format:

  return-var name( arg1, arg2 )

The prototype serves as documentation for the spec by listing variable names
for the input arguments and the output.

Examples:

  proto 'product mul( number_a, number_b )'
  proto 'quotient div( numerator, demoninator )'
  proto 'success copy( dest, src )'
  proto 'matches find( needle, haystack )'
=end
      attr_reader :prototype

=begin rdoc
An Array of argument types. Each element in the array corresponds to an
argument to the specification method; note that arguments are positional,
not named.

Each argument is represented in the Array by a Class object. If an argument 
can be of different types (e.g. IO or String), it is represented by an Array
of Class objects. If an argument can be of *any* type, the class Object is
used.

The input property is used to verify (using Object#kind_of?) that arguments 
being passed to the specification method are of the appropriate type. 
Attempts to invoke an argument specification method with inappropriate 
arguments will result in an exception.

Examples:
  
  input [ Fixnum ]                        # takes one Fixnum argument
  input [ Fixnum, Fixnum ]                # takes two Fixnum arguments
  input [ Array ]                         # takes one Array argument
  input [ Fixnum, [String, IO]]           # takes one Fixnum, one IO or String
  input [ Object, Object ]                # takes two objects of any type
  input [ Fixnum, [String, NilClass] ]    # takes one Fixnum, optional String

=end

      attr_reader :input
=begin rdoc
The return type of the specification method. This is declared in the same
manner as input arguments, and is used to verify (using Object#kind_of?) the
return value of the specification method.

Examples:

  output NilClass                     # method has no output
  output Fixnum                       # method returns a Fixnum
  output Array                        # method returns an Array
  output [NilClass, String]           # method returns a String or nil
  output [TrueClass, FalseClass]      # method returns true or false
=end
      attr_reader :output

=begin rdoc
=end
      def initialize(name, proto, input, output=NilClass)
        @name = name.to_sym
        @prototype = proto.to_s

        force_class_objects(input)
        @input = input

        force_class_objects([output])
        @output = output

        self.class.add_spec(self) 
      end

      alias :proto :prototype

=begin rdoc
Verify that all arguments are present, and are of the required types.
=end
      def validate_input(*args)
        return false if args.count < input.count

        valid = true
        args.each_with_index do |arg, idx|
          valid &= validate_type( input[idx], arg )
        end

        valid
      end

=begin rdoc
Raise an exception if arguments are invalid
=end
      def validate_input!(*args)
        raise ArgumentTypeError.new(args.inspect) if ! validate_input(*args)
        true
      end

=begin rdoc
Validate that an object is of a specified type. Type is either a Class object,
or an Array of Class objects. If type is an Array, then the object can be 
any of the Class objects in the Array.
=end
      def validate_type(type, obj)
        types = (type.kind_of? Array) ? type : [type]
        types.each { |t| return true if (obj.kind_of? t) }
        false
      end

=begin rdoc
Validate that obj is of the correct type for the output of this specification.
=end
      def validate_output(obj)
        validate_type(output, obj)
      end

=begin rdoc
Raise an exception if output is invalid
=end
      def validate_output!(obj)
        raise ArgumentTypeError.new(obj.inspect) if ! validate_output(obj)
        true
      end

=begin rdoc
Add a Specification instance to the Hash of all Specifications.
=end
      def self.add_spec(obj)
        @@specs ||= {}
        @@specs[obj.name] = obj
      end

=begin rdoc
Return a Hash [name -> Specification] of all Specification objects.
=end
      def self.specs
        @@specs ? @@specs.dup : {}
      end

=begin rdoc
Return Specification object for symbol.
=end
      def self.spec(sym)
        (@@specs || {})[sym.to_sym]
      end

      private

      def force_class_objects( arr )
        arr.flatten.each do |c| 
          raise ArgumentTypeError.new(c.class.name) if c.class != Class &&
                                                       c.class != Module
        end
      end
    end

=begin rdoc
A Specification implementation.
This maps a method name (Symbol) to a Specification name (symbol) along
with a default rating and a rating_block.
=end
    class MethodSpecification
      attr_reader :symbol, :default_rating, :rating_block

      def initialize(sym, rating, block)
        @symbol = sym
        @default_rating = rating
        @rating_block = block
      end
    end

=begin rdoc
Declare an instance method of the plugin to be an implementation of a
Specification.

An implementation of a specification should provide three things:
  * a method implementing that specification
  * a default rating or confidence level for this implementation (optional)
  * a block which returns a rating or confidence level for the
    implementation based on input data (optional)

The suitability of a plugin for a specific task (i.e., applying a specification 
to specific input data) is determined by a rating or confidence level. This
rating is in the range 0-100, and is based on two values:
  1. A number returned by the 'query block' in the specification implementation
     declaration. The block is evaluated with the prospective specification
     arguments passed in as block values; the number returned is the
     confidence that the plugin has that it can handle this specific data 
     in its implementation.
  2. A default number specified in the specification declaration. This number
     is used if there is no input data to send to the query block (e.g.
     when prompting the user to choose a plugin from a list sorted by
     confidence level), or when there is no query block in the specification
     implementation declaration. Note that if no default rating has been
     supplied in the declaration, a default rating of 50 is assumed.

A MethodSpecification object is created for the declaration.
     
Examples
  
  class ThePlugin
    extend Plugin
    def sum(a, b) a + b; end
    # declare sum() to be an implementation of :binary_operation spec
    spec :binary_operation, :sum

    # as above, but with a default rating of 75 
    spec :binary_operation, :sum, 75

    # as above, but with a rating of 100 if arguments are Fixnum (25 otherwise)
    spec :binary_operation, :sum, 75 do |a, b|
      (a.kind_of? Fixnum) && (b.kind_of? Fixnum) ? 100 : 25
    end

    # as above, but with no default rating (falling through to 50)
    spec :binary_operation, :sum do |a, b|
      (a.kind_of? Fixnum) && (b.kind_of? Fixnum) ? 100 : 25
    end
  end

Note that each plugin can only have a single implementation of a particular
Specification.
=end
    def spec(iface_sym, fn_sym, rating=50, &block)
      @specs ||= {}
      blk = (block_given?) ? Proc.new(&block) : nil
      @specs[iface_sym] = MethodSpecification.new(fn_sym, rating, blk)
    end

    alias :specification :spec

=begin rdoc
Return a Hash [spec_name -> MethodSpecification] for this plugin.
=end
    def specs
      @specs ? @specs.dup : {}
    end

    alias :specifications :specs

  # ----------------------------------------------------------------------
  # PLUGIN API

=begin rdoc
An API method documentation declaration.
This specifies the documentation strings for the method arguments, return 
value, and description (advisory only) of an API method.
=end
    class ApiDoc
      attr_reader :arguments, :return_value, :description

      def initialize(args, ret, descr)
        @arguments = args.dup
        @return_value = ret
        @description = descr
      end

      alias :args :arguments
      alias :ret :return_value
      alias :descr :description

      def to_s
        "(#{arguments.join(',')}) -> #{return_value} '#{descr}'}"
      end
    end

    API_UNDOCUMENTED = ApiDoc.new([], '', 'Not documented').freeze

=begin rdoc
Define a documentation string for an instance method of the plugin.

Example:

  class ThePlugin
    extend Plugin
    def sum(a, b) a + b; end

    api_doc :sum, ['Fixnum a', 'Fixnum b'], 'Fixnum sum', 'Sum two numbers.'
  end

Note that the contents of args and ret are used only for documentation 
purposes; there is no input validation performed by them.

TODO: replace with proper introspection?
=end
    def api_doc(fn_sym, args, ret, descr )
      @@api ||= {}
      @@api[fn_sym] = ApiDoc.new(args, ret, descr )
    end

=begin rdoc
Return a Hash [name -> ApiMethod] of API methods for this plugin.
=end
    def api
      @@api ||= {}
      @@api ? @@api.dup : {}
    end
  end

end

# TG-Plugins
Plugin system for Ruby projects.

This consists of a Plugin module, which can be extended in any Ruby class that
is to be used as a plugin, and a PluginManager class, which can be used to
manage (find, load, unload, list, execute) plugins.


The Plugin module uses ad-hoc decorators (actually class methods, once mixed in)
to define metadata describing the plugin:

  * name
  * version
  * canon_name - the name and version number of the plugin
  * author
  * license
  * description - human-readable description of the plugin
  * help - a help page or manual for the plugin


An application defines "specifications" for operations that can be performed
by multiple plugins. A specification includes a unique name (Symbol), a
human-readable prototype string, an Array of arguments classes, and an
output class. A plugin can map one of its methods to a specification,
supplying a confidence rating that reflects its ability to implement that 
specification. The confidence rating can be unconditional, or can be determined
based on specific input.


For example:

```ruby
  class ImageXformApplication
    def initialize(args)
      TG::Plugin::Specification.new( :load_image_file, 
                                     'Graphic load_image_file(String|IO)',
                                     [ [String, IO] ], Graphic )
    end
  end

  class PngImage
    extend TG::Plugin
    name 'PNG Image Support'
    version '1.0.1'

    def load_file(file)
      obj = graphics_obj_from_file(file)
      return obj
    end
    spec :load_image_file, :load_file do |f|
      # ... code to evaluate to 100 if f is a PNG, 0 otherwise ...
    end
  end    

  class NullImage
    extend TG::Plugin
    name 'NULL Image Handler'
    version '0.9'

    def load_file(file)
      $stderr.puts "Unrecognized Image: #{file.inspect}" if $debug 
      return Graphic.null_image()
    end
    # unconditionally return a rating of 10
    spec :load_image_file, :load_file, 10
  end    
```
Note that Arrays in a Specification argument list are used to implement OR:
the element "[String, Array]" in the arguments array means that the argument
in that position can be either a String or Array. This can also be used in 
the return-type, so that a plugin can be declared to return 
"[TrueClass, FalseClass]" (true or false), "[String, NilClass]" (string or nil),
etc. To specify "any class", use Object as the argument/return-value class.


The PluginManager will find the fittest Plugin to handle a given input:
```ruby
  PluginManager.fittest_providing(:load_image_file, path) do |plugin|           
    plugin.spec_invoke(:load_image_file, path)
  end
```
This will query all plugins that provide a method implementing the 
load_image_file specification, calling the confidence-rating block (the
block argument to the spec() call) of each. The plugin which returns the
highest confidence rating (generally in the range 0-100, though this is not
enforced and can be application-specific) is then returned or passed to
a block (if provided).


The PluginManager also defines the fittest_invoke() method, which calls
fittest_providing() to get the plugin, then invokes the plugin method
implementing the specification on the input.


More detail is provided in the rdoc strings.

# License
https://github.com/mkfs/pogo-license
This is the standard BSD 3-clause license with a 4th clause added to prohibit 
non-collaborative communication with project developers.

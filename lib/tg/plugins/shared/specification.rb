#!/usr/bin/env ruby
# :title: TG::Plugin::Specification
=begin rdoc
Standard Plugin Specifications

Copyright 2012 Thoughtgang <http://www.thoughtgang.org>

This directory contains Specification definitions used by standard TG plugins.

Each Specification definition is an instance of the Specification class.

Example:

TG::Plugin::Specification.new( :unary_operation, 'fn(x)', [[Fixnum,String]], [Fixnum,String] )

The list of all Specification definitions can be obtained via
TG::Plugin::Specification.specs().
=end

module TG
  module Plugin

=begin rdoc
Namespace for defining Specification objects.
Just in case.
=end
    module Spec
    end

  end
end

Dir.foreach(File.join(File.dirname(__FILE__), 'specification')) do |f|
    require File.join('tg', 'plugins', 'shared', 'specification',
                      File.basename(f, '.rb')) if (f.end_with? '.rb')
end

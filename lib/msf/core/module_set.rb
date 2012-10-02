# -*- coding: binary -*-
require 'msf/core'
require 'fastlib'
require 'pathname'

module Msf

  #
  # Define used for a place-holder module that is used to indicate that the
  # module has not yet been demand-loaded. Soon to go away.
  #
  SymbolicModule = "__SYMBOLIC__"

  ###
  #
  # A module set contains zero or more named module classes of an arbitrary
  # type.
  #
  ###
  class ModuleSet < Hash
    include Framework::Offspring

    # Wrapper that detects if a symbolic module is in use.  If it is, it creates an instance to demand load the module
    # and then returns the now-loaded class afterwords.
    #
    # @param [String] name the module reference name
    # @return [Msf::Module] instance of the of the Msf::Module subclass with the given reference name
    def [](name)
      if (super == SymbolicModule)
        create(name)
      end

      super
    end

    # Create an instance of the supplied module by its name
    #
    # @param [String] name the module reference name.
    # @return [Msf::Module] instance of the named module.
    def create(name)
      klass = fetch(name, nil)
      instance = nil

      # If there is no module associated with this class, then try to demand
      # load it.
      if klass.nil? or klass == SymbolicModule
        # If we are the root module set, then we need to try each module
        # type's demand loading until we find one that works for us.
        if module_type.nil?
          MODULE_TYPES.each { |type|
            framework.modules.demand_load_module(type, name)
          }
        else
          framework.modules.demand_load_module(module_type, name)
        end

        recalculate

        klass = fetch(name)
      end

      # If the klass is valid for this name, try to create it
      if klass and klass != SymbolicModule
        instance = klass.new
      end

      # Notify any general subscribers of the creation event
      if instance
        self.framework.events.on_module_created(instance)
      end

      return instance
    end

    # Overrides the builtin 'each' operator to avoid the following exception on Ruby 1.9.2+
    # "can't add a new key into hash during iteration"
    #
    # @yield [module_reference_name, module]
    # @yieldparam [String] module_reference_name the name of the module.
    # @yieldparam [Class] module The module class: a subclass of Msf::Module.
    # @return [void]
    def each(&block)
      list = []
      self.keys.sort.each do |sidx|
        list << [sidx, self[sidx]]
      end
      list.each(&block)
    end

    # Enumerates each module class in the set.
    #
    # @param opts (see #each_module_list)
    # @yield (see #each_module_list)
    # @yieldparam (see #each_module_list)
    # @return (see #each_module_list)
    def each_module(opts = {}, &block)
      demand_load_modules

      self.mod_sorted = self.sort

      each_module_list(mod_sorted, opts, &block)
    end

    # Custom each_module filtering if an advanced set supports doing extended filtering.
    #
    # @param opts (see #each_module_list)
    # @param [String] name the module reference name
    # @param [Array<String, Class>] entry pair of the module reference name and the module class.
    # @return [false] if the module should not be filtered; it should be yielded by {#each_module_list}.
    # @return [true] if the module should be filtered; it should not be yielded by {#each_module_list}.
    def each_module_filter(opts, name, entry)
      return false
    end

    # Enumerates each module class in the set based on their relative ranking to one another.  Modules that are ranked
    # higher are shown first.
    #
    # @param opts (see #each_module_list)
    # @yield (see #each_module_list)
    # @yieldparam (see #each_module_list)
    # @return (see #each_module_list)
    def each_module_ranked(opts = {}, &block)
      demand_load_modules

      self.mod_ranked = rank_modules

      each_module_list(mod_ranked, opts, &block)
    end

    # Forces all modules in this set to be loaded.
    #
    # @return [void]
    def force_load_set
      each_module { |name, mod| }
    end

    # Initializes a module set that will contain modules of a specific type and expose the mechanism necessary to create
    # instances of them.
    #
    # @param [String] type The type of modules cached by this {Msf::ModuleSet}.
    def initialize(type = nil)
      #
      # Defaults
      #
      self.ambiguous_module_reference_name_set = Set.new
      # Hashes that convey the supported architectures and platforms for a
      # given module
      self.architectures_by_module     = {}
      self.platforms_by_module = {}
      self.mod_sorted        = nil
      self.mod_ranked        = nil
      self.mod_extensions    = []

      #
      # Arguments
      #
      self.module_type = type
    end

    # @!attribute [r] module_type
    #   The type of modules stored by this {Msf::ModuleSet}.
    #
    #   @return [String] type of modules
    attr_reader   :module_type

    # Gives the module set an opportunity to handle a module reload event
    #
    # @param [Class] mod the module class: a subclass of Msf::Module
    # @return [void]
    def on_module_reload(mod)
    end

    # @!attribute [rw] postpone_recalc
    #   Whether or not recalculations should be postponed.  This is used from the context of the each_module_list
    #   handler in order to prevent the demand # loader from calling recalc for each module if it's possible that more
    #   than one module may be loaded.  This field is not initialized until used.
    #
    #   @return [true] if recalculate should not be called immediately
    #   @return [false] if recalculate should be called immediately
    attr_accessor :postpone_recalculate

    # Dummy placeholder to recalculate aliases and other fun things.
    #
    # @return [void]
    def recalculate
    end

    # Checks to see if the supplied module name is valid.
    #
    # @return [true] if the module can be {#create created} and cached.
    # @return [false] otherwise
    def valid?(name)
      create(name)
      (self[name]) ? true : false
    end

    protected

    # Adds a module with a the supplied name.
    #
    # @param [Class] mod The module class: a subclass of Msf::Module.
    # @param [String] name The module reference name
    # @param [Hash{String => Object}] modinfo optional module information
    # @return [Class] The mod parameter modified to have {Msf::Module#framework}, {Msf::Module#refname},
    #   {Msf::Module#file_path}, and {Msf::Module#orig_cls} set.
    def add_module(mod, name, modinfo = nil)
      # Set the module's name so that it can be referenced when
      # instances are created.
      mod.framework = framework
      mod.refname   = name
      mod.file_path = ((modinfo and modinfo['files']) ? modinfo['files'][0] : nil)
      mod.orig_cls  = mod

      cached_module = self[name]

      if (cached_module and cached_module != SymbolicModule)
        ambiguous_module_reference_name_set.add(name)

        # TODO this isn't terribly helpful since the refnames will always match, that's why they are ambiguous.
        wlog("The module #{mod.refname} is ambiguous with #{self[name].refname}.")
      else
        self[name] = mod
      end

      mod
    end

    # Load all modules that are marked as being symbolic.
    #
    # @return [void]
    def demand_load_modules
      # Pre-scan the module list for any symbolic modules
      self.each_pair { |name, mod|
        if (mod == SymbolicModule)
          self.postpone_recalculate = true

          mod = create(name)

          next if (mod.nil?)
        end
      }

      # If we found any symbolic modules, then recalculate.
      if (self.postpone_recalculate)
        self.postpone_recalculate = false

        recalculate
      end
    end

    # Enumerates the modules in the supplied array with possible limiting factors.
    #
    # @param [Array<Array<String, Class>>] ary Array of module reference name and module class pairs
    # @param [Hash{String => Object}] opts
    # @option opts [Array<String>] 'Arch' List of 1 or more architectures that the module must support.  The module need
    #   only support one of the architectures in the array to be included, not all architectures.
    # @option opts [Array<String>] 'Platform' List of 1 or more platforms that the module must support.  The module need
    #   only support one of the platforms in the array to be include, not all platforms.
    # @yield [module_reference_name, module]
    # @yieldparam [String] module_reference_name the name of module
    # @yieldparam [Class] module The module class: a subclass of {Msf::Module}.
    # @return [void]
    def each_module_list(ary, opts, &block)
      ary.each { |entry|
        name, mod = entry

        # Skip any lingering symbolic modules.
        next if (mod == SymbolicModule)

        # Filter out incompatible architectures
        if (opts['Arch'])
          if (!architectures_by_module[mod])
            architectures_by_module[mod] = mod.new.arch
          end

          next if ((architectures_by_module[mod] & opts['Arch']).empty? == true)
        end

        # Filter out incompatible platforms
        if (opts['Platform'])
          if (!platforms_by_module[mod])
            platforms_by_module[mod] = mod.new.platform
          end

          next if ((platforms_by_module[mod] & opts['Platform']).empty? == true)
        end

        # Custom filtering
        next if (each_module_filter(opts, name, entry) == true)

        block.call(name, mod)
      }
    end

    # @!attribute [rw] ambiguous_module_reference_name_set
    #   Set of module reference names that are ambiguous because two or more paths have modules with the same reference
    #   name
    #
    #   @return [Set<String>] set of module reference names loaded from multiple paths.
    attr_accessor :ambiguous_module_reference_name_set
    # @!attribute [rw] architectures_by_module
    #   Maps a module to the list of architectures it supports.
    #
    #   @return [Hash{Class => Array<String>}] Maps module class to Array of architecture Strings.
    attr_accessor :architectures_by_module
    attr_accessor :mod_extensions
    # @!attribute [rw] platforms_by_module
    #   Maps a module to the list of platforms it supports.
    #
    #   @return [Hash{Class => Array<String>}] Maps module class to Array of platform Strings.
    attr_accessor :platforms_by_module
    # @!attribute [rw] mod_ranked
    #   Array of module names and module classes ordered by their Rank with the higher Ranks first.
    #
    #   @return (see #rank_modules)
    attr_accessor :mod_ranked
    # @!attribute [rw] mod_sorted
    #   Array of module names and module classes ordered by their names.
    #
    #   @return [Array<Array<String, Class>>] Array of arrays where the inner array is a pair of the module reference
    #     name and the module class.
    attr_accessor :mod_sorted
    # @!attribute [w] module_type
    #   The type of modules stored by this {Msf::ModuleSet}.
    #
    #   @return [String] type of modules
    attr_writer   :module_type
    attr_accessor :module_history

    # Ranks modules based on their constant rank value, if they have one.  Modules without a Rank are treated as if they
    # had {Msf::NormalRanking} for Rank.
    #
    # @return [Array<Array<String, Class>>] Array of arrays where the inner array is a pair of the module reference name
    #   and the module class.
    def rank_modules
      self.mod_ranked = self.sort { |a, b|
        a_name, a_mod = a
        b_name, b_mod = b

        # Dynamically loads the module if needed
        a_mod = create(a_name) if a_mod == SymbolicModule
        b_mod = create(b_name) if b_mod == SymbolicModule

        # Extract the ranking between the two modules
        a_rank = a_mod.const_defined?('Rank') ? a_mod.const_get('Rank') : NormalRanking
        b_rank = b_mod.const_defined?('Rank') ? b_mod.const_get('Rank') : NormalRanking

        # Compare their relevant rankings.  Since we want highest to lowest,
        # we compare b_rank to a_rank in terms of higher/lower precedence
        b_rank <=> a_rank
      }
    end
  end
end
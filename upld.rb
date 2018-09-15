require "securerandom"
require "fileutils"
require "tempfile"
require "find"

class Upld
  VERSION = "0.0.1"
end

class Upld
  module Storage
    class FileSystem
      attr_reader :directory

      def initialize(directory)
        @directory = directory
        FileUtils.mkdir_p(directory)
      end

      def upload(io, id)
        IO.copy_stream(io, path(id))
        url(id)
      end

      def download(id)
        tempfile = Tempfile.new(id, binmode: true)
        IO.copy_stream(open(id), tempfile)
        tempfile.rewind
        tempfile.fsync
        tempfile
      end

      def open(id)
        ::File.open(path(id), "rb")
      end

      def read(id)
        ::File.read(path(id))
      end

      def size(id)
        ::File.size(path(id))
      end

      def exists?(id)
        ::File.exist?(path(id))
      end

      def delete(id)
        FileUtils.rm(path(id))
      end

      def url(id)
        path(id)
      end

      def path(id)
        ::File.join(directory, id)
      end

      def clear!(confirm = nil, &block)
        if block_given?
          Find.find(directory) do |path|
            if block.call(path)
              FileUtils.rm(path)
            else
              Find.prune
            end
          end
        else
          raise Upld::Confirm unless confirm == :confirm
          FileUtils.rm_rf(directory)
          FileUtils.mkdir_p(directory)
        end
      end
    end
  end
end

class Upld
  class UploadedFile
    @upld_class = ::Upld
  end

  @opts = {}
  @storages = {}

  module Plugins
    @plugins = {}

    def self.load_plugin(name)
      unless plugin = @plugins[name]
        require "Upld/plugins/#{name}"
        raise Error, "Plugin #{name} did not register itself correctly in Upld::Plugins" unless plugin = @plugins[name]
      end
      plugin
    end

    def self.register_plugin(name, mod)
      @plugins[name] = mod
    end

    module Base
      module ClassMethods
        attr_reader :opts

        def inherited(subclass)
          puts "# ========================================================================="
          subclass.instance_variable_set(:@opts, opts.dup)
          subclass.opts.each do |key, value|
            if value.is_a?(Enumerable) && !value.frozen?
              subclass.opts[key] = value.dup
            end
          end
          subclass.instance_variable_set(:@storages, storages.dup)

          file_class = Class.new(self::UploadedFile)
          file_class.upld_class = subclass
          subclass.const_set(:UploadedFile, file_class)
        end

        def plugin(plugin, *args, &block)
          plugin = Plugins.load_plugin(plugin) if plugin.is_a?(Symbol)
          plugin.load_dependencies(self, *args, &block) if plugin.respond_to?(:load_dependencies)
          include(plugin::InstanceMethods) if defined?(plugin::InstanceMethods)
          extend(plugin::ClassMethods) if defined?(plugin::ClassMethods)
          self::UploadedFile.include(plugin::FileMethods) if defined?(plugin::FileMethods)
          self::UploadedFile.extend(plugin::FileClassMethods) if defined?(plugin::FileClassMethods)
          plugin.configure(self, *args, &block) if plugin.respond_to?(:configure)
          nil
        end

        attr_accessor :storages

        def cache=(storage)
          storages[:cache] = storage
        end

        def cache
          storages[:cache]
        end

        def store=(storage)
          storages[:store] = storage
        end

        def store
          storages[:store]
        end
      end

      module InstanceMethods
        IO_METHODS = [:read, :eof?, :rewind, :size, :close].freeze

        def initialize(storage_key)
          @storage_key = storage_key
        end

        attr_reader :storage_key

        def storage
          @storage ||= self.class.storages.fetch(storage_key)
        end

        def opts
          self.class.opts
        end

        def upload(io, location = generate_location(io))
          validate(io)
          storage.upload(io, location)

          uploaded_file(
            "id"       => location,
            "storage"  => storage_key.to_s,
            "metadata" => {},
          )
        end

        def validate(io)
          IO_METHODS.each do |m|
            if not io.respond_to?(m)
              raise Error, "#{io.inspect} does not respond to `#{m}`"
            end
          end
        end

        def generate_location(io)
          filename = extract_filename(io)
          ext = (filename ? File.extname(filename) : "")
          generate_uid(io) + ext
        end

        def uploaded_file(data)
          self.class::UploadedFile.new(data)
        end

        private

        def extract_filename(io)
          if io.respond_to?(:original_filename)
            io.original_filename
          elsif io.respond_to?(:path)
            File.basename(io.path)
          elsif io.is_a?(Upld::UploadedFile)
            File.basename(io.id)
          end
        end

        def generate_uid(io)
          SecureRandom.uuid
        end
      end

      module FileClassMethods
        attr_accessor :upld_class

        def inspect
          "#{upld_class.inspect}::UploadedFile"
        end
      end

      module FileMethods
        attr_reader :data, :id, :storage, :metadata

        def initialize(data)
          @data     = data
          @id       = data.fetch("id")
          @storage  = upld_class.storages.fetch(data.fetch("storage").to_sym)
          @metadata = data.fetch("metadata")
        end

        def read(*args)
          io.read(*args)
        end

        def eof?
          io.eof?
        end

        def close
          io.close
        end

        def rewind
          @io = nil
        end

        def url
          storage.url(id)
        end

        def size
          storage.size(id)
        end

        def exists?
          storage.exists?(id)
        end

        def download
          storage.download(id)
        end

        def delete
          storage.delete(id)
        end

        def upld_class
          self.class.upld_class
        end

        private

        def io
          @io ||= storage.open(id)
        end
      end
    end
  end

  extend Plugins::Base::ClassMethods
  plugin Plugins::Base
end

puts "# ========================================================================="
puts Upld::VERSION
Upld.storages = {
  temporary: Upld::Storage::FileSystem.new(Dir.tmpdir),
  permanent: Upld::Storage::FileSystem.new("uploads"),
}
cache = Upld.new(:temporary)
store = Upld.new(:permanent)
cached_file = cache.upload(File.open("284km.jpg"))
cached_file #=> #<Upld::UploadedFile:0x00007f933102ccd8>
cached_file.data #=> {"id"=>"cfcb9837-4a56-4134-9609-85249f5ea691.jpg", "storage"=>"temporary", "metadata"=>{}}
cached_file.url #=> /var/folders/31/1h2dr3r94mj0mnmww0qmrlg00000gp/T/cfcb9837-4a56-4134-9609-85249f5ea691.jpg
stored_file = store.upload(cached_file)
stored_file #=> #<Upld::UploadedFile:0x00007f9331025eb0>
stored_file.data #=> {"id"=>"0aba43a1-11ea-4182-9f1f-c991a6938e5e.jpg", "storage"=>"permanent", "metadata"=>{}}
stored_file.url #=> uploads/0aba43a1-11ea-4182-9f1f-c991a6938e5e.jpg



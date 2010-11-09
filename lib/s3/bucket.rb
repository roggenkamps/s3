module S3
  class Bucket
    include Parser
    include Proxies
    extend Forwardable

    attr_reader :name, :service

    def_instance_delegators :service, :service_request
    private_class_method :new

    # Retrieves the bucket information from the server. Raises an
    # S3::Error exception if the bucket doesn't exist or you don't
    # have access to it, etc.
    def retrieve
      bucket_headers
      self
    end

    # Returns location of the bucket, e.g. "EU"
    def location(reload = false)
      if reload or @location.nil?
        @location = location_constraint
      else
        @location
      end
    end

    # Compares the bucket with other bucket. Returns true if the names
    # of the buckets are the same, and both have the same services
    # (see Service equality)
    def ==(other)
      self.name == other.name and self.service == other.service
    end

    # Similar to retrieve, but catches S3::Error::NoSuchBucket
    # exceptions and returns false instead.
    def exists?
      retrieve
      true
    rescue Error::NoSuchBucket
      false
    end

    # Destroys given bucket. Raises an S3::Error::BucketNotEmpty
    # exception if the bucket is not empty. You can destroy non-empty
    # bucket passing true (to force destroy)
    def destroy(force = false)
      delete_bucket
      true
    rescue Error::BucketNotEmpty
      if force
        objects.destroy_all
        retry
      else
        raise
      end
    end

    # Saves the newly built bucket.
    #
    # ==== Options
    # * <tt>:location</tt> - location of the bucket
    #   (<tt>:eu</tt> or <tt>us</tt>)
    # * Any other options are passed through to
    #   Connection#request
    def save(options = {})
      options = {:location => options} unless options.is_a?(Hash)
      create_bucket_configuration(options)
      true
    end

    # Returns true if the name of the bucket can be used like +VHOST+
    # name. If the bucket contains characters like underscore it can't
    # be used as +VHOST+ (e.g. <tt>bucket_name.s3.amazonaws.com</tt>)
    def vhost?
      "#@name.#{HOST}" =~ /\A#{URI::REGEXP::PATTERN::HOSTNAME}\Z/
    end

    # Returns host name of the bucket according (see #vhost? method)
    def host
      vhost? ? "#@name.#{HOST}" : "#{HOST}"
    end

    # Returns path prefix for non +VHOST+ bucket. Path prefix is used
    # instead of +VHOST+ name, e.g. "bucket_name/"
    def path_prefix
      vhost? ? "" : "#@name/"
    end

    # Returns the objects in the bucket and caches the result (see
    # #reload method).
    def objects
      Proxy.new(lambda { list_bucket }, :owner => self, :extend => ObjectsExtension)
    end

    # Returns the object with the given key. Does not check whether the
    # object exists. But also does not issue any HTTP requests, so it's
    # much faster than objects.find
    def object(key)
      Object.send(:new, self, :key => key)
    end

    def inspect #:nodoc:
      "#<#{self.class}:#{name}>"
    end

    private

    attr_writer :service

    def location_constraint
      response = bucket_request(:get, :params => {:location => nil})
      parse_location_constraint(response.body)
    end

    def list_bucket(options = {})
      response = bucket_request(:get, :params => options)
      objects_attributes = parse_list_bucket_result(response.body)

      # If there are more than 1000 objects S3 truncates listing
      # and we need to request another listing for the remaining objects.
      while parse_is_truncated(response.body)
        marker = objects_attributes.last[:key]
        response = bucket_request(:get, :params => options.merge(:marker => marker))
        objects_attributes += parse_list_bucket_result(response.body)
      end

      objects_attributes.map { |object_attributes| Object.send(:new, self, object_attributes) }
    end

    def bucket_headers(options = {})
      response = bucket_request(:head, :params => options)
    rescue Error::ResponseError => e
      if e.response.code.to_i == 404
        raise Error::ResponseError.exception("NoSuchBucket").new("The specified bucket does not exist.", nil)
      else
        raise e
      end
    end

    def create_bucket_configuration(options = {})
      location = options[:location].to_s.upcase if options[:location]
      options[:headers] ||= {}
      if location and location != "US"
        options[:body] = "<CreateBucketConfiguration><LocationConstraint>#{location}</LocationConstraint></CreateBucketConfiguration>"
        options[:headers][:content_type] = "application/xml"
      end
      bucket_request(:put, options)
    end

    def delete_bucket
      bucket_request(:delete)
    end

    def initialize(service, name) #:nodoc:
      self.service = service
      self.name = name
    end

    def name=(name)
      raise ArgumentError.new("Invalid bucket name: #{name}") unless name_valid?(name)
      @name = name
    end

    def bucket_request(method, options = {})
      path = "#{path_prefix}#{options[:path]}"
      service_request(method, options.merge(:host => host, :path => path))
    end

    def name_valid?(name)
      name =~ /\A[a-z0-9][a-z0-9\._-]{2,254}\Z/i and name !~ /\A#{URI::REGEXP::PATTERN::IPV4ADDR}\Z/
    end
  end
end

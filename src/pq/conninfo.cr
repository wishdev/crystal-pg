require "uri"
require "http"
require "system/user"

module PQ
  struct ConnInfo
    SOCKET_SEARCH = %w(/run/postgresql/.s.PGSQL.5432 /tmp/.s.PGSQL.5432 /var/run/postgresql/.s.PGSQL.5432)

    SUPPORTED_AUTH_METHODS = %w[cleartext md5 scram-sha-256 scram-sha-256-plus]

    # The host. If starts with a / it is assumed to be a local Unix socket.
    getter host : String

    # The port, defaults to 5432. It is ignored for local Unix sockets.
    getter port : Int32

    # The database name.
    getter database : String

    # The user.
    getter user : String

    # The password. Optional.
    getter password : String?

    # The sslmode. Optional (:prefer is default).
    getter sslmode : Symbol

    # The sslcert. Optional.
    getter sslcert : String?

    # The sslkey. Optional.
    getter sslkey : String?

    # The sslrootcert. Optional.
    getter sslrootcert : String?

    getter auth_methods : Array(String) = %w[scram-sha-256-plus scram-sha-256 md5]

    # Create a new ConnInfo from all parts
    def initialize(host : String? = nil, database : String? = nil, user : String? = nil, password : String? = nil, port : Int | String? = nil, sslmode : String | Symbol? = nil)
      @host = default_host host
      db = default_database database
      @database = db.lchop('/')
      @user = default_user user
      @port = (port || ENV.fetch("PGPORT", "5432")).to_i
      @sslmode = default_sslmode sslmode
      @password = password || ENV.fetch("PGPASSWORD", PgPass.locate(@host, @port, @database, @user))
    end

    # Initialize with either "postgres://" urls or postgres "key=value" pairs
    def self.from_conninfo_string(conninfo : String)
      if conninfo.starts_with?("postgres://") || conninfo.starts_with?("postgresql://")
        new(URI.parse(conninfo))
      else
        return new if conninfo == ""

        args = Hash(String, String).new
        conninfo.split ' ' do |pair|
          begin
            k, eq, v = pair.partition('=')
            if eq.empty?
              raise ArgumentError.new("invalid paramater: #{pair}")
            end
            args[k] = v
          end
        end
        new(args)
      end
    end

    # Initializes with a `URI`
    def initialize(uri : URI)
      hostname = uri.hostname.presence || URI::Params.parse(uri.query.to_s).fetch("host", "")
      initialize(hostname, uri.path, uri.user, uri.password, uri.port, :prefer)
      if q = uri.query
        HTTP::Params.parse(q) do |key, value|
          handle_sslparam(key, value)
        end
      end
    end

    # Initialize with a `Hash`
    #
    # Valid keys match Postgres "conninfo" keys and are `"host"`, `"dbname"`,
    # `"user"`, `"password"`, `"port"`, `"sslmode"`, `"sslcert"`, `"sslkey"` and `"sslrootcert"`
    def initialize(params : Hash)
      initialize(params["host"]?, params["dbname"]?, params["user"]?,
        params["password"]?, params["port"]?, params["sslmode"]?)
      params.each do |key, value|
        handle_sslparam(key, value)
      end
    end

    private def handle_sslparam(key : String, value : String)
      case key
      when "sslmode"
        @sslmode = default_sslmode value
      when "sslcert"
        @sslcert = value
      when "sslkey"
        @sslkey = value
      when "sslrootcert"
        @sslrootcert = value
      when "auth_methods"
        methods = value.split(",").compact_map(&.underscore.presence).uniq
        methods.each do |method|
          unless method.in?(SUPPORTED_AUTH_METHODS)
            raise "invalid auth_method #{method}"
          end
        end
        @auth_methods = methods
      else
        # ignore
      end
    end

    private def default_host(h)
      return h if h && !h.blank?

      return ENV["PGHOST"] if ENV.has_key?("PGHOST")

      SOCKET_SEARCH.each do |s|
        return s if File.exists?(s)
      end

      "localhost"
    end

    private def default_database(db)
      if db && db != "/" && !db.empty?
        db
      else
        ENV.fetch("PGDATABASE", current_user_name)
      end
    end

    private def default_user(u)
      u || ENV.fetch("PGUSER", current_user_name)
    end

    private def default_sslmode(mode)
      case mode
      when nil, :prefer, "prefer"
        :prefer
      when :disable, "disable"
        :disable
      when :allow, "allow"
        :allow
      when :require, "require"
        :require
      when :"verify-ca", "verify-ca"
        :"verify-ca"
      when :"verify-full", "verify-full"
        :"verify-full"
      else
        raise ArgumentError.new("sslmode #{mode} not supported")
      end
    end

    private def current_user_name
      System::User.find_by(id: LibC.getuid.to_s).username
    end
  end
end

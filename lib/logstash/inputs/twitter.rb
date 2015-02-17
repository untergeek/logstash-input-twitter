# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/timestamp"
require "logstash/util"
require "logstash/json"

# Read events from the twitter streaming api.
class LogStash::Inputs::Twitter < LogStash::Inputs::Base

  config_name "twitter"

  # Your twitter app's consumer key
  #
  # Don't know what this is? You need to create an "application"
  # on twitter, see this url: <https://dev.twitter.com/apps/new>
  config :consumer_key, :validate => :string, :required => true

  # Your twitter app's consumer secret
  #
  # If you don't have one of these, you can create one by
  # registering a new application with twitter:
  # <https://dev.twitter.com/apps/new>
  config :consumer_secret, :validate => :password, :required => true

  # Your oauth token.
  #
  # To get this, login to twitter with whatever account you want,
  # then visit <https://dev.twitter.com/apps>
  #
  # Click on your app (used with the consumer_key and consumer_secret settings)
  # Then at the bottom of the page, click 'Create my access token' which
  # will create an oauth token and secret bound to your account and that
  # application.
  config :oauth_token, :validate => :string, :required => true

  # Your oauth token secret.
  #
  # To get this, login to twitter with whatever account you want,
  # then visit <https://dev.twitter.com/apps>
  #
  # Click on your app (used with the consumer_key and consumer_secret settings)
  # Then at the bottom of the page, click 'Create my access token' which
  # will create an oauth token and secret bound to your account and that
  # application.
  config :oauth_token_secret, :validate => :password, :required => true

  # Any keywords to track in the twitter stream
  config :keywords, :validate => :array, :required => true

  # Record full tweet object as given to us by the Twitter stream api.
  config :full_tweet, :validate => :boolean, :default => false

  # Proxy settings.  The proxy object will be built from the proxy settings
  # included here.  If proxy_host is not provided, any other proxy arguments
  # will be ignored.
  #
  # Proxy hostname or IP
  config :proxy_host, :validate => :string

  # Proxy port
  config :proxy_port, :validate => :string

  # Connect to proxy securely, via HTTPS
  config :proxy_secure, :validate => :boolean, :default => false

  # Proxy username (if required)
  config :proxy_user, :validate => :string

  # Proxy password (if required)
  config :proxy_pass, :validate => :password

  public
  def register
    require "twitter"

    # monkey patch twitter gem to ignore json parsing error.
    # at the same time, use our own json parser
    # this has been tested with a specific gem version, raise if not the same
    raise("Incompatible Twitter gem version and the LogStash::Json.load") unless Twitter::Version.to_s == "5.12.0"

    Twitter::Streaming::Response.module_eval do
      def on_body(data)
        @tokenizer.extract(data).each do |line|
          next if line.empty?
          begin
            @block.call(LogStash::Json.load(line, :symbolize_keys => true))
          rescue LogStash::Json::ParserError
            # silently ignore json parsing errors
          end
        end
      end
    end

    # proxyobj should follow the pattern:
    # http[s]://[user:pass@]host.tld[:port]
    http_method = @proxy_secure ? 'https' : 'http'

    if @proxy_user && @proxy_pass
      proxyauth = @proxy_user + ':' + @proxy_pass.value + '@'
    else
      proxyauth = nil
    end

    if @proxy_host && @proxy_port
      proxytarget = @proxy_host + ':' + @proxy_port
      proxyobj = http_method + '://' + proxyauth + @proxy_host + ':' + @proxy_port
    elsif @proxy_host
      # Not a common occurrence, I should think, to have a proxy on port 80
      # but we'll catch it anyway
      proxyobj = http_method + '://' + proxyauth + @proxy_host
    else
      # Ensure a nil value here
      proxyobj = nil
    end

    @client = Twitter::Streaming::Client.new do |c|
      c.consumer_key = @consumer_key
      c.consumer_secret = @consumer_secret.value
      c.access_token = @oauth_token
      c.access_token_secret = @oauth_token_secret.value
      if proxyobj
        @logger.debug? && @logger.debug("Using proxy", :proxy => proxyobj.to_s)
        c.proxy = proxyobj
      end
    end
  end

  public
  def run(queue)
    @logger.info("Starting twitter tracking", :keywords => @keywords)
    begin
      @client.filter(:track => @keywords.join(",")) do |tweet|
        if tweet.is_a?(Twitter::Tweet)
          @logger.debug? && @logger.debug("Got tweet", :user => tweet.user.screen_name, :text => tweet.text)
          if @full_tweet
            event = LogStash::Event.new(LogStash::Util.stringify_symbols(tweet.to_hash))
            event.timestamp = LogStash::Timestamp.new(tweet.created_at)
          else
            event = LogStash::Event.new(
              LogStash::Event::TIMESTAMP => LogStash::Timestamp.new(tweet.created_at),
              "message" => tweet.full_text,
              "user" => tweet.user.screen_name,
              "client" => tweet.source,
              "retweeted" => tweet.retweeted?,
              "source" => "http://twitter.com/#{tweet.user.screen_name}/status/#{tweet.id}"
            )
            event["in-reply-to"] = tweet.in_reply_to_status_id if tweet.reply?
            unless tweet.urls.empty?
              event["urls"] = tweet.urls.map(&:expanded_url).map(&:to_s)
            end
          end

          decorate(event)
          queue << event
        end
      end # client.filter
    rescue LogStash::ShutdownSignal
      return
    rescue Twitter::Error::TooManyRequests => e
      @logger.warn("Twitter too many requests error, sleeping for #{e.rate_limit.reset_in}s")
      sleep(e.rate_limit.reset_in)
      retry
    rescue => e
      @logger.warn("Twitter client error", :message => e.message, :exception => e, :backtrace => e.backtrace)
      retry
    end
  end # def run
end # class LogStash::Inputs::Twitter

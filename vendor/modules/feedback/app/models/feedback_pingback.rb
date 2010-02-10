#
# Based on http://wiki.github.com/apotonick/pingback_engine/
#

require 'hpricot'
require 'open-uri'

class FeedbackPingback < DomainModel
  @@excerpt_length = 40
  cattr_accessor :excerpt_length

  attr_reader :parser, :linking_node

  validates_presence_of :content_node_id, :source_uri, :target_uri

  belongs_to :content_node
  has_one :comment, :as => :source, :dependent => :destroy

  def self.process_incoming_ping(source_uri, target_uri)
    # make sure target_uri exists on this site
    content_node = self.get_content_node_for_target(target_uri)

    pingback = FeedbackPingback.new :content_node_id => content_node.id,
                                    :source_uri => source_uri,
                                    :target_uri => target_uri,
                                    :posted_at => Time.now

    raise FeedbackPingback::Error.already_registered if pingback.already_registered?

    # make sure source_uri actually contains the target_uri
    pingback.process_ping_source

    # save the pingback
    pingback.save
    raise FeedbackPingback::Error.error('Error occurred') if pingback.id.blank?

    pingback
  end

  def already_registered?
    self.class.find_by_target_uri_and_source_uri(self.target_uri, self.source_uri)
  end

  def process_ping_source
    begin
      source_html = retrieve_source_content(self.source_uri)
      @parser = parse(source_html)
      raise FeedbackPingback::Error.source_missing_target unless @linking_node = find_linking_node_to(self.target_uri)
      self.title = parse_title
      self.excerpt = excerpt_content_to(@linking_node, self.target_uri)
    rescue SocketError, OpenURI::HTTPError => e
      raise FeedbackPingback::Error.source_not_found
    end
  end

  def retrieve_source_content(source_uri)
    return open(source_uri) if source_uri =~ /^http:\/\//
    source_uri
  end
  
  def parse(html)
    Hpricot(html)
  end
  
  def parse_title
    if elem = parser.at(:title)
      return Util::TextFormatter.text_plain_generator(elem.inner_html)
    end

    nil
  end
  
  def find_linking_node_to(target_uri)
    elem = (parser / :a).find do |link|
      link[:href] == target_uri
    end
  end
  
  def excerpt_content_to(link_node, target_uri)
    parent  = link_node.parent
    link_i  = parent.children.index(link_node)
    before  = link_i > 0 ? Util::TextFormatter.text_plain_generator(parent.children[0..link_i-1].join) : ''
    after   = (link_i+1) < parent.children.length ? Util::TextFormatter.text_plain_generator(parent.children[link_i+1..-1].join) : ''

    trim_before_text_for(before) + Util::TextFormatter.text_plain_generator(link_node.to_s) + trim_after_text_for(after)
  end
  
  def trim_before_text_for(text)
    return text if text.length <= @@excerpt_length
    text.slice(-@@excerpt_length..-1)
  end
  
  def trim_after_text_for(text)
    text.slice(0..excerpt_lengthi)
  end
  
  def excerpt_lengthi
    @@excerpt_length-1
  end

  def self.get_content_node_for_target(target_uri)
    if target_uri =~ /https?:\/\/(.*?)(\/.*)/
      raise FeedbackPingback::Error.target_not_found("Invalid host") unless self.valid_host?($1)
      raise FeedbackPingback::Error.target_not_found("Page not specified") if $2.blank?

      content_node_value = ContentNodeValue.find_by_link $2.split("?")[0]
      raise FeedbackPingback::Error.target_not_found("Missing page") unless content_node_value

      content_node = ContentNode.find_by_id content_node_value.content_node_id
      raise FeedbackPingback::Error.target_not_found("Content Node is missing?") unless content_node

      raise FeedbackPingback::Error.access_denied if content_node.content_type.protected_results?

      return content_node
    end

    raise FeedbackPingback::Error.target_not_found('Malformed target')
  end

  def self.valid_host?(target_host)
    domain = DomainModel.active_domain[:name]
    domain == target_host || ('www.' + domain) == target_host
  end

  def create_comment(myself)
    return if Comment.for_source(self.class.to_s, self.id).find(:first)

    cm = Comment.create :source => self,
      :target => self.content_node.node,
      :posted_at => self.posted_at,
      :comment => "[...] #{self.excerpt} [...]",
      :rating => 1,
      :rated_at => Time.now,
      :rated_by_user_id => myself.id,
      :name => self.title,
      :website => self.source_uri

    if cm.id
      self.has_comment = true
      self.save
    end
  end

  def self.create_comments(myself, ids)
    ids.each do |id|
      pingback = FeedbackPingback.find_by_id(id)
      pingback.create_comment(myself) if pingback
    end
  end

  class Error < Exception
    attr_accessor :errno

    ERROR = 0
    SOURCE_NOT_FOUND = 16
    SOURCE_MISSING_TARGET = 17
    TARGET_NOT_FOUND = 32
    TARGET_INVALID = 33
    ALREADY_REGISTERED = 48
    ACCESS_DENIED = 49
    SERVER = 50

    def initialize(message, errno=0)
      super(message)
      self.errno = errno
    end

    def self.method_missing(method, *args)
      msg = args.length > 0 ? args[0] : method.to_s.humanize
      errno = FeedbackPingback::Error::ERROR
      begin
	errno = "FeedbackPingback::Error::#{method.to_s.upcase}".constantize
      rescue
	raise
      end

      FeedbackPingback::Error.new msg, errno
    end
  end
end

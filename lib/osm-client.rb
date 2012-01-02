require 'lib/hash'
require 'lib/callbacks'
require 'lib/open_street_map/tags'
require 'lib/open_street_map/element'
require 'lib/open_street_map/node'
require 'lib/open_street_map/way'
require 'lib/open_street_map/changeset'
require 'lib/open_street_map/relation'
require 'lib/open_street_map/errors'
require 'lib/open_street_map/basic_auth_client'
require 'lib/open_street_map/oauth_client'
require 'httparty'

# The OpenStreetMap class handles all calls to the OpenStreetMap API.
#
# Usage:
#   require 'open_street_map/api'
#   osm = OpenStreetMap.new(:user_name => 'user', :password => 'a_password')
#   @node = osm.find(:node => 1234)
#   @node.tags << {:wheelchair => 'no'}
#   osm.save(@node)
#
# In most cases you can use the more convenient methods on the OpenStreetMap::Node, OpenStreetMap::Way,
# or OpenStreetMap::Relation objects.
#
class OpenStreetMap
  include HTTParty
  include Callbacks
  API_VERSION = "0.6".freeze

  # the default base URI for the API
  base_uri "http://www.openstreetmap.org/api/#{API_VERSION}"
  default_timeout 2

  attr_accessor :client

  attr_accessor :changeset

  def initialize(client=nil)
    @client = client
  end

  def changeset!
    @changeset ||= create_changeset
  end

  # Get an object ('node', 'way', or 'relation') with specified ID from API.
  #
  # call-seq: find_element('node', id) -> OpenStreetMap::Element
  #
  def find_element(type, id)
    raise ArgumentError.new("type needs to be one of 'node', 'way', and 'relation'") unless type =~ /^(node|way|relation)$/
    raise TypeError.new('id needs to be a positive integer') unless(id.kind_of?(Fixnum) && id > 0)
    response = get("/#{type}/#{id}")
    check_response_codes(response)
    case type
    when 'node'
      OpenStreetMap::Node.new(response['osm']['node'])
    when 'way'
      OpenStreetMap::Way.new(response['osm']['way'])
    when 'relation'
      OpenStreetMap::Relation.new(response['osm']['relation'])
    when 'changeset'
      OpenStreetMap::Changeset.new(response['osm']['changeset'])
    end

  end

  # Get a Node with specified ID from API.
  #
  # call-seq: find_node(id) -> OpenStreetMap::Node
  #
  def find_node(id)
    find_element('node', id)
  end

  # Get a Way with specified ID from API.
  #
  # call-seq: find_way(id) -> OpenStreetMap::Way
  #
  def find_way(id)
    find_element('way', id)
  end

  # Get a Relation with specified ID from API.
  #
  # call-seq: find_relation(id) -> OpenStreetMap::Relation
  #
  def find_relation(id)
    find_element('relation', id)
  end

  # Get a Changeset with specified ID from API.
  #
  # call-seq: find_changeset(id) -> OpenStreetMap::Changeset
  #
  def find_changeset(id)
    find_element('changeset', id)
  end

  def find_user_id
    raise CredentialsMissing if client.nil?
    response = do_authenticated_request(:get, "/user/details")
    response['osm']['user']['id']
  end

  # Saves an element to the API.
  # If it has no id yet, the element will be created, otherwise updated.
  def save(element)
    raise CredentialsMissing if client.nil?
    response = if element.id.nil?
      create(element)
    else
      update(element)
    end
  end

  def create(element)
    raise CredentialsMissing if client.nil?
    response = put("/#{element.type.downcase}/create", :body => element.to_xml)
  end

  def update(element)
    raise CredentialsMissing if client.nil?
    raise ChangesetMissing unless changeset.open?
    response = post("/#{element.type.downcase}/#{element.id}", :body => element.to_xml)
  end

  def create_changeset
    changeset = OpenStreetMap::Changeset.new
    response = put("/changeset/create", :body => changeset.to_xml)
    OpenStreetMap::Changeset.new(:id => response) unless response == 0
  end

  private

  # most GET requests are valid without authentication, so this is the standard
  def get(url, options = {})
    do_request(:get, url, options)
  end

  # all PUT requests need authorization, so this is the stanard
  def put(url, options = {})
    do_authenticated_request(:put, url, options)
  end

  # all POST requests need authorization, so this is the stanard
  def post(url, options = {})
    do_authenticated_request(:post, url, options)
  end

  # all DELETE requests need authorization, so this is the stanard
  def delete(url, options = {})
    do_authenticated_request(:delete, url, options)
  end

  # Do a API request without authentication
  def do_request(method, url, options = {})
    response = self.class.send(method, url, options)
    check_response_codes(response)
    response
  end

  # Do a API request with authentication, using the given client
  def do_authenticated_request(method, url, options = {})
    response = case client
    when OpenStreetMap::BasicAuthClient
      self.class.send(method, url, options.merge(:basic_auth => client.credentials))
    when OpenStreetMap::OauthClient
      client.send(method, url, options)
    end
    check_response_codes(response)
    response
  end

  def find_open_changeset
    raise CredentialsMissing if client.nil?
    user_id = find_user_id
    response = get("/changesets", :query => {:open => true, :user => user_id})
    changeset_hash = case response['osm']['changeset']
    when Array
      response['osm']['changeset'].first
    when Hash
      response['osm']['changeset']
    else
      nil
    end

    OpenStreetMap::Changeset.new(changeset_hash) unless changeset_hash.nil?
  end

  def find_or_create_open_changeset(options = {})
    @changeset = find_open_changeset || create_changeset
  end

  def check_response_codes(response)
    body = response.body
    case response.code.to_i
      when 200 then return
      when 400 then raise BadRequest.new(body)
      when 401 then raise Unauthorized.new(body)
      when 404 then raise NotFound.new(body)
      when 405 then raise MethodNotAllowed.new(body)
      when 409 then raise Conflict.new(body)
      when 410 then raise Gone.new(body)
      when 412 then raise Precondition.new(body)
      when 500 then raise ServerError
      else raise Error
    end
  end

end

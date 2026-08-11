#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

BASE_URL = ENV.fetch('QDRANT_URL', 'http://127.0.0.1:9090').sub(%r{/$}, '')
ADMIN_KEY = ENV.fetch('QDRANT_API_KEY', '')
READ_ONLY_KEY = ENV.fetch('QDRANT_READ_ONLY_API_KEY', ADMIN_KEY)
COLLECTION = ENV.fetch('QDRANT_COLLECTION', 'ruby_demo')

abort 'Set QDRANT_API_KEY before running this example' if ADMIN_KEY.empty?

def request(method, path, api_key:, body: nil)
  uri = URI("#{BASE_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = 15
  http.read_timeout = 60

  klass = {
    get: Net::HTTP::Get,
    put: Net::HTTP::Put,
    post: Net::HTTP::Post
  }.fetch(method)
  req = klass.new(uri)
  req['api-key'] = api_key
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate(body) if body

  response = http.request(req)
  parsed = response.body.empty? ? {} : JSON.parse(response.body)
  raise "HTTP #{response.code}: #{parsed}" unless response.is_a?(Net::HTTPSuccess)

  parsed
end

puts "[ruby] Endpoint: #{BASE_URL}"
puts "[ruby] Collection: #{COLLECTION}"

collections = request(:get, '/collections', api_key: ADMIN_KEY).dig('result', 'collections') || []
unless collections.any? { |collection| collection['name'] == COLLECTION }
  request(
    :put,
    "/collections/#{COLLECTION}",
    api_key: ADMIN_KEY,
    body: { vectors: { size: 4, distance: 'Cosine' } }
  )
end

request(
  :put,
  "/collections/#{COLLECTION}/points?wait=true",
  api_key: ADMIN_KEY,
  body: {
    points: [
      { id: 1, vector: [0.9, 0.1, 0.1, 0.1], payload: { name: 'red' } },
      { id: 2, vector: [0.1, 0.9, 0.1, 0.1], payload: { name: 'green' } },
      { id: 3, vector: [0.1, 0.1, 0.9, 0.1], payload: { name: 'blue' } }
    ]
  }
)

result = request(
  :post,
  "/collections/#{COLLECTION}/points/query",
  api_key: READ_ONLY_KEY,
  body: { query: [0.8, 0.2, 0.1, 0.1], limit: 3, with_payload: true }
)
puts JSON.pretty_generate(result)

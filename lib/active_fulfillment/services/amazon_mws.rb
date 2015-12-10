require 'base64'
require 'time'
require 'cgi'
require 'active_support/core_ext/hash/except'

module ActiveFulfillment
  class AmazonMarketplaceWebService < Service

    APPLICATION_IDENTIFIER = "active_merchant_mws/0.01 (Language=ruby)"

    REGISTRATION_URI = URI.parse("https://sellercentral.amazon.com/gp/mws/registration/register.html")

    SIGNATURE_VERSION = 2
    SIGNATURE_METHOD  = "SHA256"
    VERSION = "2010-10-01"

    SUCCESS, FAILURE, ERROR = 'Accepted', 'Failure', 'Error'

    ENDPOINTS = {
      :ca => 'mws.amazonservices.ca',
      :cn => 'mws.amazonservices.com.cn',
      :de => 'mws-eu.amazonservices.ca',
      :es => 'mws-eu.amazonservices.ca',
      :fr => 'mws-eu.amazonservices.ca',
      :it => 'mws-eu.amazonservices.ca',
      :jp => 'mws.amazonservices.jp',
      :uk => 'mws-eu.amazonservices.ca',
      :us => 'mws.amazonservices.com'
    }

    LOOKUPS = {
      :destination_address => {
        :name => "DestinationAddress.Name",
        :address1 => "DestinationAddress.Line1",
        :address2 => "DestinationAddress.Line2",
        :city => "DestinationAddress.City",
        :state => "DestinationAddress.StateOrProvinceCode",
        :country => "DestinationAddress.CountryCode",
        :zip => "DestinationAddress.PostalCode",
        :phone => "DestinationAddress.PhoneNumber"
      },
      :line_items => {
        :comment => "Items.member.%d.DisplayableComment",
        :gift_message => "Items.member.%d.GiftMessage",
        :currency_code => "Items.member.%d.PerUnitDeclaredValue.CurrencyCode",
        :value => "Items.member.%d.PerUnitDeclaredValue.Value",
        :quantity => "Items.member.%d.Quantity",
        :order_id => "Items.member.%d.SellerFulfillmentOrderItemId",
        :sku => "Items.member.%d.SellerSKU",
        :network_sku => "Items.member.%d.FulfillmentNetworkSKU",
        :item_disposition => "Items.member.%d.OrderItemDisposition",
      },
      :list_inventory => {
        :sku => "SellerSkus.member.%d"
      }
    }

    # The first is the label, and the last is the code
    # Standard:  3-5 business days
    # Expedited: 2 business days
    # Priority:  1 business day
    def self.shipping_methods
      [
        [ 'Standard Shipping', 'Standard' ],
        [ 'Expedited Shipping', 'Expedited' ],
        [ 'Priority Shipping', 'Priority' ]
      ].inject({}){|h, (k,v)| h[k] = v; h}
    end

    def initialize(options = {})
      requires!(options, :login, :password)
      @seller_id = options[:seller_id]
      @mws_auth_token = options[:mws_auth_token]
      super
    end

    def seller_id=(seller_id)
      @seller_id = seller_id
    end

    def endpoint
      ENDPOINTS[@options[:endpoint] || :us]
    end

    def fulfill(order_id, shipping_address, line_items, options = {})
      requires!(options, :order_date, :shipping_method)
      with_error_handling do
        data = commit :post, 'CreateFulfillmentOrder', build_fulfillment_request(order_id, shipping_address, line_items, options)
        parse_fulfillment_response(parse_document(data), 'Successfully submitted the order')
      end
    end

    def status
      with_error_handling do
        data = commit :post, 'GetServiceStatus', build_basic_api_query({ :Action => 'GetServiceStatus' })
        parse_tracking_response(parse_document(data))
      end
    end

    def fetch_current_orders
      with_error_handling do
        data = commit :post, 'GetServiceStatus', build_get_current_fulfillment_orders_request
        parse_tracking_response(parse_document(data))
      end
    end

    def fetch_stock_levels(options = {})
      options[:skus] = [options.delete(:sku)] if options.include?(:sku)
      response = with_error_handling do
        data = commit :post, 'ListInventorySupply', build_inventory_list_request(options)
        parse_inventory_response(parse_document(data))
      end
      while token = response.params['next_token'] do
        next_page = with_error_handling do
          data = commit :post, 'ListInventorySupplyByNextToken', build_next_inventory_list_request(token)
          parse_inventory_response(parse_document(data))
        end

        # if we fail during the stock-level-via-token gathering, fail the whole request
        return next_page if next_page.params['response_status'] != SUCCESS
        next_page.stock_levels.merge!(response.stock_levels)
        response = next_page
      end

      response
    end

    def fetch_tracking_data(order_ids, options = {})
      index = 0
      order_ids.reduce(nil) do |previous, order_id|
        index += 1
        response = with_error_handling do
          data = commit :post, 'GetFulfillmentOrder', build_tracking_request(order_id, options)
          parse_tracking_response(parse_document(data))
        end

        return response if !response.success?

        if previous
          sleep_for_throttle_options(options[:throttle], index)
          response.tracking_numbers.merge!(previous.tracking_numbers)
          response.tracking_companies.merge!(previous.tracking_companies)
          response.tracking_urls.merge!(previous.tracking_urls)
        end

        response
      end
    end

    def valid_credentials?
      fetch_stock_levels.success?
    end

    def test_mode?
      false
    end

    def build_full_query(verb, uri, params)
      signature = sign(verb, uri, params)
      build_query(params) + "&Signature=#{signature}"
    end

    def commit(verb, action, params)
      uri = URI.parse("https://#{endpoint}/#{action}/#{VERSION}")
      query = build_full_query(verb, uri, params)
      headers = build_headers(query)
      log_query = query.dup
      [@options[:login], @options[:app_id], @mws_auth_token].each { |key| log_query.gsub!(/#{key}/, '[filtered]') if key.present? }

      logger.info "[#{self.class}][#{action}] query=#{log_query}"
      data = ssl_post(uri.to_s, query, headers)
      logger.info "[#{self.class}][#{action}] response=#{data}"
      data
    end

    def handle_error(e)
      logger.info "[#{self.class}][ResponseError] response=#{e.response.try(:body)}, message=#{e.message}"
      response = parse_error(e.response)
      if response.fetch(:faultstring, "").match(/^Requested order \'.+\' not found$/)
        Response.new(true, nil, {:status => SUCCESS, :tracking_numbers => {}, :tracking_companies => {}, :tracking_urls => {}})
      else
        Response.new(false, message_from(response), response)
      end
    end

    def success?(response)
      response[:response_status] == SUCCESS
    end

    def message_from(response)
      response[:response_message]
    end

    ## PARSING

    def parse_document(xml)
      begin
        document = REXML::Document.new(xml)
      rescue REXML::ParseException
        return { :success => FAILURE }
      end
    end

    def parse_tracking_response(document)
      response = {}
      response[:tracking_numbers] = {}
      response[:tracking_companies] = {}
      response[:tracking_urls] = {}

      tracking_numbers = REXML::XPath.match(document, "//FulfillmentShipmentPackage/member/TrackingNumber")
      if tracking_numbers.present?
        order_id = REXML::XPath.first(document, "//FulfillmentOrder/SellerFulfillmentOrderId").text.strip
        response[:tracking_numbers][order_id] = tracking_numbers.map{ |t| t.text.strip }
      end

      tracking_companies = REXML::XPath.match(document, "//FulfillmentShipmentPackage/member/CarrierCode")
      if tracking_companies.present?
        order_id = REXML::XPath.first(document, "//FulfillmentOrder/SellerFulfillmentOrderId").text.strip
        response[:tracking_companies][order_id] = tracking_companies.map{ |t| t.text.strip }
      end

      response[:response_status] = SUCCESS
      Response.new(success?(response), message_from(response), response)
    end

    def parse_fulfillment_response(document, message)
      Response.new(true, message, { :response_status => SUCCESS, :response_comment => message })
    end

    def parse_inventory_response(document)
      response = {}
      response[:stock_levels] = {}

      document.each_element('//InventorySupplyList/member') do |node|
        params = node.elements.to_a.each_with_object({}) { |elem, hash| hash[elem.name] = elem.text }

        response[:stock_levels][params['SellerSKU']] = params['InStockSupplyQuantity'].to_i
      end

      next_token = REXML::XPath.first(document, '//NextToken')
      response[:next_token] = next_token ? next_token.text : nil

      response[:response_status] = SUCCESS
      response
      Response.new(success?(response), message_from(response), response)
    end

    def parse_error(http_response)
      response = {}
      response[:http_code] = http_response.code
      response[:http_message] = http_response.message

      document = REXML::Document.new(http_response.body)

      node = REXML::XPath.first(document, '//Error')
      error_code = REXML::XPath.first(node, '//Code')
      error_message = REXML::XPath.first(node, '//Message')

      response[:status] = FAILURE
      response[:faultcode] = error_code ? error_code.text : ""
      response[:faultstring] = error_message ? error_message.text : ""
      response[:response_message] = error_message ? error_message.text : ""
      response[:response_comment] = "#{response[:faultcode]}: #{response[:faultstring]}"
      response
    rescue REXML::ParseException => e
    rescue NoMethodError => e
      response[:http_body] = http_response.body
      response[:response_status] = FAILURE
      response[:response_comment] = "#{response[:http_code]}: #{response[:http_message]}"
      response
    end

    def sign(http_verb, uri, options)
      string_to_sign = "#{http_verb.to_s.upcase}\n"
      string_to_sign += "#{uri.host}\n"
      string_to_sign += uri.path.length <= 0 ? "/\n" : "#{uri.path}\n"
      string_to_sign += build_query(options)

      # remove trailing newline created by encode64
      escape(Base64.encode64(OpenSSL::HMAC.digest(SIGNATURE_METHOD, @options[:password], string_to_sign)).chomp)
    end

    def amazon_request?(http_verb, base_url, return_path_and_parameters, post_params)
      signed_params = build_query(post_params.except(:Signature, :SignedString))
      string_to_sign = "#{http_verb}\n#{base_url}\n#{return_path_and_parameters}\n#{signed_params}"
      calculated_signature = Base64.encode64(OpenSSL::HMAC.digest(SIGNATURE_METHOD, @options[:password], string_to_sign)).chomp
      secure_compare(calculated_signature, post_params[:Signature])
    end

    def registration_url(options)
      opts = {
        "returnPathAndParameters" => options["returnPathAndParameters"],
        "id" => @options[:app_id],
        "AWSAccessKeyId" => @options[:login],
        "SignatureMethod" => "Hmac#{SIGNATURE_METHOD}",
        "SignatureVersion" => SIGNATURE_VERSION
      }
      signature = sign(:get, REGISTRATION_URI, opts)
      "#{REGISTRATION_URI.to_s}?#{build_query(opts)}&Signature=#{signature}"
    end

    def md5_content(content)
      Base64.encode64(OpenSSL::Digest.new('md5', content).digest).chomp
    end

    def build_query(query_params)
      query_params.sort.map{ |key, value| [escape(key.to_s), escape(value.to_s)].join('=') }.join('&')
    end

    def build_headers(querystr)
      {
        'User-Agent' => APPLICATION_IDENTIFIER,
        'Content-MD5' => md5_content(querystr),
        'Content-Type' => 'application/x-www-form-urlencoded'
      }
    end

    def build_basic_api_query(options)
      opts = Hash[options.map{ |k,v| [k.to_s, v.to_s] }]
      opts["AWSAccessKeyId"] = @options[:login] unless opts["AWSAccessKey"]
      opts["Timestamp"] = Time.now.utc.iso8601 unless opts["Timestamp"]
      opts["Version"] = VERSION unless opts["Version"]
      opts["SignatureMethod"] = "Hmac#{SIGNATURE_METHOD}" unless opts["SignatureMethod"]
      opts["SignatureVersion"] = SIGNATURE_VERSION unless opts["SignatureVersion"]
      opts["SellerId"] = @seller_id unless opts["SellerId"] || !@seller_id
      opts["MWSAuthToken"] = @mws_auth_token unless opts["MWSAuthToken"] || !@mws_auth_token
      opts
    end

    def build_fulfillment_request(order_id, shipping_address, line_items, options)
      params = {
        :Action => 'CreateFulfillmentOrder',
        :SellerFulfillmentOrderId => order_id.to_s,
        :DisplayableOrderId => order_id.to_s,
        :DisplayableOrderDateTime => options[:order_date].utc.iso8601,
        :ShippingSpeedCategory => options[:shipping_method]
      }
      params[:DisplayableOrderComment] = options[:comment] if options[:comment]

      request = build_basic_api_query(params.merge(options))
      request = request.merge build_address(shipping_address)
      request = request.merge build_items(line_items)

      request
    end

    def build_get_current_fulfillment_orders_request(options = {})
      start_time = options.delete(:start_time) || 1.day.ago.utc
      params = {
        :Action => 'ListAllFulfillmentOrders',
        :QueryStartDateTime => start_time.strftime("%Y-%m-%dT%H:%M:%SZ")
      }

      build_basic_api_query(params.merge(options))
    end

    def build_inventory_list_request(options = {})
      response_group = options.delete(:response_group) || "Basic"
      params = {
        :Action => 'ListInventorySupply',
        :ResponseGroup => response_group
      }
      if skus = options.delete(:skus)
        skus.each_with_index do |sku, index|
          params[LOOKUPS[:list_inventory][:sku] % (index + 1)] = sku
        end
      else
        start_time = options.delete(:start_time) || 1.day.ago
        params[:QueryStartDateTime] = start_time.utc.iso8601
      end

      build_basic_api_query(params.merge(options))
    end

    def build_next_inventory_list_request(token)
      params = {
        :NextToken => token,
        :Action => 'ListInventorySupplyByNextToken'
      }

      build_basic_api_query(params)
    end

    def build_tracking_request(order_id, options)
      params = {:Action => 'GetFulfillmentOrder', :SellerFulfillmentOrderId => order_id}

      build_basic_api_query(params.merge(options))
    end

    def build_address(address)
      requires!(address, :name, :address1, :city, :country, :zip)
      address[:state] ||= "N/A"
      address[:zip].upcase! if address[:zip]
      address[:name] = "#{address[:company]} - #{address[:name]}" if address[:company].present?
      address[:name] = address[:name][0...50] if address[:name].present?
      ary = address.map{ |key, value| [LOOKUPS[:destination_address][key], value] if LOOKUPS[:destination_address].include?(key) && value.present? }
      Hash[ary.compact]
    end

    def build_items(line_items)
      lookup = LOOKUPS[:line_items]
      counter = 0
      line_items.reduce({}) do |items, line_item|
        counter += 1
        lookup.each do |key, value|
          entry = value % counter
          case key
          when :sku
            items[entry] = line_item[:sku] || "SKU-#{counter}"
          when :order_id
            items[entry] = line_item[:sku] || "FULFILLMENT-ITEM-ID-#{counter}"
          when :quantity
            items[entry] = line_item[:quantity] || 1
          else
            items[entry] = line_item[key] if line_item.include? key
          end
        end
        items
      end
    end

    def escape(str)
      CGI.escape(str.to_s).gsub('+', '%20')
    end

    private

    def with_error_handling
      yield
    rescue ActiveUtils::ResponseError => e
      handle_error(e)
    end

    def sleep_for_throttle_options(throttle_options, index)
      return unless interval = throttle_options.try(:[], :interval)
      sleep(throttle_options[:sleep_time]) if (index % interval).zero?
    end

    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      l = a.unpack "C#{a.bytesize}"

      res = 0
      b.each_byte { |byte| res |= byte ^ l.shift }
      res == 0
    end
  end
end

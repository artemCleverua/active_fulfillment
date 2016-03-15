require 'cgi'

module ActiveFulfillment
  class ShipwireService < Service

    SERVICE_URLS = { :fulfillment  => 'https://api.shipwire.com/exec/FulfillmentServices.php',
                     :inventory    => 'https://api.shipwire.com/exec/InventoryServices.php',
                     :tracking     => 'https://api.shipwire.com/exec/TrackingServices.php',
                     :rate         => 'https://api.shipwire.com/exec/RateServices.php'
                   }.freeze

    SCHEMA_URLS = { :fulfillment => 'http://www.shipwire.com/exec/download/OrderList.dtd',
                    :inventory   => 'http://www.shipwire.com/exec/download/InventoryUpdate.dtd',
                    :tracking    => 'http://www.shipwire.com/exec/download/TrackingUpdate.dtd',
                    :rate        => 'http://www.shipwire.com/exec/download/RateRequest.dtd'
                  }.freeze

    POST_VARS = { :fulfillment => 'OrderListXML',
                  :inventory   => 'InventoryUpdateXML',
                  :tracking    => 'TrackingUpdateXML',
                  :rate        => 'RateRequestXML'
                }.freeze

    WAREHOUSES = { 'CHI' => 'Chicago',
                   'LAX' => 'Los Angeles',
                   'REN' => 'Reno',
                   'VAN' => 'Vancouver',
                   'TOR' => 'Toronto',
                   'UK'  => 'United Kingdom'
                 }.freeze

    SHIPPING_METHODS = {
      '1 Day Service' => '1D',
      '2 Day Service' => '2D',
      'Ground Service' => 'GD',
      'Freight Service' => 'FT',
      'International' => 'INTL'
    }.freeze

    INVALID_LOGIN = /(Error with Valid Username\/EmailAddress and Password Required)|(Could not verify Username\/EmailAddress and Password combination)/

    class_attribute :affiliate_id

    # The first is the label, and the last is the code
    def self.shipping_methods
      SHIPPING_METHODS
    end

    # Pass in the login and password for the shipwire account.
    # Optionally pass in the :test => true to force test mode
    def initialize(options = {})
      requires!(options, :login, :password)

      super
    end

    def fulfill(order_id, shipping_address, line_items, options = {})
      commit :fulfillment, build_fulfillment_request(order_id, shipping_address, line_items, options)
    end

    def fetch_stock_levels(options = {})
      commit :inventory, build_inventory_request(options)
    end

    def fetch_tracking_data(order_ids, options = {})
      commit :tracking, build_tracking_request(order_ids)
    end

    def fetch_rate_data(order_id, shipping_address, line_items, options = {})
      commit :rate, build_rate_request(order_id, shipping_address, line_items, options)
    end

    def valid_credentials?
      response = fetch_tracking_numbers([])
      response.message !~ INVALID_LOGIN
    end

    def test_mode?
      true
    end

    def include_pending_stock?
      @options[:include_pending_stock]
    end

    def include_empty_stock?
      @options[:include_empty_stock]
    end

    private
    def build_fulfillment_request(order_id, shipping_address, line_items, options)
      xml = Builder::XmlMarkup.new :indent => 2
      xml.instruct!
      xml.declare! :DOCTYPE, :OrderList, :SYSTEM, SCHEMA_URLS[:fulfillment]
      xml.tag! 'OrderList' do
        add_credentials(xml)
        xml.tag! 'Referer', 'Active Fulfillment'
        add_order(xml, order_id, shipping_address, line_items, options)
      end
      xml.target!
    end

    def build_inventory_request(options)
      xml = Builder::XmlMarkup.new :indent => 2
      xml.instruct!
      xml.declare! :DOCTYPE, :InventoryStatus, :SYSTEM, SCHEMA_URLS[:inventory]
      xml.tag! 'InventoryUpdate' do
        add_credentials(xml)
        xml.tag! 'Warehouse', WAREHOUSES[options[:warehouse]]
        xml.tag! 'ProductCode', options[:sku]
        xml.tag! 'IncludeEmpty' if include_empty_stock?
      end
    end

    def build_tracking_request(order_ids)
      xml = Builder::XmlMarkup.new
      xml.instruct!
      xml.declare! :DOCTYPE, :InventoryStatus, :SYSTEM, SCHEMA_URLS[:inventory]
      xml.tag! 'TrackingUpdate' do
        add_credentials(xml)
        xml.tag! 'Server', test? ? 'Test' : 'Production'
        order_ids.each do |o_id|
          xml.tag! 'OrderNo', o_id
        end
      end
    end

    def build_rate_request(order_id, shipping_address, line_items, options)
      options[:rate] = true
      xml = Builder::XmlMarkup.new :indent => 2
      xml.instruct!
      xml.declare! :DOCTYPE, :RateRequest, :SYSTEM, SCHEMA_URLS[:rate]
      xml.tag! 'RateRequest' do
        add_rate_credentials(xml)
        add_order(xml, order_id, shipping_address, line_items, options)
      end
    end

    def add_credentials(xml)
      xml.tag! 'EmailAddress', @options[:login]
      xml.tag! 'Password', @options[:password]
      xml.tag! 'Server', test? ? 'Test' : 'Production'
      xml.tag! 'AffiliateId', affiliate_id if affiliate_id.present?
    end

    def add_rate_credentials(xml)
      xml.tag! 'EmailAddress', @options[:login]
      xml.tag! 'Password', @options[:password]
      xml.tag! 'Server', 'Production'
    end

    def add_order(xml, order_id, shipping_address, line_items, options)
      xml.tag! 'Order', :id => order_id do
        xml.tag! 'Warehouse', options[:warehouse] || '00'

        add_address(xml, shipping_address, options)
        xml.tag! 'Shipping', options[:shipping_method] unless (options[:shipping_method].blank? && options[:rate])

        Array(line_items).each_with_index do |line_item, index|
          add_item(xml, line_item, index)
        end
        xml.tag! 'Note' do
          xml.cdata! options[:note] unless options[:note].blank?
        end
      end
    end

    def add_address(xml, address, options)
      xml.tag! 'AddressInfo', :type => 'Ship' do
        if options[:rate].blank?
          xml.tag! 'Name' do
            xml.tag! 'Full', address[:name]
          end
        end

        xml.tag! 'Address1', address[:address1]
        xml.tag! 'Address2', address[:address2]

        xml.tag! 'Company', address[:company] if options[:rate].blank?

        xml.tag! 'City', address[:city]
        xml.tag! 'State', address[:state] unless address[:state].blank?
        xml.tag! 'Country', address[:country]

        xml.tag! 'Zip', address[:zip]
        if options[:rate].blank?
          xml.tag! 'Phone', address[:phone] unless address[:phone].blank?
          xml.tag! 'Email', options[:email] unless options[:email].blank?
        end
      end
    end

    # Code is limited to 12 characters
    def add_item(xml, item, index)
      xml.tag! 'Item', :num => index do
        xml.tag! 'Code', item[:sku]
        xml.tag! 'Quantity', item[:quantity]
      end
    end

    def commit(action, request)
      log_query = request.dup
      [@options[:password], affiliate_id].each { |key| log_query.gsub!(key.to_s, '[filtered]') if key.present? }
      logger.info "[#{self.class}][#{SERVICE_URLS[action]}][#{POST_VARS[action]}] query=#{log_query}"
      data = ssl_post(SERVICE_URLS[action], "#{POST_VARS[action]}=#{CGI.escape(request)}")
      logger.info "[#{self.class}][result] #{data}"

      response = parse_response(action, data)
      Response.new(response[:success], response[:message], response, :test => test?)
    end

    def parse_response(action, data)
      case action
      when :fulfillment
        parse_fulfillment_response(data)
      when :inventory
        parse_inventory_response(data)
      when :tracking
        parse_tracking_response(data)
      when :rate
        parse_rate_response(data)
      else
        raise ArgumentError, "Unknown action #{action}"
      end
    end

    def parse_fulfillment_response(xml)
      Parsing.with_xml_document(xml) do |document, response|
        document.root.try do |root_document|
          root_document.elements.each do |node|
            response[node.name.underscore.to_sym] = node.text.strip
          end
        end

        response[:success] = response[:status] == '0'.freeze
        response[:message] = response[:success] ? 'Successfully submitted the order'.freeze : message_from(response[:error_message])
        response
      end
    end

    def compute_stock_levels(document)
      items = {}
      products = document.xpath('//Product'.freeze)
      products.each do |product|
        qty = product.at_xpath('@quantity'.freeze).child.content.to_i
        code = product.at_xpath('@code'.freeze).child.content
        pending_qty = include_pending_stock? ? product.at_xpath('@pending'.freeze).child.content.to_i : 0
        items[code] = qty + pending_qty
      end
      items
    end

    def parse_inventory_response(xml)
      response = { stock_levels: {} }
      Parsing.with_xml_document(xml, response) do |document|
        status = document.at_xpath('//Status'.freeze).child.content
        success = test? ? status == 'Test'.freeze : status == '0'.freeze
        total_products = success ? document.at_xpath('//TotalProducts'.freeze).child.content : 0
        message = success ? 'Successfully received the stock levels'.freeze : document.at_xpath('//ErrorMessage'.freeze).child.content

        {
          status: status,
          total_products: total_products,
          stock_levels: compute_stock_levels(document),
          message: message,
          success: success
        }
      end
    end

    def shipped_order?(node)
      node.name == 'Order'.freeze && node.attributes['shipped'.freeze].text == 'YES'.freeze
    end

    def parse_tracking_response(xml)
      response = {
        tracking_numbers: {},
        tracking_companies: {},
        tracking_urls: {}
      }

      Parsing.with_xml_document(xml, response) do |document, response|
        document.root.try do |root_document|
          root_document.elements.each do |node|
            if shipped_order?(node)
              node_tracking = node.at_css('TrackingNumber'.freeze)
              unless node_tracking.nil?
                node_id = node.attributes['id'.freeze].text.strip
                tracking_number = node_tracking.text.strip
                response[:tracking_numbers][node_id] = [tracking_number]

                tracking_company = node_tracking.attributes['carrier'.freeze].try { |item| item.text.strip }
                response[:tracking_companies][node_id] = [tracking_company] if tracking_company

                tracking_url = node_tracking.attributes['href'.freeze].try { |item| item.text.strip }
                response[:tracking_urls][node_id] = [tracking_url] if tracking_url
              end
            else
              response[node.name.underscore.to_sym] = node.text.strip
            end
          end
        end
      end

      response[:success] = test? ? (response[:status] == '0'.freeze || response[:status] == 'Test'.freeze) : response[:status] == '0'.freeze
      response[:message] = response[:success] ? 'Successfully received the tracking numbers'.freeze : message_from(response[:error_message])
      response
    end

    def parse_rate_response(xml)
      response = {}
      response[:quote] = {}
      response[:warnings] = []

      Parsing.with_xml_document(xml, response) do |document, response|
        document.root.try do |root_document|
          if root_document.xpath('//RateResponse'.freeze).blank?
            response[root_document.name.underscore.to_sym] = node.text.strip
          else
            root_document.xpath('//RateResponse'.freeze).each do |node|
              status = node.xpath('Status'.freeze).text.strip
              response[:status] = status

              node.xpath('Order'.freeze).each do |order|
                order.xpath('Quotes'.freeze).each do |quotes|
                  quotes.xpath('Quote'.freeze).each do |quote|
                    quote_method = quote.attributes['method'.freeze].text
                    response[:quote][quote_method] = {}

                    quote_warehouse = quote.xpath('Warehouse').text.strip
                    response[:quote][quote_method]['warehouse'] = quote_warehouse

                    quote_service = quote.xpath('Service').text.strip
                    response[:quote][quote_method]['service'] = quote_service

                    cost = quote.xpath('Cost').first
                    total_cost = cost.attributes['originalCost'].text.strip
                    cost_currency = cost.attributes['currency'].text.strip

                    response[:quote][quote_method]['cost'] = {
                      'total' => total_cost,
                      'currency' => cost_currency
                    }

                    response[:quote][quote_method]['subtotal'] = {}
                    quote.xpath('Subtotals').each do |subtotals|
                      subtotals.xpath('Subtotal'.freeze).each do |subtotal|
                        sub_type = subtotal.attributes['type'].text.strip.downcase!
                        original_cost = subtotal.xpath('Cost').first.attributes['originalCost'].text.strip
                        response[:quote][quote_method]['subtotal'][sub_type] = original_cost
                      end
                    end

                    estimate_time = quote.xpath('DeliveryEstimate').first
                    estimate_min_day = estimate_time.xpath('Minimum').text.strip
                    estimate_max_day = estimate_time.xpath('Maximum').text.strip

                    response[:quote][quote_method]['estimate'] = {
                      'min_day' => estimate_min_day,
                      'max_day' => estimate_max_day
                    }
                  end
                end

                order.xpath('Warnings'.freeze).each do |warnings|
                  warnings.xpath('Warning'.freeze).each do |warning|
                    response[:warnings] << warning.text.strip
                  end
                end
              end
            end
          end
        end
      end

      response[:success] = response[:status] == 'OK'
      response[:message] = response[:success] ? 'Successfully received the rate data' : message_from(response[:error_message])

      response
    end

    def message_from(string)
      return if string.blank?
      string.gsub("\n", ''.freeze).squeeze(' '.freeze)
    end
  end
end

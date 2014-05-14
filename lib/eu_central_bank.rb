require 'rubygems'
require 'open-uri'
require 'nokogiri'
require 'money'

class InvalidCache < StandardError ; end

class EuCentralBank < Money::Bank::VariableExchange

  attr_accessor :last_updated
  attr_accessor :rates_updated_at
  attr_accessor :historical_last_updated
  attr_accessor :historical_rates_updated_at
  attr_accessor :latest_cache, :historical_cache
  attr_reader   :ttl_in_seconds
  attr_reader   :rates_expiration

  CURRENCIES = %w(USD JPY BGN CZK DKK GBP HUF ILS LTL PLN RON SEK CHF NOK HRK RUB TRY AUD BRL CAD CNY HKD IDR INR KRW MXN MYR NZD PHP SGD THB ZAR)
  ECB_RATES_URL = 'http://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml'
  ECB_90_DAY_URL = 'http://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist-90d.xml'

  def ttl_in_seconds=(value)
    @ttl_in_seconds=value
    refresh_rates_expiration if value
  end

  def refresh_rates_expiration
    @rates_expiration = Time.now + ttl_in_seconds
  end

  def cache(url)
    case url
    when ECB_RATES_URL then latest_cache
    when ECB_90_DAY_URL then historical_cache
    end
  end

  def expire_rates
    if ttl_in_seconds and rates_expiration <= Time.now
      update_rates(false)
      refresh_rates_expiration
    end
  end

  def update_rates(use_cache=true)
    update_parsed_rates(doc(use_cache))
  end

  def update_historical_rates
    update_parsed_historical_rates(doc(ECB_90_DAY_URL))
  end

  def save_rates(url=ECB_RATES_URL)
    raise InvalidCache unless cache(url)
    case cache(url)
    when String
      File.open(cache(url), "w") do |file|
        io = open(url);
        io.each_line { |line| file.puts line }
      end
    when Proc
      cache(url).call(save_rates_to_s(url))
    end
  end

  def update_rates_from_s(content)
    update_parsed_rates(doc_from_s(content))
  end

  def save_rates_to_s(url=ECB_RATES_URL)
    open(url).read
  end

  def exchange(cents, from_currency, to_currency, date=nil)
    exchange_with(Money.new(cents, from_currency), to_currency, date)
  end

  def exchange_with(from, to_currency, date=nil)
    from_base_rate, to_base_rate = nil, nil
    rate = get_rate(from, to_currency, {:date => date})

    unless rate
      @mutex.synchronize do
        opts = { :date => date, :without_mutex => true }
        from_base_rate = get_rate("EUR", from.currency.to_s, opts)
        to_base_rate = get_rate("EUR", to_currency, opts)
      end
      rate = to_base_rate / from_base_rate
    end

    calculate_exchange(from, to_currency, rate)
  end

  def get_rate(from, to, opts = {})
    expire_rates
    fn = -> { @rates[rate_key_for(from, to, opts)] }

    if opts[:without_mutex]
      fn.call
    else
      @mutex.synchronize { fn.call }
    end
  end

  def set_rate(from, to, rate, opts = {})
    fn = -> { @rates[rate_key_for(from, to, opts)] = rate }

    if opts[:without_mutex]
      fn.call
    else
      @mutex.synchronize { fn.call }
    end
  end

  protected

  def doc(use_cache=true, url=ECB_RATES_URL)
    if use_cache and !cache(url).nil?
      case cache(url)
      when String
        Nokogiri::XML(open(cache(url))).tap { |doc| doc.xpath('gesmes:Envelope/xmlns:Cube/xmlns:Cube//xmlns:Cube') }
      when Proc
        doc_from_s(cache(url).call(nil))
      end
    else
      save_rates(url) unless cache(url).nil?
      Nokogiri::XML(open(url)).tap { |doc| doc.xpath('gesmes:Envelope/xmlns:Cube/xmlns:Cube//xmlns:Cube') }
    end
  rescue Nokogiri::XML::XPath::SyntaxError
    save_rates(url) unless cache(url).nil?
    Nokogiri::XML(open(url))
  end

  def doc_from_s(content)
    Nokogiri::XML(content)
  end

  def update_parsed_rates(doc)
    rates = doc.xpath('gesmes:Envelope/xmlns:Cube/xmlns:Cube//xmlns:Cube')

    @mutex.synchronize do
      rates.each do |exchange_rate|
        rate = BigDecimal(exchange_rate.attribute("rate").value)
        currency = exchange_rate.attribute("currency").value
        set_rate("EUR", currency, rate, :without_mutex => true)
      end
      set_rate("EUR", "EUR", 1, :without_mutex => true)
    end

    rates_updated_at = doc.xpath('gesmes:Envelope/xmlns:Cube/xmlns:Cube/@time').first.value
    @rates_updated_at = Time.parse(rates_updated_at)

    @last_updated = Time.now
  end

  def update_parsed_historical_rates(doc)
    rates = doc.xpath('gesmes:Envelope/xmlns:Cube/xmlns:Cube//xmlns:Cube')

    @mutex.synchronize do
      rates.each do |exchange_rate|
        rate = BigDecimal(exchange_rate.attribute("rate").value)
        currency = exchange_rate.attribute("currency").value
        opts = { :without_mutex => true }
        opts[:date] = exchange_rate.parent.attribute("time").value
        set_rate("EUR", currency, rate, opts)
        set_rate("EUR", "EUR", 1, opts)
      end
    end

    rates_updated_at = doc.xpath('gesmes:Envelope/xmlns:Cube/xmlns:Cube/@time').first.value
    @historical_rates_updated_at = Time.parse(rates_updated_at)

    @historical_last_updated = Time.now
  end

  private

  def calculate_exchange(from, to_currency, rate)
    to_currency_money = Money::Currency.wrap(to_currency).subunit_to_unit
    from_currency_money = from.currency.subunit_to_unit
    decimal_money = BigDecimal(to_currency_money) / BigDecimal(from_currency_money)
    money = (decimal_money * from.cents * rate).round
    Money.new(money, to_currency)
  end

  def rate_key_for(from, to, opts)
    key = "#{from}_TO_#{to}"
    key << "_#{opts[:date].to_s}" if opts[:date]
    key.upcase
  end
end

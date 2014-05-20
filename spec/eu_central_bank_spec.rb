require File.expand_path(File.dirname(__FILE__) + '/spec_helper')
require 'yaml'

describe "EuCentralBank" do
  before(:each) do
    @bank = EuCentralBank.new
    @dir_path = File.dirname(__FILE__)
    @cache_path = File.expand_path(@dir_path + '/exchange_rates.xml')
    @history_cache_path = File.expand_path(@dir_path + '/exchange_rates_90_day.xml')
    @tmp_cache_path = File.expand_path(@dir_path + '/tmp/exchange_rates.xml')
    yml_cache_path = File.expand_path(@dir_path + '/exchange_rates.yml')
    @exchange_rates = YAML.load_file(yml_cache_path)
    @cache_value = nil
  end

  after(:each) do
    if File.exists? @tmp_cache_path
      File.delete @tmp_cache_path
    end
    @cache_value = nil
  end

  it "should save the xml file from ecb given a file path" do
    @bank.latest_cache = @tmp_cache_path
    @bank.save_rates
    File.exists?(@tmp_cache_path).should == true
  end

  describe 'using proc for cache' do
    it "should cache the rates" do
      @bank.latest_cache = proc do |val|
        if val.nil?
          @cache_value
        else
          @cache_value = val
        end
      end

      @bank.update_rates
      @cache_value.should_not be_nil
    end

    it "should restore the rates from the cache" do
      # Get the current rates
      @bank.latest_cache = proc do |val|
        if val.nil?
          @cache_value
        else
          @cache_value = val
        end
      end

      @bank.update_rates

      @bank.latest_cache.should_receive(:call).with(nil).exactly(2).times.and_return { @cache_value }
      @bank.update_rates
    end
  end

  describe "#get_rates" do
    context "when a ttl is provided" do
      context "as a proc" do
        before(:each) do
          @bank.ttl_in_seconds= proc { 3600 * 24 }
          @bank.update_rates
        end

        it "should update rates if is referred to future" do
          @bank.should_not_receive(:update_rates)
          @bank.get_rate(:eur, :usd)
        end

        it "should not update rates if is referred to present" do
          Timecop.freeze(@bank.rates_expiration + 10) do
            @bank.should_receive(:update_rates).with(false)
            @bank.get_rate(:eur, :usd)
          end
        end
      end

      context "as a value" do
        before(:each) do
          @bank.ttl_in_seconds= 3600 * 24
          @bank.update_rates
        end

        it "should update rates if is referred to future" do
          @bank.should_not_receive(:update_rates)
          @bank.get_rate(:eur, :usd)
        end

        it "should not update rates if is referred to present" do
          Timecop.freeze(@bank.rates_expiration + 10) do
            @bank.should_receive(:update_rates).with(false)
            @bank.get_rate(:eur, :usd)
          end
        end
      end
    end

    context "when a ttl isn't provided" do
      it "should never receive #update_rates" do
        @bank.should_not_receive(:update_rates)
        @bank.get_rate(:eur, :usd)
      end
    end

  end



  it "should save the xml file from ecb given a file path and url" do
    tmp_history_cache_path = File.expand_path(@dir_path + '/tmp/exchange_rates_90_day.xml')
    @bank.historical_cache = tmp_history_cache_path
    @bank.save_rates(EuCentralBank::ECB_90_DAY_URL)
    File.exists?(tmp_history_cache_path).should == true
  end


  it "should raise an error if an invalid path is given to save_rates" do
    lambda { @bank.save_rates }.should raise_exception
  end

  it "should update itself with exchange rates from ecb website" do
    OpenURI::OpenRead.stub(:open).with(EuCentralBank::ECB_RATES_URL)  { @cache_path }
    @bank.update_rates
    EuCentralBank::CURRENCIES.each do |currency|
      @bank.get_rate("EUR", currency).should > 0
    end
  end

  it "should update itself with exchange rates from ecb website when the data get from cache is illegal" do
    illegal_cache_path = File.expand_path(@dir_path + '/illegal_exchange_rates.xml')
    OpenURI::OpenRead.stub(:open).with(EuCentralBank::ECB_RATES_URL)  { @cache_path }
    @bank.update_rates(illegal_cache_path)
    EuCentralBank::CURRENCIES.each do |currency|
      @bank.get_rate("EUR", currency).should > 0
    end
  end

  it "should update itself with exchange rates from cache" do
    @bank.update_rates(@cache_path)
    EuCentralBank::CURRENCIES.each do |currency|
      @bank.get_rate("EUR", currency).should > 0
    end
  end

  it "should export to a string a valid cache that can be reread" do
    OpenURI::OpenRead.stub(:open).with(EuCentralBank::ECB_RATES_URL)  { @cache_path }
    s = @bank.save_rates_to_s
    @bank.update_rates_from_s(s)
    EuCentralBank::CURRENCIES.each do |currency|
      @bank.get_rate("EUR", currency).should > 0
    end
  end

  it 'should set last_updated when the rates are downloaded' do
    lu1 = @bank.last_updated
    @bank.update_rates(@cache_path)
    lu2 = @bank.last_updated
    @bank.update_rates(@cache_path)
    lu3 = @bank.last_updated

    lu1.should_not eq(lu2)
    lu2.should_not eq(lu3)
  end

  it 'should set rates_updated_at when the rates are downloaded' do
    lu1 = @bank.rates_updated_at
    @bank.update_rates(@cache_path)
    lu2 = @bank.rates_updated_at

    lu1.should_not eq(lu2)
  end

  it 'should set historical last_updated when the rates are downloaded' do
    @bank.historical_cache = @history_cache_path
    lu1 = @bank.historical_last_updated
    @bank.update_historical_rates
    lu2 = @bank.historical_last_updated
    @bank.update_historical_rates
    lu3 = @bank.historical_last_updated

    lu1.should_not eq(lu2)
    lu2.should_not eq(lu3)
  end

  it 'should set rates_updated_at when the rates are downloaded' do
    lu1 = @bank.historical_rates_updated_at
    @bank.update_historical_rates(@history_cache_path)
    lu2 = @bank.historical_rates_updated_at

    lu1.should_not eq(lu2)
  end

  it "should return the correct exchange rates using exchange" do
    @bank.latest_cache = @cache_path
    @bank.update_rates
    EuCentralBank::CURRENCIES.each do |currency|
      subunit_to_unit  = Money::Currency.wrap(currency).subunit_to_unit
      exchanged_amount = @bank.exchange(100, "EUR", currency)
      exchanged_amount.cents.should == (@exchange_rates["currencies"][currency] * subunit_to_unit).round(0).to_i
    end
  end

  it "should return the correct exchange rates using exchange_with" do
    @bank.latest_cache = @cache_path
    @bank.update_rates
    EuCentralBank::CURRENCIES.each do |currency|
      subunit_to_unit  = Money::Currency.wrap(currency).subunit_to_unit
      amount_from_rate = (@exchange_rates["currencies"][currency] * subunit_to_unit).round(0).to_i

      @bank.exchange_with(Money.new(100, "EUR"), currency).cents.should == amount_from_rate
    end
  end

  it "should return the correct exchange rates using historical exchange" do
    yml_path = File.expand_path(File.dirname(__FILE__) + '/historical_exchange_rates.yml')
    historical_exchange_rates = YAML.load_file(yml_path)
    @bank.historical_cache = @history_cache_path
    @bank.update_historical_rates

    EuCentralBank::CURRENCIES.each do |currency|
      subunit_to_unit  = Money::Currency.wrap(currency).subunit_to_unit
      exchanged_amount = @bank.exchange(100, "EUR", currency, "2014-05-06")
      exchanged_amount.cents.should == (historical_exchange_rates["currencies"][currency] * subunit_to_unit).round(0).to_i
    end
  end

  it "should update update_rates atomically", slow: true do
    even_rates = File.expand_path(File.dirname(__FILE__) + '/even_exchange_rates.xml')
    odd_rates = File.expand_path(File.dirname(__FILE__) + '/odd_exchange_rates.xml')

    odd_thread = Thread.new do
      while true
        @bank.latest_cache = odd_rates
        @bank.update_rates
      end
    end

    even_thread = Thread.new do
      while true
        @bank.latest_cache = even_rates
        @bank.update_rates(even_rates)
      end
    end

    # Updating bank rates so that we're sure the test won't fail prematurely
    # (i.e. even without odd_thread/even_thread getting a change to run)
    @bank.latest_cache = odd_rates
    @bank.update_rates

    10000.times do
      rates = YAML.load(@bank.export_rates(:yaml))
      rates.delete('EUR_TO_EUR')
      rates = rates.values.collect(&:to_i)
      rates.length.should eq(34)
      rates.should satisfy { |rates|
        rates.all?(&:even?) or rates.all?(&:odd?)
      }
    end
    even_thread.kill
    odd_thread.kill
  end

  it "should exchange money atomically", slow: true do
    # NOTE: We need to introduce an artificial delay in the core get_rate
    # function, otherwise it will take a lot of iterations to hit some sort or
    # 'race-condition'
    Money::Bank::VariableExchange.class_eval do
      alias_method :get_rate_original, :get_rate
      def get_rate(*args)
        sleep(Random.rand)
        get_rate_original(*args)
      end
    end
    even_rates = File.expand_path(File.dirname(__FILE__) + '/even_exchange_rates.xml')
    odd_rates = File.expand_path(File.dirname(__FILE__) + '/odd_exchange_rates.xml')

    odd_thread = Thread.new do
      while true; @bank.update_rates(odd_rates); end
    end

    even_thread = Thread.new do
      while true;  @bank.update_rates(even_rates); end
    end

    # Updating bank rates so that we're sure the test won't fail prematurely
    # (i.e. even without odd_thread/even_thread getting a change to run)
    @bank.update_rates(odd_rates)

    100.times do
      @bank.exchange(100, 'INR', 'INR').fractional.should eq(100)
    end
    even_thread.kill
    odd_thread.kill
  end
end

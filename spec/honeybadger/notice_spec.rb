require 'spec_helper'
require 'json'
require 'rack'

describe Honeybadger::Notice do
  def configure
    Honeybadger::Configuration.new.tap do |config|
      config.api_key = 'abc123def456'
    end
  end

  def build_notice(args = {})
    configuration = args.delete(:configuration) || configure
    Honeybadger::Notice.new(configuration.merge(args))
  end

  def stub_request(attrs = {})
    double('request', { :parameters  => { 'one' => 'two' },
                      :protocol    => 'http',
                      :host        => 'some.host',
                      :request_uri => '/some/uri',
                      :session     => { :to_hash => { 'a' => 'b' } },
                      :env         => { 'three' => 'four' } }.update(attrs))
  end

  context '#deliver' do
    context 'sender is configured' do
      it "delivers to sender" do
        sender = stub_sender!
        notice = build_notice
        notice.stub(:to_json => { :foo => 'bar' })

        sender.should_receive(:send_to_honeybadger).with(notice)
        notice.deliver
      end
    end

    context 'sender is not configured' do
      it "returns false" do
        notice = build_notice
        Honeybadger.sender = nil
        expect(notice.deliver).to be_false
      end
    end
  end

  it "generates json from as_json template" do
    notice = build_notice
    hash = {'foo' => 'bar'}
    notice.should_receive(:as_json).once.and_return(hash)
    json = notice.to_json

    payload = nil
    expect { payload = JSON.parse(json) }.not_to raise_error

    expect(payload).to eq hash
  end

  it "accepts a project root" do
    project_root = '/path/to/project'
    notice = build_notice(:project_root => project_root)
    expect(notice.project_root).to eq project_root
  end

  it "accepts a component" do
    expect(build_notice(:component => 'users_controller').controller).to eq 'users_controller'
  end

  it "aliases the component as controller" do
    expect(build_notice(:controller => 'users_controller').component).to eq 'users_controller'
    expect(build_notice(:controller => 'users_controller').controller).to eq 'users_controller'
  end

  it "accepts a action" do
    expect(build_notice(:action => 'index').action).to eq 'index'
  end

  it "accepts source excerpt radius" do
    expect(build_notice(:source_extract_radius => 3).source_extract_radius).to eq 3
  end

  it "accepts a url" do
    url = 'http://some.host/uri'
    notice = build_notice(:url => url)
    expect(notice.url).to eq url
  end

  it "sets the host name" do
    notice = build_notice
    expect(notice.hostname).to eq hostname
  end

  it "overrides the host name" do
    notice = build_notice({ :hostname => 'asdf' })
    expect(notice.hostname).to eq 'asdf'
  end

  context "custom fingerprint" do
    it "includes nil fingerprint when no fingerprint is specified" do
      notice = build_notice
      expect(notice.fingerprint).to be_nil
    end

    it "accepts fingerprint as string" do
      notice = build_notice({ :fingerprint => 'foo' })
      expect(notice.fingerprint).to eq '0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33'
    end

    it "accepts fingerprint responding to #call" do
      notice = build_notice({ :fingerprint => double(:call => 'foo') })
      expect(notice.fingerprint).to eq '0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33'
    end

    it "accepts fingerprint using #to_s" do
      notice = build_notice({ :fingerprint => double(:to_s => 'foo') })
      expect(notice.fingerprint).to eq '0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33'
    end
  end

  context "with a backtrace" do
    before(:each) do
      @source = <<-RUBY
        $:<<'lib'
        require 'honeybadger'

        begin
          raise StandardError
        rescue => e
          puts Honeybadger::Notice.new(exception: e).backtrace.to_json
        end
      RUBY

      @backtrace_array = ["my/file/backtrace:3",
                          "test/honeybadger/rack_test.rb:2:in `build_exception'",
                   "test/honeybadger/rack_test.rb:52:in `test_delivers_exception_from_rack'",
                   "foo/bar/baz.rb:28:in `run'"]

      @exception = build_exception
      @exception.set_backtrace(@backtrace_array)
    end

    it "passes its backtrace filters for parsing" do
      Honeybadger::Backtrace.should_receive(:parse).with(@backtrace_array, {:filters => 'foo'}).and_return(double(:lines => []))

      Honeybadger::Notice.new({:exception => @exception, :backtrace_filters => 'foo'})
    end

    it "passes its backtrace line filters for parsing" do
      @backtrace_array.each do |line|
        Honeybadger::Backtrace::Line.should_receive(:parse).with(line, {:filters => 'foo'})
      end

      Honeybadger::Notice.new({:exception => @exception, :backtrace_filters => 'foo'})
    end

    it "accepts a backtrace from an exception or hash" do
      backtrace = Honeybadger::Backtrace.parse(@backtrace_array)
      notice_from_exception = build_notice(:exception => @exception)

      expect(notice_from_exception.backtrace).to eq backtrace # backtrace was not correctly set from an exception

      notice_from_hash = build_notice(:backtrace => @backtrace_array)
      expect(notice_from_hash.backtrace).to eq backtrace # backtrace was not correctly set from a hash
    end

    context "without application trace" do
      before(:each) do
        Honeybadger.configuration.project_root = '/foo/bar'
        @string_io = StringIO.new(@source)
        File.stub(:exists?).with('my/file/backtrace').and_return true
        File.stub(:open).with('my/file/backtrace').and_yield @string_io
      end

      it "includes source extract from backtrace" do
        backtrace = Honeybadger::Backtrace.parse(@backtrace_array)
        notice_from_exception = build_notice(:exception => @exception)
        @string_io.rewind

        expect(notice_from_exception.source_extract).not_to be_empty # Expected backtrace source extract to be found
        expect(notice_from_exception.source_extract).to eq backtrace.lines.first.source
      end
    end

    context 'with an application trace' do
      before(:each) do
        Honeybadger.configuration.project_root = 'test/honeybadger/'

        @string_io = StringIO.new(@source)
        File.stub(:exists?).with('test/honeybadger/rack_test.rb').and_return true
        File.stub(:open).with('test/honeybadger/rack_test.rb').and_yield @string_io
      end

      it "includes source extract from first line of application trace" do
        backtrace = Honeybadger::Backtrace.parse(@backtrace_array)
        notice_from_exception = build_notice(:exception => @exception)
        @string_io.rewind

        expect(notice_from_exception.source_extract).not_to be_empty # Expected backtrace source extract to be found
        expect(notice_from_exception.source_extract).to eq backtrace.lines[1].source
      end
    end
  end

  it "Uses source extract from view when reporting an ActionView::Template::Error" do
    # TODO: I would like to stub out a real ActionView::Template::Error, but we're
    # currently locked at actionpack 2.3.8. Perhaps if one day we upgrade...
    source = <<-ERB
      1:   <%= current_user.name %>
      2: </div>
      3: 
      4: <div>
    ERB
    exception = build_exception
    exception.stub(:source_extract).and_return(source)
    notice = Honeybadger::Notice.new({:exception => exception})

    expect(notice.source_extract).to eq({ '1' => '  <%= current_user.name %>', '2' => '</div>', '3' => '', '4' => '<div>'})
  end

  it "sets the error class from an exception or hash" do
    assert_accepts_exception_attribute :error_class do |exception|
      exception.class.name
    end
  end

  it "sets the error message from an exception or hash" do
    assert_accepts_exception_attribute :error_message do |exception|
      "#{exception.class.name}: #{exception.message}"
    end
  end

  it "accepts parameters from a request or hash" do
    parameters = { 'one' => 'two' }
    notice_from_hash = build_notice(:parameters => parameters)
    expect(notice_from_hash.parameters).to eq parameters
  end

  it "accepts session data from a session[:data] hash" do
    data = { 'one' => 'two' }
    notice = build_notice(:session => { :data => data })
    expect(notice.session_data).to eq data
  end

  it "accepts session data from a session_data hash" do
    data = { 'one' => 'two' }
    notice = build_notice(:session_data => data)
    expect(notice.session_data).to eq data
  end

  it "accepts an environment name" do
    expect(build_notice(:environment_name => 'development').environment_name).to eq 'development'
  end

  it "accepts CGI data from a hash" do
    data = { 'string' => 'value' }
    notice = build_notice(:cgi_data => data)
    expect(notice.cgi_data).to eq data
  end

  it "accepts notifier information" do
    params = { :notifier_name    => 'a name for a notifier',
               :notifier_version => '1.0.5',
               :notifier_url     => 'http://notifiers.r.us/download' }
    notice = build_notice(params)
    expect(notice.notifier_name).to eq params[:notifier_name]
    expect(notice.notifier_version).to eq params[:notifier_version]
    expect(notice.notifier_url).to eq params[:notifier_url]
  end

  it "sets sensible defaults without an exception" do
    backtrace = Honeybadger::Backtrace.parse(build_backtrace_array)
    notice = build_notice(:backtrace => build_backtrace_array)

    expect(notice.error_message).to eq 'Notification'
    assert_array_starts_with backtrace.lines, notice.backtrace.lines
    expect(notice.parameters).to be_empty
    expect(notice.session_data).to be_empty
  end

  it "uses the caller as the backtrace for an exception without a backtrace" do
    filters = Honeybadger::Configuration.new.backtrace_filters
    backtrace = Honeybadger::Backtrace.parse(caller, :filters => filters)
    notice = build_notice(:exception => StandardError.new('error'), :backtrace => nil)

    assert_array_starts_with backtrace.lines, notice.backtrace.lines
  end

  it "converts unserializable objects to strings" do
    assert_serializes_hash(:parameters)
    assert_serializes_hash(:cgi_data)
    assert_serializes_hash(:session_data)
  end

  it "filters parameters" do
    assert_filters_hash(:parameters)
  end

  it "filters cgi data" do
    assert_filters_hash(:cgi_data)
  end

  it "filters session" do
    assert_filters_hash(:session_data)
  end

  describe 'url' do
    let(:params_filters) { [] }
    let(:notice) { build_notice(:params_filters => params_filters, :url => url) }

    context 'filtered params in query' do
      let(:params_filters) { [:bar] }
      let(:url) { 'https://www.honeybadger.io/?foo=1&bar=2&baz=3' }

      it 'filters query' do
        expect(notice.url).to eq 'https://www.honeybadger.io/?foo=1&bar=[FILTERED]&baz=3'
      end
    end

    context 'malformed query' do
      let(:url) { 'https://www.honeybadger.io/?foobar12' }

      it 'maintains query' do
        expect(notice.url).to eq url
      end
    end

    context 'no query' do
      let(:url) { 'https://www.honeybadger.io' }

      it 'keeps original URL' do
        expect(notice.url).to eq url
      end
    end

    context 'malformed url' do
      let(:url) { 'http s ! honeybadger' }

      before do
        expect { URI.parse(url) }.to raise_error
      end

      it 'keeps original URL' do
        expect(notice.url).to eq url
      end
    end

    context 'complex url' do
      let(:url) { 'https://foo:bar@www.honeybadger.io:123/asdf/?foo=1&bar=2&baz=3' }

      it 'keeps original URL' do
        expect(notice.url).to eq url
      end
    end
  end

  it "removes rack.request.form_vars" do
    original = {
      "rack.request.form_vars" => "story%5Btitle%5D=The+TODO+label",
      "abc" => "123"
    }

    notice = build_notice(:cgi_data => original)
    expect(notice.cgi_data).to eq({"abc" => "123"})
  end

  it "does not send empty request data" do
    notice = build_notice
    notice.url.should be_nil
    notice.controller.should be_nil
    notice.action.should be_nil

    json = notice.to_json
    payload = JSON.parse(json)
    payload['request']['url'].should be_nil
    payload['request']['component'].should be_nil
    payload['request']['action'].should be_nil
    payload['request']['user'].should be_nil
  end

  %w(url controller action).each do |var|
    it "sends a request if #{var} is present" do
      notice = build_notice(var.to_sym => 'value')
      json = notice.to_json
      payload = JSON.parse(json)
      payload['request'].should_not be_nil
    end
  end

  %w(parameters cgi_data session_data context).each do |var|
    it "sends a request if #{var} is present" do
      notice = build_notice(var.to_sym => { 'key' => 'value' })
      json = notice.to_json
      payload = JSON.parse(json)
      payload['request'].should_not be_nil
    end
  end

  it "does not ignore an exception not matching ignore filters" do
    notice = build_notice(:error_class       => 'ArgumentError',
                          :ignore            => ['Argument'],
                          :ignore_by_filters => [lambda { |n| false }])
    expect(notice.ignore?).to be_false
  end

  it "ignores an exception with a matching error class" do
    notice = build_notice(:error_class => 'ArgumentError',
                          :ignore      => [ArgumentError])
    expect(notice.ignore?).to be_true
  end

  it "ignores an exception with an equal error class name" do
    notice = build_notice(:error_class => 'ArgumentError',
                          :ignore      => ['ArgumentError'])
    expect(notice.ignore?).to be_true # Expected ArgumentError to ignore ArgumentError
  end

  it "ignores an exception matching error class name" do
    notice = build_notice(:error_class => 'ArgumentError',
                          :ignore      => [/Error$/])
    expect(notice.ignore?).to be_true # Expected /Error$/ to ignore ArgumentError
  end

  it "ignores an exception that inherits from ignored error class" do
    class ::FooError < ArgumentError ; end
    notice = build_notice(:exception => FooError.new('Oh noes!'),
                          :ignore      => [ArgumentError])
    expect(notice.ignore?).to be_true # Expected ArgumentError to ignore FooError
  end

  it "ignores an exception with a matching filter" do
    filter = lambda {|notice| notice.error_class == 'ArgumentError' }
    notice = build_notice(:error_class       => 'ArgumentError',
                          :ignore_by_filters => [filter])
    expect(notice.ignore?).to be_true
  end

  it "does not raise without an ignore list" do
    notice = build_notice(:ignore => nil, :ignore_by_filters => nil)
    expect { notice.ignore? }.not_to raise_error
  end

  ignored_error_classes = %w(
    ActiveRecord::RecordNotFound
    AbstractController::ActionNotFound
    ActionController::RoutingError
    ActionController::InvalidAuthenticityToken
    CGI::Session::CookieStore::TamperedWithCookie
    ActionController::UnknownAction
  )

  ignored_error_classes.each do |ignored_error_class|
    it "ignores #{ignored_error_class} error by default" do
      notice = build_notice(:error_class => ignored_error_class)
      expect(notice.ignore?).to be_true
    end
  end

  it "acts like a hash" do
    notice = build_notice(:error_message => 'some message')
    expect(notice[:error_message]).to eq notice.error_message
  end

  it "returns params on notice[:request][:params]" do
    params = { 'one' => 'two' }
    notice = build_notice(:parameters => params)
    expect(notice[:request][:params]).to eq params
  end

  it "returns context on notice[:request][:context]" do
    context = { 'one' => 'two' }
    notice = build_notice(:context => context)
    expect(notice[:request][:context]).to eq context
  end

  it "merges context from args with context from Honeybadger#context" do
    Honeybadger.context({ 'one' => 'two', 'foo' => 'bar' })
    notice = build_notice(:context => { 'three' => 'four', 'foo' => 'baz' })
    expect(notice[:request][:context]).to eq({ 'one' => 'two', 'three' => 'four', 'foo' => 'baz' })
  end

  it "returns nil context when context is not set" do
    notice = build_notice
    notice[:request][:context].should be_nil
  end

  it "allows falsey values in context" do
    Honeybadger.context({ :debuga => true, :debugb => false })
    notice = build_notice
    hash = JSON.parse(notice.to_json)
    expect(hash['request']['context']).to eq({ 'debuga' => true, 'debugb' => false })
  end

  it "ensures #to_hash is called on objects that support it" do
    expect { build_notice(:session => { :object => double(:to_hash => {}) }) }.not_to raise_error
  end

  it "ensures #to_ary is called on objects that support it" do
    expect { build_notice(:session => { :object => double(:to_ary => {}) }) }.not_to raise_error
  end

  it "extracts data from a rack environment hash" do
    url = "https://subdomain.happylane.com:100/test/file.rb?var=value&var2=value2"
    parameters = { 'var' => 'value', 'var2' => 'value2' }
    env = Rack::MockRequest.env_for(url)

    notice = build_notice(:rack_env => env)

    expect(notice.url).to eq url
    expect(notice.parameters).to eq parameters
    expect(notice.cgi_data['REQUEST_METHOD']).to eq 'GET'
  end

  it "extracts data from a rack environment hash with action_dispatch info" do
    params = { 'controller' => 'users', 'action' => 'index', 'id' => '7' }
    env = Rack::MockRequest.env_for('/', { 'action_dispatch.request.parameters' => params })

    notice = build_notice(:rack_env => env)

    expect(notice.parameters).to eq params
    expect(notice.component).to eq params['controller']
    expect(notice.action).to eq params['action']
  end

  it "extracts session data from a rack environment" do
    session_data = { 'something' => 'some value' }
    env = Rack::MockRequest.env_for('/', 'rack.session' => session_data)

    notice = build_notice(:rack_env => env)

    expect(notice.session_data).to eq session_data
  end

  it "prefers passed session data to rack session data" do
    session_data = { 'something' => 'some value' }
    env = Rack::MockRequest.env_for('/')

    notice = build_notice(:rack_env => env, :session_data => session_data)

    expect(notice.session_data).to eq session_data
  end

  unless Gem::Version.new(Rack.release) < Gem::Version.new('1.2')
    it "fails gracefully when Rack params cannot be parsed" do
      rack_env = Rack::MockRequest.env_for('http://www.example.com/explode', :method => 'POST', :input => 'foo=bar&bar=baz%')
      notice = Honeybadger::Notice.new(:rack_env => rack_env)
      expect(notice.params.size).to eq 1
      expect(notice.params[:error]).to match(/Failed to call params on Rack::Request/)
    end
  end

  it "does not send session data when send_request_session is false" do
    notice = build_notice(:send_request_session => false, :session_data => { :foo => :bar })
    notice.session_data.should be_nil
  end

  it "does not allow infinite recursion" do
    hash = {:a => :a}
    hash[:hash] = hash
    notice = Honeybadger::Notice.new(:parameters => hash)
    expect(notice.parameters[:hash]).to eq "[possible infinite recursion halted]"
  end

  it "trims error message to 1k" do
    message = 'asdfghjkl'*200
    e = StandardError.new(message)
    notice = Honeybadger::Notice.new(:exception => e)
    message.bytesize.should > 1024
    expect(notice.error_message.bytesize).to eq 1024
  end

  it "prefers notice args to exception attributes" do
    e = RuntimeError.new('Not very helpful')
    notice = Honeybadger::Notice.new(:exception => e, :error_class => 'MyClass', :error_message => 'Something very specific went wrong.')
    expect(notice.error_class).to eq 'MyClass'
    expect(notice.error_message).to eq 'Something very specific went wrong.'
  end

  context "notice_post_build" do

    it "does not change the notice if a notice_post_build Proc is not given" do
      e = StandardError.new('error')
      notice = Honeybadger::Notice.new(:exception => e)

      expect(notice.to_json).to eq notice.to_json
    end

    it "transforms the notice if a notice_post_build Proc is given" do
      configuration = Honeybadger::Configuration.new.tap do |config|
        config.notice_post_build = Proc.new do |notice|
          if notice.error_class == 'StandardError'
            notice.send(:error_message=, '')
          end
        end
      end
      e = StandardError.new('error')
      notice = Honeybadger::Notice.new(configuration.merge(:exception => e))
      expect(notice.error_message).to eq ''
    end
  end

  def assert_accepts_exception_attribute(attribute, args = {}, &block)
    exception = build_exception
    block ||= lambda { exception.send(attribute) }
    value = block.call(exception)

    notice_from_exception = build_notice(args.merge(:exception => exception))

    expect(notice_from_exception.send(attribute)).to eq value

    notice_from_hash = build_notice(args.merge(attribute => value))
    expect(notice_from_hash.send(attribute)).to eq value
  end

  def assert_serializes_hash(attribute)
    [File.open(__FILE__), Proc.new { puts "boo!" }, Module.new].each do |object|
      hash = {
        :strange_object => object,
        :sub_hash => {
          :sub_object => object
        },
        :array => [object]
      }
      notice = build_notice(attribute => hash)
      hash = notice.send(attribute)
      expect(object.to_s).to eq hash[:strange_object] # objects should be serialized

      expect(hash[:sub_hash]).to be_a Hash # subhashes should be kept
      expect(object.to_s).to eq hash[:sub_hash][:sub_object] # subhash members should be serialized
      expect(hash[:array]).to be_a Array # arrays should be kept
      expect(object.to_s).to eq hash[:array].first # array members should be serialized
    end
  end

  def assert_filters_hash(attribute)
    filters  = ["abc", :def, /private/, /^foo_.*$/]
    original = { 'abc' => "123", 'def' => "456", 'ghi' => "789", 'nested' => { 'abc' => '100' },
      'something_with_abc' => 'match the entire string', 'private_param' => 'prra',
      'foo_param' => 'bar', 'not_foo_param' => 'baz', 'nested_foo' => { 'foo_nested' => 'bla'} }
    filtered = { 'abc'    => "[FILTERED]",
                 'def'    => "[FILTERED]",
                 'something_with_abc' => "match the entire string",
                 'ghi'    => "789",
                 'nested' => { 'abc' => '[FILTERED]' },
                 'private_param' => '[FILTERED]',
                 'foo_param' => '[FILTERED]',
                 'not_foo_param' => 'baz',
                 'nested_foo' => { 'foo_nested' => '[FILTERED]'}
    }

    notice = build_notice(:params_filters => filters, attribute => original)

    expect(notice.send(attribute)).to eq filtered
  end

  def build_backtrace_array
    ["app/models/user.rb:13:in `magic'",
      "app/controllers/users_controller.rb:8:in `index'"]
  end

  def hostname
    `hostname`.chomp
  end
end

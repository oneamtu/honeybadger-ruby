require 'honeybadger'
require 'honeybadger/monitor'
require 'rails'

module Honeybadger
  class Railtie < Rails::Railtie
    rake_tasks do
      require 'honeybadger/rake_handler'
      require "honeybadger/rails3_tasks"
    end

    initializer "honeybadger.use_rack_middleware" do |app|
      app.config.middleware.insert 0, "Honeybadger::Rack"
    end

    config.after_initialize do
      Honeybadger.configure(true) do |config|
        config.logger           ||= ::Rails.logger
        config.environment_name ||= ::Rails.env
        config.project_root     ||= ::Rails.root
        config.framework        = "Rails: #{::Rails::VERSION::STRING}"
      end

      ActiveSupport.on_load(:action_controller) do
        # Lazily load action_controller methods
        #
        require 'honeybadger/rails/controller_methods'

        include Honeybadger::Rails::ControllerMethods
      end

      if defined?(::ActionDispatch::DebugExceptions)
        # We should catch the exceptions in ActionDispatch::DebugExceptions in Rails 3.2.x.
        #
        require 'honeybadger/rails/middleware/exceptions_catcher'
        ::ActionDispatch::DebugExceptions.send(:include,Honeybadger::Rails::Middleware::ExceptionsCatcher)
      elsif defined?(::ActionDispatch::ShowExceptions)
        # ActionDispatch::DebugExceptions is not defined in Rails 3.0.x and 3.1.x so
        # catch the exceptions in ShowExceptions.
        #
        require 'honeybadger/rails/middleware/exceptions_catcher'
        ::ActionDispatch::ShowExceptions.send(:include,Honeybadger::Rails::Middleware::ExceptionsCatcher)
      end

      if Honeybadger.configuration.public?
        if result = Honeybadger.sender.ping({ :version => Honeybadger::VERSION, :framework => Honeybadger.configuration.framework, :environment => Honeybadger.configuration.environment_name, :hostname => Honeybadger.configuration.hostname })
          Honeybadger.configure(true) do |config|
            config.features = result['features'] if result['features']
          end
        end
      end
    end
  end
end

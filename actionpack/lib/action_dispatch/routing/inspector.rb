# frozen_string_literal: true

require "delegate"
require "io/console/size"

module ActionDispatch
  module Routing
    class RouteWrapper < SimpleDelegator
      def endpoint
        app.dispatcher? ? "#{controller}##{action}" : rack_app.inspect
      end

      def constraints
        requirements.except(:controller, :action)
      end

      def rack_app
        app.rack_app
      end

      def path
        super.spec.to_s
      end

      def name
        super.to_s
      end

      def reqs
        @reqs ||= begin
          reqs = endpoint
          reqs += " #{constraints}" unless constraints.empty?
          reqs
        end
      end

      def controller
        parts.include?(:controller) ? ":controller" : requirements[:controller]
      end

      def action
        parts.include?(:action) ? ":action" : requirements[:action]
      end

      def internal?
        internal
      end

      def engine?
        app.engine?
      end
    end

    ##
    # This class is just used for displaying route information when someone
    # executes `rails routes` or looks at the RoutingError page.
    # People should not use this class.
    class RoutesInspector # :nodoc:
      def initialize(routes)
        @engines = {}
        @routes = routes
      end

      def format(formatter, filter = {})
        routes_to_display = filter_routes(normalize_filter(filter))
        columns_to_display = filter_columns(filter) || nil
        routes = collect_routes(routes_to_display)
        if routes.none?
          formatter.no_routes(collect_routes(@routes), filter)
          return formatter.result
        end

        formatter.header routes, columns_to_display
        formatter.section routes, columns_to_display

        @engines.each do |name, engine_routes|
          formatter.section_title "Routes for #{name}"
          formatter.section engine_routes
        end

        formatter.result
      end

      private
        def normalize_filter(filter)
          if filter[:controller]
            { controller: /#{filter[:controller].underscore.sub(/_?controller\z/, "")}/ }
          elsif filter[:grep]
            { controller: /#{filter[:grep]}/, action: /#{filter[:grep]}/,
              verb: /#{filter[:grep]}/, name: /#{filter[:grep]}/, path: /#{filter[:grep]}/ }
          end
        end

        def filter_columns(filter)
          if filter[:columns]
            filter[:columns].split(",").map(&:to_sym)
          end
        end

        def filter_routes(filter)
          if filter
            @routes.select do |route|
              route_wrapper = RouteWrapper.new(route)
              filter.any? { |default, value| value.match?(route_wrapper.send(default)) }
            end
          else
            @routes
          end
        end

        def collect_routes(routes)
          routes.collect do |route|
            RouteWrapper.new(route)
          end.reject(&:internal?).collect do |route|
            collect_engine_routes(route)

            { name: route.name,
              verb: route.verb,
              path: route.path,
              reqs: route.reqs }
          end
        end

        def collect_engine_routes(route)
          name = route.endpoint
          return unless route.engine?
          return if @engines[name]

          routes = route.rack_app.routes
          if routes.is_a?(ActionDispatch::Routing::RouteSet)
            @engines[name] = collect_routes(routes.routes)
          end
        end
    end

    module ConsoleFormatter
      class Base
        def initialize
          @buffer = []
        end

        def result
          @buffer.join("\n")
        end

        def section_title(title)
        end

        def section(routes, columns_to_display=nil)
        end

        def header(routes, columns_to_display=nil)
        end

        def no_routes(routes, filter)
          @buffer <<
            if routes.none?
              <<~MESSAGE
                You don't have any routes defined!

                Please add some routes in config/routes.rb.
              MESSAGE
            elsif filter.key?(:controller)
              "No routes were found for this controller."
            elsif filter.key?(:grep)
              "No routes were found for this grep pattern."
            end

          @buffer << "For more information about routes, see the Rails guide: https://guides.rubyonrails.org/routing.html."
        end
      end

      class Sheet < Base
        def section_title(title)
          @buffer << "\n#{title}:"
        end

        def section(routes, columns_to_display = nil)
          @buffer << draw_section(routes, columns_to_display)
        end

        def header(routes, columns_to_display = nil)
          @buffer << draw_header(routes, columns_to_display)
        end

        private
          def draw_section(routes, columns_to_display =  nil)
            header_lengths = ["Prefix", "Verb", "URI Pattern", "Controller#Action"].map(&:length)
            name_width, verb_width, path_width, reqs_width = widths(routes).zip(header_lengths).map(&:max)

            routes.map do |r|
              draw_section_row(r, columns_to_display, name_width, verb_width, path_width, reqs_width)
            end
          end

          def draw_section_row(r, columns_to_display = nil, name_width, verb_width, path_width, reqs_width)
            # if filter is not there everything should work normally
            row = ""
            row += "#{r[:name].rjust(name_width)} " unless (columns_to_display && !(columns_to_display.include? :name))
            row += "#{r[:verb].ljust(verb_width)} " unless (columns_to_display && !(columns_to_display.include? :verb))
            row += "#{r[:path].ljust(path_width)} " unless (columns_to_display && !(columns_to_display.include? :path))
            row += "#{r[:reqs]}" unless (columns_to_display && !(columns_to_display.include? :reqs))
            row
          end

          def filter_headers
            header_label_map = {
              name: "Prefix",
              verb: "Verb",
              path: "URI Pattern",
              reqs: "Controller#Action"
            }
            header_label_map.values
          end

          def draw_header(routes, columns_to_display)
            header_lengths = ["Prefix", "Verb", "URI Pattern", "Controller#Action"].map(&:length)
            name_width, verb_width, path_width, reqs_width = widths(routes).zip(header_lengths).map(&:max)
            header = ""
            header += "#{"Prefix".rjust(name_width)} " unless (columns_to_display && !(columns_to_display.include? :name))
            header += "#{"Verb".ljust(verb_width)} " unless (columns_to_display && !(columns_to_display.include? :verb))
            header += "#{"URI Pattern".ljust(path_width)} " unless (columns_to_display && !(columns_to_display.include? :path))
            header += "#{"Controller#Action"}" unless (columns_to_display && !(columns_to_display.include? :reqs))
            header
          end

          def widths(routes)
            [routes.map { |r| r[:name].length }.max || 0,
             routes.map { |r| r[:verb].length }.max || 0,
             routes.map { |r| r[:path].length }.max || 0,
             routes.map { |r| r[:reqs].length }.max || 0]
          end
      end

      class Expanded < Base
        def initialize(width: IO.console_size.second)
          @width = width
          super()
        end

        def section_title(title)
          @buffer << "\n#{"[ #{title} ]"}"
        end

        def section(routes, columns_to_display = nil)
          @buffer << draw_expanded_section(routes, columns_to_display)
        end

        private
          def draw_expanded_section(routes, columns_to_display)
            routes.map.each_with_index do |r, i|
              <<~MESSAGE.chomp
                #{route_header(index: i + 1)}
                Prefix            | #{r[:name]}
                Verb              | #{r[:verb]}
                URI               | #{r[:path]}
                Controller#Action | #{r[:reqs]}
              MESSAGE
            end
          end

          def route_header(index:)
            "--[ Route #{index} ]".ljust(@width, "-")
          end
      end
    end

    class HtmlTableFormatter
      def initialize(view)
        @view = view
        @buffer = []
      end

      def section_title(title)
        @buffer << %(<tr><th colspan="4">#{title}</th></tr>)
      end

      def section(routes, columns_to_display)
        @buffer << @view.render(partial: "routes/route", collection: routes)
      end

      # The header is part of the HTML page, so we don't construct it here.
      def header(routes, columns_to_display)
      end

      def no_routes(*)
        @buffer << <<~MESSAGE
          <p>You don't have any routes defined!</p>
          <ul>
            <li>Please add some routes in <tt>config/routes.rb</tt>.</li>
            <li>
              For more information about routes, please see the Rails guide
              <a href="https://guides.rubyonrails.org/routing.html">Rails Routing from the Outside In</a>.
            </li>
          </ul>
        MESSAGE
      end

      def result
        @view.raw @view.render(layout: "routes/table") {
          @view.raw @buffer.join("\n")
        }
      end
    end
  end
end

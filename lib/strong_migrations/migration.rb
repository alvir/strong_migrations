module StrongMigrations
  module Migration
    def safety_assured
      previous_value = @safe
      @safe = true
      yield
    ensure
      @safe = previous_value
    end

    def migrate(direction)
      @direction = direction
      super
    end

    def method_missing(method, *args, &block)
      unless @safe || ENV["SAFETY_ASSURED"] || is_a?(ActiveRecord::Schema) || @direction == :down || version_safe?
        ar5 = ActiveRecord::VERSION::MAJOR >= 5

        case method
        when :remove_column, :remove_timestamps
          base_model = ar5 ? "ApplicationRecord" : "ActiveRecord::Base"
          columns = method == :remove_timestamps ? ["created_at", "updated_at"] : [args[1].to_s]
          code = ar5 ? "self.ignored_columns = #{columns.inspect}" : "def self.columns\n    super.reject { |c| #{columns.inspect}.include?(c.name) }\n  end"
          raise_error :remove_column, model: args[0].to_s.classify, base_model: base_model, code: code
        when :change_table
          raise_error :change_table
        when :rename_table
          raise_error :rename_table
        when :rename_column
          raise_error :rename_column
        when :add_index
          columns = args[1]
          options = args[2] || {}
          if columns.is_a?(Array) && columns.size > 3 && !options[:unique]
            raise_error :add_index_columns
          end
          if postgresql? && options[:algorithm] != :concurrently && !@new_tables.to_a.include?(args[0].to_s)
            raise_error :add_index, {
              table: sym_str(args[0]),
              column: column_str(columns),
              options: options_str(options.except(:algorithm)),
              migration_name: self.class.name,
              migration_suffix: ar5 ? "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]" : ""
            }
          end
        when :add_column
          type = args[2]
          options = args[3] || {}
          default = options[:default]

          if !default.nil? && !(postgresql? && postgresql_version >= 110000)
            model = args[0].to_s.classify
            code = ar5 ? "#{model}.in_batches.update_all #{args[1]}: #{default.inspect}" : "#{model}.find_in_batches do |records|\n      #{model}.where(id: records.map(&:id)).update_all #{args[1]}: #{default.inspect}\n    end"
            raise_error :add_column_default, {
              table: sym_str(args[0]),
              column: sym_str(args[1]),
              type: sym_str(type),
              options: options_str(options.except(:default)),
              default: default.inspect,
              migration_name: self.class.name,
              migration_suffix: ar5 ? "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]" : "",
              code: code
            }
          end

          if type.to_s == "json" && postgresql?
            if postgresql_version >= 90400
              raise_error :add_column_json
            else
              base_model = ar5 ? "ApplicationRecord" : "ActiveRecord::Base"
              raise_error :add_column_json_legacy, {
                model: args[0].to_s.classify,
                table: connection.quote_table_name(args[0]),
                base_model: base_model
              }
            end
          end
        when :change_column
          safe = false
          # assume Postgres 9.1+ since previous versions are EOL
          if postgresql? && args[2].to_s == "text"
            column = connection.columns(args[0]).find { |c| c.name.to_s == args[1].to_s }
            safe = column && column.type == :string
          end
          raise_error :change_column unless safe
        when :create_table
          options = args[1] || {}
          raise_error :create_table if options[:force]
          (@new_tables ||= []) << args[0].to_s
        when :add_reference, :add_belongs_to
          options = args[2] || {}
          index_value = options.fetch(:index, ActiveRecord::VERSION::MAJOR >= 5 ? true : false)
          if postgresql? && index_value
            reference = args[1]
            columns = []
            columns << "#{reference}_type" if options[:polymorphic]
            columns << "#{reference}_id"
            raise_error :add_reference, {
              command: method,
              table: sym_str(args[0]),
              reference: sym_str(reference),
              column: column_str(columns),
              options: options_str(options.except(:index)),
              migration_name: self.class.name,
              migration_suffix: ar5 ? "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]" : ""
            }
          end
        when :execute
          raise_error :execute
        when :change_column_null
          null = args[2]
          default = args[3]
          if !null && !default.nil?
            model = args[0].to_s.classify
            code = ar5 ? "#{model}.in_batches.update_all #{args[1]}: #{default.inspect}" : "#{model}.find_in_batches do |records|\n      #{model}.where(id: records.map(&:id)).update_all #{args[1]}: #{default.inspect}\n    end"
            raise_error :change_column_null, {
              migration_name: self.class.name,
              migration_suffix: ar5 ? "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]" : "",
              code: code
            }
          end
        end

        StrongMigrations.checks.each do |check|
          instance_exec(method, args, &check)
        end
      end

      result = super

      if StrongMigrations.auto_analyze && @direction == :up && postgresql? && method == :add_index
        connection.execute "ANALYZE VERBOSE #{connection.quote_table_name(args[0])}"
      end

      result
    end

    private

    def postgresql?
      %w(PostgreSQL PostGIS).include?(connection.adapter_name)
    end

    def postgresql_version
      @postgresql_version ||= connection.execute("SHOW server_version_num").first["server_version_num"].to_i
    end

    def version_safe?
      version && version <= StrongMigrations.start_after
    end

    def raise_error(message_key, vars = {})
      message = StrongMigrations.error_messages[message_key] || "Missing message"
      # escape % not followed by {
      stop!(message.gsub(/%(?!{)/, "%%") % vars, dangerous: true)
    end

    def sym_str(v)
      v.to_sym.inspect
    end

    def column_str(columns)
      columns = Array(columns).map(&:to_sym)
      columns = columns.first if columns.size == 1
      columns.inspect
    end

    def options_str(options)
      str = String.new("")
      options.each do |k, v|
        str << ", #{k}: #{v.inspect}"
      end
      str
    end

    def stop!(message, dangerous: false)
      header = dangerous ? "Dangerous operation detected!" : "Custom check"
      raise StrongMigrations::UnsafeMigration, "\n=== #{header} #strong_migrations ===\n\n#{message}\n"
    end
  end
end

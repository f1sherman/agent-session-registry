# frozen_string_literal: true

module AgentSessionRegistry
  class Record
    FIELDS = %i[
      source hostname session_id remote status name cwd adapter adapter_config
      created_at updated_at
    ].freeze

    attr_reader(*FIELDS)

    def initialize(**attributes)
      FIELDS.each do |field|
        instance_variable_set("@#{field}", attributes.fetch(field))
      end
    end

    def to_h
      FIELDS.to_h { |field| [field, public_send(field)] }
    end
  end
end

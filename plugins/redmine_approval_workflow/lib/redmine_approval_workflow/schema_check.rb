# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Has the code been deployed without its migrations?
  #
  # Copying the plugin directory and forgetting `redmine:plugins:migrate` leaves
  # the code asking for columns the database does not have. What that looked
  # like in practice was a 500 on the project settings tab and a chain panel
  # that silently stopped appearing -- a puzzle, when the cause is one command.
  # So the places that would break say so instead.
  #
  # This asks the schema directly rather than comparing migration numbers.
  # Redmine records a plugin migration as "<n>-<plugin_id>" in schema_migrations,
  # and `rake redmine:plugins:migrate` ends by dumping db/schema.rb -- which
  # carries no plugin rows, so the next time that schema is loaded the
  # bookkeeping is wiped while every column survives. Counting versions would
  # then cry "pending" on a perfectly good install, which is worse than the
  # problem it is meant to catch.
  module SchemaCheck
    # The columns this version of the code reads. SchemaCheckTest asserts every
    # one of them exists in a migrated database, so a typo here fails the suite
    # rather than hiding the settings tab in production.
    REQUIRED_COLUMNS = {
      'approval_routes'          => %w[kind],
      'approval_route_trackers'  => %w[approval_route_id tracker_id],
      'approval_route_steps'     => %w[approval_mode assign_signer assign_author],
      'approval_route_approvers' => %w[approval_route_step_id position approver_dynamic],
      'approval_signatures'      => %w[derived issue_extension_id approval_route_approver_id],
      'issue_extensions'         => %w[status approval_route_id decided_at]
    }.freeze

    module_function

    # ["approval_route_steps: assign_signer", ...] -- empty when up to date.
    def missing
      connection = ActiveRecord::Base.connection
      REQUIRED_COLUMNS.filter_map do |table, columns|
        next "#{table}: *" unless connection.table_exists?(table)

        absent = columns - connection.columns(table).map(&:name)
        "#{table}: #{absent.join(', ')}" if absent.any?
      end
    rescue StandardError => e
      # Never let the check itself be the thing that breaks a page.
      Rails.logger.error("[redmine_approval_workflow] schema check failed: #{e.class}: #{e.message}")
      []
    end

    def pending?
      missing.any?
    end
  end
end

# frozen_string_literal: true

class AddExtensionApproval < ActiveRecord::Migration[8.1]
  def up
    # A route now governs either the issue's status chain or extension requests.
    add_column :approval_routes, :kind, :string, :null => false, :default => 'issue'
    add_index :approval_routes, [:kind, :tracker_id, :project_id],
              :name => 'index_approval_routes_on_kind_and_scope'

    # An extension step names its approver instead of moving the issue into a
    # status, so the status is no longer universally required.
    change_column_null :approval_route_steps, :issue_status_id, true

    # A request now has a life before it takes effect.
    add_column :issue_extensions, :status, :string, :null => false, :default => 'approved'
    add_column :issue_extensions, :approval_route_id, :integer
    add_column :issue_extensions, :decided_at, :datetime
    add_index :issue_extensions, [:issue_id, :status]

    # Rows that predate this migration were applied the moment they were made,
    # which is exactly what 'approved' means.
    execute "UPDATE issue_extensions SET status = 'approved'"

    # A signature belongs either to an issue's chain or to one extension request.
    add_column :approval_signatures, :issue_extension_id, :integer
    add_index :approval_signatures, :issue_extension_id
  end

  def down
    remove_column :approval_signatures, :issue_extension_id
    remove_column :issue_extensions, :decided_at
    remove_column :issue_extensions, :approval_route_id
    remove_column :issue_extensions, :status
    change_column_null :approval_route_steps, :issue_status_id, false
    remove_index :approval_routes, :name => 'index_approval_routes_on_kind_and_scope'
    remove_column :approval_routes, :kind
  end
end

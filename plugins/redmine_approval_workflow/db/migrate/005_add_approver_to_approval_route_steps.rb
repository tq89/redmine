# frozen_string_literal: true

class AddApproverToApprovalRouteSteps < ActiveRecord::Migration[8.1]
  def change
    # Who may sign this step, on top of the workflow transition it performs.
    # Both null means "anybody the workflow allows".
    add_column :approval_route_steps, :approver_role_id, :integer
    add_column :approval_route_steps, :approver_user_id, :integer
    # Wording of the action button, e.g. "Trình ký" or "Phê duyệt".
    add_column :approval_route_steps, :button_label, :string
  end
end

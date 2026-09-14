# frozen_string_literal: true

# A step can now be assigned to whoever the issue happens to be assigned to,
# rather than to a fixed role or a fixed person. Stored as a string so further
# kinds of dynamic approver do not each need a column.
class AddDynamicApproverToSteps < ActiveRecord::Migration[8.1]
  def up
    add_column :approval_route_steps, :approver_dynamic, :string
  end

  def down
    remove_column :approval_route_steps, :approver_dynamic
  end
end

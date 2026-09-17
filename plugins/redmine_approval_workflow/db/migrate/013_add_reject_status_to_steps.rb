# frozen_string_literal: true

# Where a refusal sends the issue, decided per step.
#
# Until now the answer came from the route alone: back to the previous step's
# status, or to the route's single "rejected status" at the head of the chain.
# A route with no rejected status configured therefore had no reject target at
# the first two positions at all -- and no target means no reject button, which
# is how the button went missing without anything looking broken.
class AddRejectStatusToSteps < ActiveRecord::Migration[8.1]
  def up
    # 'previous' is what every existing step already does, so nothing changes
    # for a chain that was working before this.
    add_column :approval_route_steps, :reject_mode, :string,
               :null => false, :default => 'previous'
    add_column :approval_route_steps, :reject_status_id, :integer
    add_index :approval_route_steps, :reject_status_id
  end

  def down
    remove_index :approval_route_steps, :reject_status_id
    remove_column :approval_route_steps, :reject_status_id
    remove_column :approval_route_steps, :reject_mode
  end
end

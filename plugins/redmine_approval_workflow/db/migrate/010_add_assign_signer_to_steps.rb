# frozen_string_literal: true

# "Nhận việc": a step that hands the issue to whoever signs it. Off by default,
# so every existing step keeps behaving exactly as it did.
class AddAssignSignerToSteps < ActiveRecord::Migration[8.1]
  def up
    add_column :approval_route_steps, :assign_signer, :boolean,
               :null => false, :default => false
  end

  def down
    remove_column :approval_route_steps, :assign_signer
  end
end

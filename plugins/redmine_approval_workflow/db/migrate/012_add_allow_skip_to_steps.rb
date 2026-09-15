# frozen_string_literal: true

# A step that can be signed without waiting for the ones before it, when the
# workflow allows the move anyway -- "tự nhận việc" without being given it.
# Off by default: every existing chain keeps running strictly in order.
class AddAllowSkipToSteps < ActiveRecord::Migration[8.1]
  def up
    add_column :approval_route_steps, :allow_skip, :boolean,
               :null => false, :default => false
  end

  def down
    remove_column :approval_route_steps, :allow_skip
  end
end

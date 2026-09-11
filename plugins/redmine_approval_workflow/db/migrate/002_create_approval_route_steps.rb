# frozen_string_literal: true

class CreateApprovalRouteSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :approval_route_steps do |t|
      t.integer :approval_route_id, :null => false
      t.integer :position, :null => false, :default => 0
      t.string  :name, :null => false
      t.integer :issue_status_id, :null => false
      t.timestamps
    end

    add_index :approval_route_steps, [:approval_route_id, :position]
  end
end

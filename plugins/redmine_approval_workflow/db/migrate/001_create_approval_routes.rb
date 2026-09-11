# frozen_string_literal: true

class CreateApprovalRoutes < ActiveRecord::Migration[8.1]
  def change
    create_table :approval_routes do |t|
      t.string  :name, :null => false
      t.integer :tracker_id, :null => false
      t.integer :project_id
      t.integer :rejected_status_id
      t.text    :description
      t.boolean :active, :null => false, :default => true
      t.timestamps
    end

    add_index :approval_routes, [:tracker_id, :project_id]
  end
end

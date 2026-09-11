# frozen_string_literal: true

class CreateApprovalSignatures < ActiveRecord::Migration[8.1]
  def change
    create_table :approval_signatures do |t|
      t.integer  :issue_id, :null => false
      t.integer  :approval_route_id, :null => false
      t.integer  :approval_route_step_id
      t.integer  :step_position, :null => false, :default => 0
      t.string   :step_name
      t.integer  :user_id, :null => false
      t.string   :action, :null => false
      t.integer  :from_status_id
      t.integer  :to_status_id
      t.text     :comments
      t.integer  :journal_id
      t.datetime :created_at, :null => false
    end

    add_index :approval_signatures, [:issue_id, :id]
  end
end

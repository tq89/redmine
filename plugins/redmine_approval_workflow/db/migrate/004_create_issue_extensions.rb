# frozen_string_literal: true

class CreateIssueExtensions < ActiveRecord::Migration[8.1]
  def change
    create_table :issue_extensions do |t|
      t.integer  :issue_id, :null => false
      t.integer  :user_id, :null => false
      t.date     :previous_due_date
      t.date     :new_due_date, :null => false
      t.integer  :days, :null => false, :default => 0
      t.text     :reason
      t.integer  :journal_id
      t.datetime :created_at, :null => false
    end

    add_index :issue_extensions, [:issue_id, :id]
  end
end

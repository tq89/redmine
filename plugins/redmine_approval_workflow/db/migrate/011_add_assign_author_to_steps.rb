# frozen_string_literal: true

# "Giao việc": a step that makes the signer the issue's author -- the person who
# handed the work out. Off by default, so every existing step is untouched.
class AddAssignAuthorToSteps < ActiveRecord::Migration[8.1]
  def up
    add_column :approval_route_steps, :assign_author, :boolean,
               :null => false, :default => false
  end

  def down
    remove_column :approval_route_steps, :assign_author
  end
end

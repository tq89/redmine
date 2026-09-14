# frozen_string_literal: true

# Two one-to-one relationships become lists.
#
# A step held exactly one approver in three columns; it now holds an ordered
# list of them plus a mode saying whether one signature is enough (OR) or every
# one of them has to sign, in order (AND).
#
# A route was bound to exactly one tracker; it now covers as many as the
# administrator lists.
#
# Existing configuration is carried across before the old columns go: a step
# with an approver becomes a one-item list in "any" mode, which behaves exactly
# as it did, and a route keeps the tracker it had.
class AddApproverListsAndTrackers < ActiveRecord::Migration[8.1]
  def up
    create_table :approval_route_approvers do |t|
      t.integer :approval_route_step_id, :null => false
      t.integer :position, :null => false, :default => 0
      t.integer :approver_role_id
      t.integer :approver_user_id
      t.string  :approver_dynamic
    end
    add_index :approval_route_approvers, [:approval_route_step_id, :position],
              :name => 'index_approval_route_approvers_on_step_and_position'

    add_column :approval_route_steps, :approval_mode, :string,
               :null => false, :default => 'any'

    create_table :approval_route_trackers do |t|
      t.integer :approval_route_id, :null => false
      t.integer :tracker_id, :null => false
    end
    add_index :approval_route_trackers, [:approval_route_id, :tracker_id],
              :unique => true, :name => 'index_approval_route_trackers_unique'
    add_index :approval_route_trackers, :tracker_id

    # Which slot of a multi-approver step a signature filled. Left null by
    # rows that predate the list, and by anything reconciled from history.
    add_column :approval_signatures, :approval_route_approver_id, :integer
    add_index :approval_signatures, :approval_route_approver_id

    execute <<~SQL.squish
      INSERT INTO approval_route_approvers
        (approval_route_step_id, position, approver_role_id, approver_user_id, approver_dynamic)
      SELECT id, 0, approver_role_id, approver_user_id, approver_dynamic
      FROM approval_route_steps
      WHERE approver_role_id IS NOT NULL
         OR approver_user_id IS NOT NULL
         OR (approver_dynamic IS NOT NULL AND approver_dynamic <> '')
    SQL

    execute <<~SQL.squish
      INSERT INTO approval_route_trackers (approval_route_id, tracker_id)
      SELECT id, tracker_id FROM approval_routes WHERE tracker_id IS NOT NULL
    SQL

    # Dropped rather than left behind: a column nothing reads any more is a
    # column that quietly disagrees with the truth next time somebody looks.
    remove_column :approval_route_steps, :approver_role_id
    remove_column :approval_route_steps, :approver_user_id
    remove_column :approval_route_steps, :approver_dynamic
    remove_column :approval_routes, :tracker_id
  end

  def down
    add_column :approval_routes, :tracker_id, :integer
    add_column :approval_route_steps, :approver_role_id, :integer
    add_column :approval_route_steps, :approver_user_id, :integer
    add_column :approval_route_steps, :approver_dynamic, :string

    # A route covering several trackers cannot be expressed by one column, so
    # it keeps the lowest; a step keeps its first approver.
    execute <<~SQL.squish
      UPDATE approval_routes SET tracker_id =
        (SELECT MIN(tracker_id) FROM approval_route_trackers
          WHERE approval_route_trackers.approval_route_id = approval_routes.id)
    SQL
    execute <<~SQL.squish
      UPDATE approval_route_steps SET
        approver_role_id = (SELECT approver_role_id FROM approval_route_approvers a
                             WHERE a.approval_route_step_id = approval_route_steps.id
                             ORDER BY a.position, a.id LIMIT 1),
        approver_user_id = (SELECT approver_user_id FROM approval_route_approvers a
                             WHERE a.approval_route_step_id = approval_route_steps.id
                             ORDER BY a.position, a.id LIMIT 1),
        approver_dynamic = (SELECT approver_dynamic FROM approval_route_approvers a
                             WHERE a.approval_route_step_id = approval_route_steps.id
                             ORDER BY a.position, a.id LIMIT 1)
    SQL

    remove_column :approval_signatures, :approval_route_approver_id
    drop_table :approval_route_trackers
    remove_column :approval_route_steps, :approval_mode
    drop_table :approval_route_approvers
  end
end

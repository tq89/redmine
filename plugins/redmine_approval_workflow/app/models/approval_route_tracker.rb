# frozen_string_literal: true

# Which trackers a route covers. A plain join row; the unique index on
# (approval_route_id, tracker_id) is what stops a duplicate.
class ApprovalRouteTracker < ApplicationRecord
  belongs_to :approval_route
  belongs_to :tracker

  # Only tracker_id: approval_route_id is filled in by the parent's save, which
  # happens after these rows are validated, so requiring it here would reject
  # every route at the moment it is created.
  #
  # Not redundant despite what RuboCop reads into the belongs_to: Redmine
  # leaves belongs_to_required_by_default unset, so a belongs_to is optional
  # and this validation is what actually keeps the column populated.
  validates :tracker_id, :presence => true
end

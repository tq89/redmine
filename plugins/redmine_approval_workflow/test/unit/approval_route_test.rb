# frozen_string_literal: true

require_relative '../test_helper'

class ApprovalRouteTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
  end

  def test_for_issue_returns_route_matching_tracker
    route = build_route(:tracker_id => 1)
    issue = Issue.find(1)

    assert_equal 1, issue.tracker_id
    assert_equal route, ApprovalRoute.for_issue(issue)
  end

  def test_for_issue_ignores_other_trackers
    build_route(:tracker_id => 2)

    assert_nil ApprovalRoute.for_issue(Issue.find(1))
  end

  def test_for_issue_ignores_inactive_routes
    route = build_route(:tracker_id => 1)
    route.update!(:active => false)

    assert_nil ApprovalRoute.for_issue(Issue.find(1))
  end

  def test_project_route_wins_over_global_route
    issue = Issue.find(1)
    build_route(:tracker_id => 1, :project_id => nil)
    project_route = build_route(:tracker_id => 1, :project_id => issue.project_id)

    assert_equal project_route, ApprovalRoute.for_issue(issue)
  end

  def test_global_route_applies_when_no_project_route_exists
    issue = Issue.find(1)
    build_route(:tracker_id => 1, :project_id => issue.project_id + 100)
    global_route = build_route(:tracker_id => 1, :project_id => nil)

    assert_equal global_route, ApprovalRoute.for_issue(issue)
  end

  def test_steps_are_ordered_by_position
    route = build_route(:tracker_id => 1, :statuses => [2, 3])
    route.steps.first.update!(:position => 5)

    assert_equal [3, 2], route.reload.steps.map(&:issue_status_id)
  end

  def test_name_and_trackers_are_required
    route = ApprovalRoute.new
    assert_not route.valid?
    assert_includes route.errors.attribute_names, :name
    assert_includes route.errors.attribute_names, :tracker_ids
  end

  # --- several trackers per route -------------------------------------------

  def test_a_route_covers_every_tracker_listed
    route = build_route(:tracker_ids => [1, 2], :statuses => [2, 3])

    assert_equal [1, 2], route.tracker_ids.sort
    assert route.covers_tracker?(1)
    assert route.covers_tracker?(2)
    assert_not route.covers_tracker?(3)
  end

  def test_for_issue_matches_any_of_the_listed_trackers
    route = build_route(:tracker_ids => [1, 2], :statuses => [2, 3])
    issue = Issue.find(1)

    [1, 2].each do |tracker_id|
      issue.update_columns(:tracker_id => tracker_id)
      assert_equal route.id, ApprovalRoute.for_issue(issue.reload)&.id,
                   "tracker #{tracker_id} is listed, so the route must govern it"
    end

    issue.update_columns(:tracker_id => 3)
    assert_nil ApprovalRoute.for_issue(issue.reload)
  end

  def test_a_project_route_still_wins_over_a_global_one
    global = build_route(:tracker_ids => [1, 2], :statuses => [2, 3])
    local  = build_route(:tracker_ids => [1], :project_id => 1, :statuses => [2, 3])
    issue = Issue.find(1)

    assert_equal local.id, ApprovalRoute.for_issue(issue)&.id
    assert_not_equal global.id, ApprovalRoute.for_issue(issue)&.id
  end

  def test_trackers_can_be_changed_without_touching_the_steps
    route = build_route(:tracker_ids => [1], :statuses => [2, 3])
    step_ids = route.steps.map(&:id)

    route.update!(:tracker_ids => [1, 2])

    assert_equal [1, 2], route.reload.tracker_ids.sort
    assert_equal step_ids, route.steps.map(&:id)
  end

  def test_destroying_a_route_removes_its_tracker_rows
    route = build_route(:tracker_ids => [1, 2], :statuses => [2, 3])

    assert_difference 'ApprovalRouteTracker.count', -2 do
      route.destroy
    end
  end

  def test_destroying_route_destroys_steps
    route = build_route(:tracker_id => 1)
    assert_difference 'ApprovalRouteStep.count', -2 do
      route.destroy
    end
  end
end

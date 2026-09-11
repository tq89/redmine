# frozen_string_literal: true

require_relative '../test_helper'

class HistorySyncTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  Sync = RedmineApprovalWorkflow::HistorySync

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    # Core fixtures already give issue 1 a journal that moves it 1 -> 2. That is
    # exactly the kind of history this feature exists to read, but it makes the
    # algorithm tests ambiguous, so each one builds the history it means to test.
    # RealFixtureHistoryTest below keeps the untouched-fixture case covered.
    @issue.journals.delete_all
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    set_plugin_settings('sync_status_from_history' => '1')
  end

  # Moves the issue the way a user would: through the ordinary journalled save,
  # so the status history this feature reads from is the real thing.
  def move_status(to_status_id, user_id = 2)
    issue = Issue.find(@issue.id)
    issue.init_journal(User.find(user_id))
    issue.status_id = to_status_id
    issue.save!
    issue
  end

  def route!(statuses)
    @route = build_route(:tracker_id => @issue.tracker_id, :statuses => statuses)
  end

  def test_fills_a_step_the_issue_already_walked_past
    move_status(2)
    ApprovalSignature.delete_all # the route did not exist while it moved
    route!([2, 3])

    created = Sync.backfill(@issue.reload)

    assert_equal 1, created.size
    signature = created.first
    assert signature.derived?, 'must not masquerade as a real signature'
    assert_equal 0, signature.step_position
    assert_equal 2, signature.to_status_id
    assert_equal 1, signature.from_status_id
    assert_equal 2, signature.user_id, 'credits whoever actually moved it'
    assert_not_nil signature.journal_id
    assert_equal 1, @issue.reload.approval_position
  end

  def test_walks_several_steps_in_order
    move_status(2)
    move_status(3, 3)
    ApprovalSignature.delete_all
    route!([2, 3])

    created = Sync.backfill(@issue.reload)

    assert_equal [0, 1], created.map(&:step_position)
    assert_equal [2, 3], created.map(&:to_status_id)
    assert_equal [2, 3], created.map(&:user_id), 'each step credits its own mover'
    assert @issue.reload.approval_completed?
  end

  def test_ignores_a_detour_through_an_unrelated_status
    move_status(4) # Feedback, not part of the chain
    move_status(2)
    ApprovalSignature.delete_all
    route!([2, 3])

    created = Sync.backfill(@issue.reload)

    assert_equal [0], created.map(&:step_position)
    assert_equal 2, created.first.to_status_id
  end

  def test_matches_the_status_the_issue_was_created_in
    route!([1, 2])

    created = Sync.backfill(@issue.reload)

    assert_equal [0], created.map(&:step_position)
    signature = created.first
    assert_equal @issue.author_id, signature.user_id
    assert_nil signature.journal_id, 'a creation status leaves no journal of its own'
  end

  def test_is_idempotent
    move_status(2)
    ApprovalSignature.delete_all
    route!([2, 3])

    assert_equal 1, Sync.backfill(@issue.reload).size
    assert_equal 0, Sync.backfill(@issue.reload).size, 'second run must add nothing'
    assert_equal 1, ApprovalSignature.where(:issue_id => @issue.id).count
  end

  def test_never_overwrites_a_real_signature
    route!([2, 3])
    real = ApprovalSignature.create!(:issue => @issue, :approval_route => @route,
                                     :approval_route_step => @route.step_at(0),
                                     :step_position => 0, :user_id => 2,
                                     :action => ApprovalSignature::APPROVED,
                                     :to_status_id => 2)
    move_status(3)

    Sync.backfill(@issue.reload)

    assert real.reload.signed?, 'the real signature must stay a real signature'
    step0 = ApprovalSignature.where(:issue_id => @issue.id, :step_position => 0)
    assert_equal 1, step0.count, 'step 0 must not be filled twice'
  end

  def test_adds_nothing_when_the_status_never_reached_the_chain
    route!([2, 3])
    assert_equal 1, @issue.status_id

    assert_equal [], Sync.backfill(@issue.reload)
  end

  def test_respects_the_setting
    move_status(2)
    ApprovalSignature.delete_all
    route!([2, 3])
    set_plugin_settings('sync_status_from_history' => '0')

    assert_equal [], Sync.backfill(@issue.reload)
    assert_equal 1, Sync.backfill(@issue.reload, :force => true).size,
                 'force is what the rake task and the button use'
  end

  def test_reconciling_clears_the_out_of_sync_warning
    move_status(2)
    ApprovalSignature.delete_all
    route!([2, 3])
    # A chain with no signatures is not "out of sync" yet, it just has not
    # started; the drift shows once it advances past a step it never recorded.
    Sync.backfill(@issue.reload)

    assert_not @issue.reload.approval_out_of_sync?
  end

  def test_timeline_starts_from_the_creation_status
    move_status(2)
    entries = Sync.timeline(@issue.reload)

    assert_equal 1, entries.first[:status_id], 'first entry is the status it was created in'
    assert_nil entries.first[:journal]
    assert_equal 2, entries.last[:status_id]
    assert_not_nil entries.last[:journal]
  end
end

# The point of the feature: an instance that already has years of status
# history, with the route added afterwards. These run against the core fixtures
# untouched.
class RealFixtureHistoryTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  Sync = RedmineApprovalWorkflow::HistorySync

  def setup
    User.current = nil
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    set_plugin_settings('sync_status_from_history' => '1')
  end

  def test_picks_up_a_status_change_that_predates_the_route
    # Fixture journal 1 moves issue 1 from status 1 to status 2, by user 1,
    # long before any approval route existed.
    journal = Sync.status_journals(@issue).first
    assert_not_nil journal, 'fixtures must carry a status change for this test to mean anything'
    detail = Sync.status_detail(journal)
    assert_equal '2', detail.value

    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    created = Sync.backfill(@issue.reload)

    assert_equal 1, created.size
    signature = created.first
    assert signature.derived?
    assert_equal route.step_at(0).id, signature.approval_route_step_id
    assert_equal journal.user_id, signature.user_id
    assert_equal journal.id, signature.journal_id
    assert_equal journal.created_on.to_i, signature.created_at.to_i,
                 'the entry is dated when the move happened, not when we noticed'
  end
end

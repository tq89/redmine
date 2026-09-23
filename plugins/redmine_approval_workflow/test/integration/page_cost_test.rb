# frozen_string_literal: true

require_relative '../test_helper'

# What the plugin costs a page, measured on the rendered page rather than on
# the lookups underneath it.
#
# This exists because the lookups were bounded and the pages were not. The
# bulk lookup worked out the pending step for every row and the views then
# threw that away and asked each issue for its own step, which re-runs the
# route lookup and reloads the signatures -- four queries a row, on a bell
# that renders on every page of the site. A hundred rows meant four hundred
# extra queries per page, for every logged-in user. A query-count test on the
# lookup alone could not see any of it.
class PageCostTest < Redmine::IntegrationTest
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalSignature.delete_all
    IssueExtension.delete_all
    @issue = Issue.find(1)
    @project = @issue.project
    EnabledModule.create!(:project_id => @project.id, :name => 'approval_workflow')
    Role.find(1).add_permission!(:view_approval_workflow, :extend_issue_due_date)
  end

  def queries_for(path)
    count = 0
    counter = lambda do |_n, _s, _f, _i, payload|
      next if payload[:name].in?(%w[CACHE SCHEMA])
      next if payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

      count += 1
    end
    # Warm first: the first render of a template and the session lookup are
    # one-offs that would otherwise be counted as page cost.
    get path
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') {get path}
    assert_response :success
    count
  end

  def generate_issues(count)
    count.times do |i|
      Issue.generate!(:project_id => @project.id, :tracker_id => @issue.tracker_id,
                      :status_id => 1, :subject => "Ho so #{i}")
    end
  end

  # --- the bell renders on every page ---------------------------------------

  def test_the_bell_does_not_get_more_expensive_as_the_queue_grows
    build_route(:tracker_id => @issue.tracker_id, :project_id => @project.id,
                :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    generate_issues(3)
    baseline = queries_for('/')

    generate_issues(40)
    grown = queries_for('/')

    assert_operator RedmineApprovalWorkflow::PendingApprovals.for_user(User.find(2)).size,
                    :>=, 40, 'the bell must actually be listing them'
    assert_operator grown, :<=, baseline + 5,
                    "the bell grew with the queue: #{baseline} -> #{grown} queries a page"
  end

  def test_the_pending_page_does_not_get_more_expensive_either
    build_route(:tracker_id => @issue.tracker_id, :project_id => @project.id,
                :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    generate_issues(3)
    baseline = queries_for('/pending_approvals')

    generate_issues(40)
    grown = queries_for('/pending_approvals')

    assert_operator grown, :<=, baseline + 5,
                    "the page grew with the queue: #{baseline} -> #{grown} queries"
  end

  # --- the panel on the issue page ------------------------------------------

  # The chain, the button bar, the floating header and the hint that explains
  # a missing reject button all ask can_approve?/can_reject_approval? again,
  # and each answer costs a new_statuses_allowed_to. They are memoised on a
  # key holding every input, so the page asks once.
  def test_the_panel_costs_the_issue_page_little_and_does_not_grow
    log_user('jsmith', 'jsmith')
    bare = queries_for("/issues/#{@issue.id}")

    route = build_route(:tracker_id => @issue.tracker_id, :project_id => @project.id,
                        :statuses => [2, 3, 5])
    route.step_at(1).update!(:allow_skip => true)
    route.step_at(2).update!(:reject_mode => ApprovalRouteStep::REJECT_KEEP)
    with_panel = queries_for("/issues/#{@issue.id}")

    assert_select 'div.approval-workflow', 1
    # A handful per step -- reading whether this user may sign it or skip to
    # it -- and nothing else. The ceiling is loose on purpose; what it catches
    # is an order-of-magnitude slip, which is the shape this went wrong in.
    assert_operator with_panel, :<=, bare + 30,
                    "the panel added #{with_panel - bare} queries to the issue page"
  end

  # The real invariant: the panel reads one issue's chain, so nothing about
  # the rest of the instance may change what it costs.
  def test_the_issue_page_does_not_grow_with_the_rest_of_the_instance
    build_route(:tracker_id => @issue.tracker_id, :project_id => @project.id,
                :statuses => [2, 3])
    log_user('jsmith', 'jsmith')
    baseline = queries_for("/issues/#{@issue.id}")

    generate_issues(40)
    grown = queries_for("/issues/#{@issue.id}")

    assert_operator grown, :<=, baseline + 5,
                    "the issue page grew with the instance: #{baseline} -> #{grown}"
  end

  # --- the extension queue --------------------------------------------------

  def test_other_peoples_extension_requests_do_not_slow_the_bell
    build_route(:tracker_id => @issue.tracker_id, :project_id => @project.id,
                :statuses => [2, 3])
    ext = ApprovalRoute.create!(:name => 'GH', :tracker_ids => [@issue.tracker_id],
                                :project_id => @project.id,
                                :kind => ApprovalRoute::EXTENSION_KIND)
    ext.steps.create!(:name => 'Duyệt', :position => 0, :approver_tokens => ['user:3'])
    log_user('jsmith', 'jsmith')
    baseline = queries_for('/')

    30.times do |i|
      issue = Issue.generate!(:project_id => @project.id, :tracker_id => @issue.tracker_id,
                              :status_id => 1, :subject => "GH #{i}")
      IssueExtension.create!(:issue => issue, :user_id => 2, :approval_route => ext,
                             :status => IssueExtension::PENDING,
                             :new_due_date => Date.today + 20, :reason => 'x')
    end
    grown = queries_for('/')

    assert_equal 30, IssueExtension.pending.count
    assert_operator grown, :<=, baseline + 5,
                    "requests listed to somebody else cost #{grown - baseline} queries a page"
  end

  # --- signing must not wait for the mailing list ---------------------------

  # Working out who to tell means asking can_approve? per candidate, and on a
  # step that names nobody the candidates are every member holding the
  # transition. That belongs in a job, not in the POST the signer is waiting
  # on.
  def test_signing_enqueues_the_notification_instead_of_computing_it
    build_route(:tracker_id => @issue.tracker_id, :project_id => @project.id,
                :statuses => [2, 3])
    set_plugin_settings('notify_on_pending_approval' => '1')
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    log_user('jsmith', 'jsmith')

    post "/issues/#{@issue.id}/approvals?decision=approve"

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 2, @issue.reload.status_id
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.
           select {|j| j[:job] == ApprovalNotificationJob}
    assert_equal 1, jobs.size, 'the notification work must leave the request'
    sent = ActionMailer::Base.deliveries.
           select {|m| m.subject.to_s.include?(::I18n.t(:mail_subject_approval_pending))}
    assert_empty sent
  ensure
    ActiveJob::Base.queue_adapter = previous if previous
  end

  def test_the_job_still_sends_the_mail
    build_route(:tracker_id => @issue.tracker_id, :project_id => @project.id,
                :statuses => [2, 3])
    set_plugin_settings('notify_on_pending_approval' => '1')
    Setting.default_language = 'en'
    ActionMailer::Base.deliveries.clear

    ApprovalNotificationJob.perform_now('issue', @issue.id, nil)

    assert_not_empty ActionMailer::Base.deliveries
  end

  def test_the_job_swallows_a_missing_record
    assert_nothing_raised do
      ApprovalNotificationJob.perform_now('issue', 999_999, nil)
      ApprovalNotificationJob.perform_now('extension', 999_999, nil)
    end
  end
end

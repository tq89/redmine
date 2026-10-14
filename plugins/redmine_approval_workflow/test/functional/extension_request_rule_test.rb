# frozen_string_literal: true

require_relative '../test_helper'

# Who may ASK for more time.
#
# The report: "Nhân viên của tôi không thấy mục gia hạn để trình ký". The
# request gate demanded what only the WRITE needs -- the right to edit the
# issue and a writable due_date -- even when an approval chain stands in front
# of the write. The people who most need to ask for more time are exactly the
# ones the workflow does not let move the deadline themselves, so they never
# saw the button.
#
# The rule now depends on what the request does:
#   chain    -> the request writes nothing; the requester must be someone the
#               work concerns (assignee, author, or an editor). The final
#               approver's own rights guard the actual write.
#   no chain -> the request IS the write, applied at once; the requester needs
#               exactly what the issue form would require. Unchanged.
class ExtensionRequestRuleTest < Redmine::ControllerTest
  include RedmineApprovalWorkflow::TestFixtures

  tests IssueExtensionsController

  def setup
    User.current = nil
    IssueExtension.delete_all
    ApprovalSignature.delete_all
    ApprovalRouteApprover.delete_all
    ApprovalRouteStep.delete_all
    ApprovalRoute.delete_all
    @issue = Issue.find(1)                       # author jsmith (2), project 1, tracker 1
    @due = @issue.start_date + 30
    @issue.update_columns(:due_date => @due, :assigned_to_id => 3)  # dlopper does the work
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    @employee_role = Role.find(2)                # dlopper's role on project 1
    @employee_role.add_permission!(:extend_issue_due_date)
    set_plugin_settings('max_extension_days' => '30')
  end

  def chain!
    @route = build_extension_route(:approvers => ['user:2'])
  end

  def lock_due_date_for_employees!
    WorkflowPermission.create!(:tracker_id => @issue.tracker_id, :role_id => @employee_role.id,
                               :old_status_id => @issue.status_id,
                               :field_name => 'due_date', :rule => 'readonly')
  end

  def strip_edit_rights!
    @employee_role.remove_permission!(:edit_issues)
    @employee_role.remove_permission!(:edit_own_issues)
  end

  def request_extension(user_id = 3, days: 10)
    @request.session[:user_id] = user_id
    post :create, :params => {:issue_id => @issue.id,
                              :issue_extension => {:new_due_date => (@due + days).to_s,
                                                   :reason => 'Chờ vật tư'}}
  end

  def issue
    Issue.find(@issue.id)
  end

  # --- with a chain: asking needs no edit rights ------------------------------

  def test_an_employee_whose_due_date_is_locked_can_submit_for_signing
    chain!
    lock_due_date_for_employees!

    assert issue.extendable_by?(User.find(3))
    assert_difference 'IssueExtension.count', 1 do
      request_extension
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert IssueExtension.last.pending?
    assert_equal @due, issue.due_date, 'asking moves nothing; the chain decides'
  end

  def test_an_assignee_with_only_edit_own_issues_can_submit
    chain!
    @employee_role.remove_permission!(:edit_issues)
    @employee_role.add_permission!(:edit_own_issues)
    assert_not issue.attributes_editable?(User.find(3)), 'dlopper is not the author'

    request_extension

    assert IssueExtension.last&.pending?
  end

  def test_an_assignee_with_no_edit_rights_at_all_can_submit
    chain!
    strip_edit_rights!

    request_extension

    assert IssueExtension.last&.pending?
    assert_equal @due, issue.due_date
  end

  def test_the_author_can_submit_without_edit_rights
    chain!
    strip_edit_rights!
    @issue.update_columns(:author_id => 3, :assigned_to_id => nil)

    request_extension

    assert IssueExtension.last&.pending?
  end

  def test_a_member_of_the_assigned_group_can_submit
    chain!
    strip_edit_rights!
    group = Group.find(10)
    group.users << User.find(3) unless group.users.include?(User.find(3))
    @issue.update_columns(:assigned_to_id => group.id)

    assert issue.extendable_by?(User.find(3).reload)
  end

  # Not every member holding the permission: a colleague's deadline is not
  # theirs to reopen.
  def test_a_colleague_who_is_neither_assignee_nor_author_cannot
    chain!
    strip_edit_rights!
    @issue.update_columns(:assigned_to_id => 2)

    assert_equal :not_involved, issue.extension_request_denial(User.find(3))
    assert_no_difference 'IssueExtension.count' do
      request_extension
    end
    assert_response :forbidden
  end

  def test_the_permission_is_still_required
    chain!
    @employee_role.remove_permission!(:extend_issue_due_date)

    assert_equal :no_permission, issue.extension_request_denial(User.find(3))
  end

  def test_anonymous_is_never_involved_even_as_the_recorded_author
    chain!
    Role.anonymous.add_permission!(:extend_issue_due_date)
    @issue.update_columns(:author_id => User.anonymous.id)

    assert_not issue.extendable_by?(User.anonymous)
  end

  # --- the write is still guarded where it happens ----------------------------

  # Somebody who could only ask -- due_date locked for them -- is not turned
  # into somebody who can approve their own request by being on the chain.
  def test_a_relaxed_requester_named_on_the_chain_still_cannot_sign_it
    @route = build_extension_route(:approvers => ['dynamic:assignee'])
    lock_due_date_for_employees!

    request_extension
    extension = IssueExtension.last

    assert extension.pending?
    assert_not extension.signable_by?(User.find(3)),
               'signing writes due_date, and due_date is locked for them'
    assert_nil RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(3), :approve => true)
    assert_equal @due, issue.due_date
  end

  # --- without a chain: the request is the write, rule unchanged -------------

  def test_without_a_chain_a_locked_due_date_still_refuses
    lock_due_date_for_employees!

    assert_equal :due_date_readonly, issue.extension_request_denial(User.find(3))
    assert_no_difference 'IssueExtension.count' do
      request_extension
    end
    assert_response :forbidden
    assert_equal @due, issue.due_date
  end

  def test_without_a_chain_edit_rights_are_still_required
    strip_edit_rights!

    assert_equal :not_editable, issue.extension_request_denial(User.find(3))
  end

  def test_a_route_with_no_steps_counts_as_no_chain
    ApprovalRoute.create!(:name => 'Rỗng', :tracker_ids => [@issue.tracker_id],
                          :kind => ApprovalRoute::EXTENSION_KIND)
    lock_due_date_for_employees!

    assert_nil issue.extension_route
    assert_equal :due_date_readonly, issue.extension_request_denial(User.find(3))
  end

  # The gate must judge the path the request will actually take. A chain that
  # disappears between loading the form and posting it means an immediate
  # write, and the strict rule applies -- never "passed on the chain rule,
  # then applied without a chain".
  def test_a_chain_switched_off_before_posting_falls_back_to_the_strict_rule
    chain!
    lock_due_date_for_employees!
    @request.session[:user_id] = 3
    get :new, :params => {:issue_id => @issue.id}
    assert_response :success, 'with the chain on, the form is offered'

    @route.update!(:active => false)

    assert_no_difference 'IssueExtension.count' do
      request_extension
    end
    assert_response :forbidden
    assert_equal @due, issue.due_date
  end

  # --- new and create agree ---------------------------------------------------

  def test_the_form_is_refused_to_whoever_create_would_refuse
    lock_due_date_for_employees!   # no chain: dlopper may not write due_date
    @request.session[:user_id] = 3

    get :new, :params => {:issue_id => @issue.id}

    assert_response :forbidden
  end

  # --- findings from the adversarial review ----------------------------------

  # Somebody else's work stays somebody else's on the no-chain path too: the
  # panel must not tell a colleague to "ask a manager for a route" when a route
  # would still not let them ask.
  def test_an_uninvolved_colleague_is_not_involved_without_a_chain_either
    strip_edit_rights!
    @issue.update_columns(:assigned_to_id => 2)

    assert_equal :not_involved, issue.extension_request_denial(User.find(3))
  end

  # Involvement is decided before the limit, so a colleague is not shown a
  # "used up" hint that suggests a higher limit would let them ask.
  def test_involvement_is_decided_before_the_limit
    chain!
    strip_edit_rights!
    @issue.update_columns(:assigned_to_id => 2)
    set_plugin_settings('max_extension_count' => '1')
    IssueExtension.create!(:issue => @issue, :user_id => 2, :status => IssueExtension::APPROVED,
                           :previous_due_date => @due, :new_due_date => @due + 5, :reason => 'x')

    assert_equal :not_involved, issue.extension_request_denial(User.find(3))
    @issue.update_columns(:assigned_to_id => 3)
    assert_equal :limit_reached, issue.extension_request_denial(User.find(3))
  end

  # logged? guards only the author match. An anonymous EDITOR could file a
  # pending request before; taking that away while still letting the same
  # visitor write the date at once (no chain) would be backwards.
  def test_an_anonymous_editor_may_still_ask_on_a_chain
    chain!
    project = @issue.project
    project.update_columns(:is_public => true)
    Role.anonymous.add_permission!(:extend_issue_due_date, :edit_issues, :view_issues)
    Role.anonymous.update_columns(:issues_visibility => 'all')

    assert issue.attributes_editable?(User.anonymous), 'fixture: anonymous may edit here'
    assert_nil issue.extension_request_denial(User.anonymous)
  end

  # The route lookup is a query or two and runs for every viewer of every
  # issue page; nobody without the permission should pay for it.
  def test_no_route_lookup_for_someone_without_the_permission
    chain!
    @employee_role.remove_permission!(:extend_issue_due_date)
    loaded = issue
    route_queries = 0
    counter = lambda do |_n, _s, _f, _i, payload|
      route_queries += 1 if payload[:sql].to_s.include?(ApprovalRoute.table_name)
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      assert_equal :no_permission, loaded.extension_request_denial(User.find(3))
    end

    assert_equal 0, route_queries
  end

  # A parent whose dates come from its subtasks cannot be moved through the
  # form, so it cannot be moved through an extension either -- not by the
  # requester, and not by an approver signing it.
  def test_a_parent_with_derived_dates_takes_no_extension
    chain!
    Role.find(1).add_permission!(:extend_issue_due_date)   # jsmith, the approver
    with_settings :parent_issue_dates => 'derived' do
      Issue.generate!(:project_id => @issue.project_id, :tracker_id => @issue.tracker_id,
                      :subject => 'Con', :parent_issue_id => @issue.id)
      parent = issue

      assert parent.dates_derived?
      assert_equal :due_date_derived, parent.extension_request_denial(User.find(3))
      assert_equal :due_date_derived, parent.extension_request_denial(User.find(2))

      # A request filed before the subtask existed cannot be signed into the
      # parent either: signing writes due_date, which the form no longer allows.
      pending = IssueExtension.create!(:issue => parent, :user_id => 3, :approval_route => @route,
                                       :status => IssueExtension::PENDING,
                                       :previous_due_date => parent.due_date,
                                       :new_due_date => (parent.due_date || Date.today) + 5,
                                       :reason => 'x')
      assert_not pending.signable_by?(User.find(2))
    end
  end

  def test_a_tracker_without_a_due_date_takes_no_extension
    chain!
    tracker = @issue.tracker
    tracker.core_fields = tracker.core_fields - ['due_date']
    tracker.save!

    assert_equal :due_date_disabled, issue.extension_request_denial(User.find(3))
  end

  # --- withdrawing: the way out of a request nobody can decide ----------------

  # The review's scenario: the chain's only approver is the assignee, who may
  # not write due_date. Nobody can approve or reject, and with a limit of one
  # the stuck request would block every further request on the issue, the
  # administrator's included.
  def test_a_request_nobody_can_decide_can_be_withdrawn_and_frees_the_allowance
    build_extension_route(:approvers => ['dynamic:assignee'])
    lock_due_date_for_employees!
    set_plugin_settings('max_extension_count' => '1')
    request_extension
    extension = IssueExtension.last
    assert extension.pending?
    assert_not extension.signable_by?(User.find(3))
    assert_not extension.signable_by?(User.find(1))
    assert_equal :limit_reached, issue.extension_request_denial(User.find(1))

    @request.session[:user_id] = 3
    post :withdraw, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_redirected_to "/issues/#{@issue.id}"
    assert extension.reload.withdrawn?
    assert_not extension.counts_toward_limit?
    assert_nil issue.extension_request_denial(User.find(1)), 'the allowance is free again'
  end

  def test_an_administrator_may_withdraw_anyones_request
    chain!
    request_extension
    @request.session[:user_id] = 1

    post :withdraw, :params => {:issue_id => @issue.id, :id => IssueExtension.last.id}

    assert IssueExtension.last.withdrawn?
  end

  def test_nobody_else_may_withdraw_it
    chain!
    request_extension
    @request.session[:user_id] = 2   # the approver, not the requester

    post :withdraw, :params => {:issue_id => @issue.id, :id => IssueExtension.last.id}

    assert_response :forbidden
    assert IssueExtension.last.pending?
  end

  def test_a_decided_request_cannot_be_withdrawn
    chain!
    request_extension
    extension = IssueExtension.last
    RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)
    assert extension.reload.approved?

    @request.session[:user_id] = 3
    post :withdraw, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_response :forbidden
    assert extension.reload.approved?
  end

  # --- stale requests ---------------------------------------------------------

  # The deadline moved after the request was made. Approving it would write a
  # date picked against a deadline that no longer exists.
  def test_a_stale_request_is_refused_with_a_reason_and_can_still_be_rejected
    chain!
    request_extension(:days => 10)
    extension = IssueExtension.last
    @issue.update_columns(:due_date => @due + 40)   # a manager moved it meanwhile
    assert extension.reload.stale?

    @request.session[:user_id] = 2
    post :approve, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_redirected_to "/issues/#{@issue.id}"
    assert_match(/#{Regexp.escape(format_date(@due + 40))}/, flash[:error].to_s)
    assert extension.reload.pending?
    assert_equal @due + 40, issue.due_date, 'not rolled back to the requested date'

    post :reject, :params => {:issue_id => @issue.id, :id => extension.id}
    assert extension.reload.rejected?
  end

  def test_the_bell_gets_the_stale_reason_as_json
    chain!
    request_extension
    extension = IssueExtension.last
    @issue.update_columns(:due_date => @due - 3)
    @request.session[:user_id] = 2
    @request.headers['Accept'] = 'application/json'

    post :approve, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_response :unprocessable_entity
    assert_equal 'error', ActiveSupport::JSON.decode(response.body)['level']
  end

  def test_decide_itself_refuses_to_approve_a_stale_request
    chain!
    request_extension
    extension = IssueExtension.last
    @issue.update_columns(:due_date => @due + 1)

    assert_nil RedmineApprovalWorkflow::ExtensionApproval.decide(extension.reload, User.find(2), :approve => true)
  end

  # --- findings from the second adversarial round -----------------------------

  # The withdrawal loaded the request while it was pending; the final approval
  # committed before the withdrawal wrote. The write must not land: the
  # extension was granted and has to keep counting toward the limit.
  def test_a_withdrawal_that_lost_the_race_to_the_final_approval_changes_nothing
    chain!
    set_plugin_settings('max_extension_count' => '1')
    request_extension(:days => 10)
    seen_by_requester = IssueExtension.find(IssueExtension.last.id)   # pending, in memory
    assert seen_by_requester.withdrawable_by?(User.find(3))

    RedmineApprovalWorkflow::ExtensionApproval.decide(IssueExtension.find(seen_by_requester.id),
                                                      User.find(2), :approve => true)

    assert_not seen_by_requester.withdraw!, 'somebody decided first'
    assert seen_by_requester.approved?
    assert seen_by_requester.counts_toward_limit?
    assert_equal @due + 10, issue.due_date
    assert_equal :limit_reached, issue.extension_request_denial(User.find(3))
  end

  # The other order: the approver loaded it, the requester withdrew, then the
  # approval ran. A request the requester was told is withdrawn must not be
  # applied.
  def test_an_approval_that_lost_the_race_to_a_withdrawal_applies_nothing
    chain!
    request_extension(:days => 10)
    seen_by_approver = IssueExtension.find(IssueExtension.last.id)
    assert seen_by_approver.signable_by?(User.find(2))

    assert IssueExtension.find(seen_by_approver.id).withdraw!

    assert_nil RedmineApprovalWorkflow::ExtensionApproval.decide(seen_by_approver, User.find(2), :approve => true)
    assert IssueExtension.find(seen_by_approver.id).withdrawn?
    assert_equal @due, issue.due_date
    assert_equal 0, ApprovalSignature.where(:issue_extension_id => seen_by_approver.id).count
  end

  def test_the_approver_is_told_it_was_already_decided
    chain!
    request_extension
    extension = IssueExtension.last
    extension.withdraw!
    # The approver's page was rendered before the withdrawal.
    @request.session[:user_id] = 2
    @request.headers['Accept'] = 'application/json'

    post :approve, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_response :conflict
    assert_equal ::I18n.t(:error_issue_extension_already_decided),
                 ActiveSupport::JSON.decode(response.body)['message']
  end

  # A closed project is read-only for everybody; approving and rejecting are
  # refused there, so withdrawing must be too.
  def test_no_withdrawal_on_a_closed_project
    chain!
    request_extension
    extension = IssueExtension.last
    @issue.project.update_columns(:status => Project::STATUS_CLOSED)

    assert_not extension.reload.withdrawable_by?(User.find(3))
    assert_not extension.withdrawable_by?(User.find(1)), 'not the administrator either'
    @request.session[:user_id] = 3
    post :withdraw, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_response :forbidden
    assert extension.reload.pending?
  end

  def test_the_stale_message_has_no_holes_when_a_date_is_missing
    chain!
    @issue.update_columns(:due_date => nil)
    set_plugin_settings('max_extension_days' => '0')
    @request.session[:user_id] = 3
    post :create, :params => {:issue_id => @issue.id,
                              :issue_extension => {:new_due_date => (Date.today + 10).to_s,
                                                   :reason => 'Chờ vật tư'}}
    extension = IssueExtension.last
    assert_nil extension.previous_due_date
    @issue.update_columns(:due_date => Date.today + 3)   # a manager set one meanwhile

    @request.session[:user_id] = 2
    post :approve, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_include ::I18n.t(:label_none), flash[:error].to_s
    assert_no_match(/from\s+to|từ\s+sang/, flash[:error].to_s)
  end

  # --- findings from the third adversarial round ------------------------------

  # With the module off there is no extension feature: nobody withdraws, and
  # nobody approves a deadline into place either. Before, withdrawing was
  # refused while approvers could still move the date.
  def test_with_the_module_off_nobody_decides
    chain!
    request_extension
    extension = IssueExtension.last
    EnabledModule.where(:project_id => @issue.project_id, :name => 'approval_workflow').delete_all

    assert_not extension.reload.signable_by?(User.find(2))
    assert_not extension.withdrawable_by?(User.find(3))
    assert_not_includes RedmineApprovalWorkflow::ExtensionApproval.pending_for(User.find(2)).map(&:id),
                        extension.id
    @request.session[:user_id] = 2
    post :approve, :params => {:issue_id => @issue.id, :id => extension.id}

    assert_response :forbidden
    assert_equal @due, issue.due_date
  end

  # Issue#destroy locks the issue and then deletes its extension requests. A
  # final approval that locked the request first and the issue second could
  # deadlock against it (reproduced on PostgreSQL). SQLite cannot deadlock, but
  # the order of the locking reads is visible: the issue row must come first.
  def test_a_final_approval_locks_the_issue_before_the_request
    chain!
    request_extension
    extension = IssueExtension.find(IssueExtension.last.id)
    # Only reads inside decide's own transaction count: signable_by? has
    # already read the issue before it, which would make this pass whatever
    # the lock order. Under transactional tests that transaction is a SAVEPOINT.
    reads = []
    in_transaction = false
    counter = lambda do |_n, _s, _f, _i, payload|
      sql = payload[:sql].to_s
      in_transaction = true if sql =~ /\A\s*(SAVEPOINT|BEGIN)/i
      next unless in_transaction && sql.start_with?('SELECT')

      reads << :issue if sql =~ /FROM "issues" WHERE "issues"\."id" = /
      reads << :extension if sql =~ /FROM "issue_extensions" WHERE "issue_extensions"\."id" = /
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      RedmineApprovalWorkflow::ExtensionApproval.decide(extension, User.find(2), :approve => true)
    end

    first_extension = reads.index(:extension)
    assert first_extension, 'the request is re-read under the lock'
    assert reads[0...first_extension].include?(:issue),
           "the issue row must be locked before the request; read order was #{reads.inspect}"
    assert_equal @due + 10, issue.due_date
  end

  def format_date(date)
    ::I18n.l(date)
  end

  # --- the route lookup is memoised and reload clears it ----------------------

  def test_reload_forgets_the_route
    loaded = issue
    assert_nil loaded.extension_route
    chain!

    assert_nil loaded.extension_route, 'memoised for the request'
    assert_not_nil loaded.reload.extension_route
  end
end

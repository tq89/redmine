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

  # --- the route lookup is memoised and reload clears it ----------------------

  def test_reload_forgets_the_route
    loaded = issue
    assert_nil loaded.extension_route
    chain!

    assert_nil loaded.extension_route, 'memoised for the request'
    assert_not_nil loaded.reload.extension_route
  end
end

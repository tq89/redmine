# frozen_string_literal: true

require_relative '../test_helper'

# Exercises the parts that only work once the hook, the view path and the
# explicitly registered helper are all wired together.
class ApprovalPanelTest < Redmine::IntegrationTest
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    ApprovalRoute.delete_all
    ApprovalRouteStep.delete_all
    ApprovalSignature.delete_all
    IssueExtension.delete_all
    @issue = Issue.find(1)
    EnabledModule.create!(:project_id => @issue.project_id, :name => 'approval_workflow')
    Role.find(1).add_permission!(:view_approval_workflow, :extend_issue_due_date)
  end

  def test_issue_page_renders_the_approval_panel
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div.approval-workflow' do
      assert_select 'ol.approval-steps li', 2
      assert_select 'li.approval-step-current', 1
    end
    assert_select "a[href=?]", "/issues/#{@issue.id}/approvals/new?decision=approve"
  end

  def test_issue_page_has_no_approval_panel_without_a_route
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div.approval-workflow', 0
  end

  def test_issue_page_renders_the_extension_panel
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div.issue-extensions'
    assert_select "a[href=?]", "/issues/#{@issue.id}/extensions/new"
  end

  def test_full_approve_then_extend_round_trip
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    set_plugin_settings('max_extension_days' => '30')
    due = @issue.start_date + 30
    @issue.update_columns(:due_date => due)
    log_user('jsmith', 'jsmith')

    post "/issues/#{@issue.id}/approvals", :params => {:decision => 'approve', :comments => 'OK'}
    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 2, @issue.reload.status_id

    post "/issues/#{@issue.id}/extensions",
         :params => {:issue_extension => {:new_due_date => (due + 10).to_s, :reason => 'Chờ vật tư'}}
    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal due + 10, @issue.reload.due_date

    # Both actions must be visible in the issue history.
    get "/issues/#{@issue.id}"
    assert_response :success
    assert_select 'div.approval-workflow li.approval-step-done', 1
    assert_select 'table.issue-extension-list tbody tr', 1
  end

  def test_routes_are_configured_from_the_project_settings
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    get "/projects/#{identifier}/settings/approval_routes"
    assert_response :success
    assert_select "a[href=?]", "/projects/#{identifier}/approval_routes/new"

    get "/projects/#{identifier}/approval_routes/new"
    assert_response :success
    # Rails only treats a nested-attributes hash as a collection when every key
    # is numeric, so a non-numeric index here would be silently dropped by
    # permit and the steps would never be created.
    assert_select 'input[name=?]', 'approval_route[steps_attributes][0][name]'

    assert_difference 'ApprovalRoute.count', 1 do
      post "/projects/#{identifier}/approval_routes", :params => {
        :approval_route => {
          :name => 'Lưu trình duyệt chi',
          :tracker_id => 1,
          :active => '1',
          :steps_attributes => {
            '0' => {:name => 'Trưởng bộ phận', :issue_status_id => 2, :position => 0,
                    :approver_role_id => 1, :button_label => 'Trình ký'},
            '1' => {:name => 'Giám đốc', :issue_status_id => 3, :position => 1,
                    :approver_user_id => 2}
          }
        }
      }
    end

    route = ApprovalRoute.order(:id).last
    assert_equal 'Lưu trình duyệt chi', route.name
    # The route belongs to the project whose settings created it.
    assert_equal @issue.project_id, route.project_id
    assert_equal [0, 1], route.steps.map(&:position)
    assert_equal [2, 3], route.steps.map(&:issue_status_id)
    assert_equal 1, route.step_at(0).approver_role_id
    assert_equal 'Trình ký', route.step_at(0).action_label
    assert_equal 2, route.step_at(1).approver_user_id
    # An unlabelled step falls back to the generic wording.
    assert_equal ::I18n.t(:button_approve), route.step_at(1).action_label
  end

  def test_settings_tab_is_hidden_without_the_permission
    Role.find(1).remove_permission!(:manage_approval_routes)
    log_user('jsmith', 'jsmith')

    get "/projects/#{@issue.project.identifier}/settings"

    assert_response :success
    assert_select "a[href=?]",
                  "/projects/#{@issue.project.identifier}/settings/approval_routes", 0
  end

  def test_managing_routes_is_denied_without_the_permission
    Role.find(1).remove_permission!(:manage_approval_routes)
    log_user('jsmith', 'jsmith')

    get "/projects/#{@issue.project.identifier}/approval_routes/new"

    assert_response :forbidden
  end

  def test_bell_sits_in_the_profile_menu_with_a_count
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '.profile-menu #approval-bell' do
      assert_select 'a.approval-bell-trigger.has-items'
      assert_select 'span.approval-bell-count'
      assert_select '.approval-bell-panel .approval-bell-item', :minimum => 1
    end
  end

  def test_bell_offers_a_quick_sign_button_using_the_step_label
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(0).update!(:button_label => 'Trình ký')
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select "#approval-bell form[action=?]",
                  "/issues/#{@issue.id}/approvals?decision=approve" do
      assert_select 'input[type=submit][value=?]', 'Trình ký'
    end
  end

  def test_quick_sign_from_the_bell_signs_the_step
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    assert_difference 'ApprovalSignature.count', 1 do
      post "/issues/#{@issue.id}/approvals?decision=approve"
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 2, @issue.reload.status_id
  end

  def test_bell_shows_overdue_issues_assigned_to_the_user
    @issue.update_columns(:assigned_to_id => 2, :due_date => Date.today - 5)
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#approval-bell .approval-bell-overdue' do
      assert_select '.approval-overdue-days', :text => /5/
    end
  end

  def test_bell_is_empty_when_nothing_needs_the_user
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#approval-bell span.approval-bell-count', 0
    assert_select '#approval-bell .approval-bell-empty'
  end

  def test_bell_is_hidden_for_anonymous_visitors
    with_settings :login_required => '0' do
      get '/'

      assert_response :success
      assert_select '#approval-bell', 0
    end
  end

  def test_bell_can_be_switched_off_by_the_administrator
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    set_plugin_settings('show_pending_approvals' => '0')
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#approval-bell', 0
  end

  def test_pending_page_lists_the_issue_and_its_next_status
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get '/pending_approvals'

    assert_response :success
    assert_select "table.issues a[href=?]", "/issues/#{@issue.id}"
    # Every listed row must name the step and the status it leads to.
    assert_select 'table.issues tbody tr', :minimum => 1
    assert_select 'table.issues tbody tr td', :text => /#{@issue.approval_route.step_at(0).issue_status.name}/
  end

  def test_pending_page_requires_login
    get '/pending_approvals'

    assert_redirected_to '/login?back_url=' + CGI.escape('http://www.example.com/pending_approvals')
  end

  def test_signing_removes_the_issue_from_the_reminder
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get '/pending_approvals'
    assert_select "table.issues a[href=?]", "/issues/#{@issue.id}"

    post "/issues/#{@issue.id}/approvals", :params => {:decision => 'approve'}
    assert_redirected_to "/issues/#{@issue.id}"

    # The issue now sits at step 1, which targets status 3. Remove every
    # transition out of status 2 so this user cannot sign that step: the issue
    # must drop off the reminder rather than linger on it.
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :old_status_id => 2).delete_all
    get '/pending_approvals'
    assert_select "table.issues a[href='/issues/#{@issue.id}']", 0
  end
end

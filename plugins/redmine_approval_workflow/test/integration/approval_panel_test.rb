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

  def test_admin_can_manage_routes
    log_user('admin', 'admin')

    get '/approval_routes'
    assert_response :success

    get '/approval_routes/new'
    assert_response :success
    # Rails only treats a nested-attributes hash as a collection when every key
    # is numeric, so a non-numeric index here would be silently dropped by
    # permit and the steps would never be created.
    assert_select 'input[name=?]', 'approval_route[steps_attributes][0][name]'

    assert_difference 'ApprovalRoute.count', 1 do
      post '/approval_routes', :params => {
        :approval_route => {
          :name => 'Lưu trình duyệt chi',
          :tracker_id => 1,
          :active => '1',
          :steps_attributes => {
            '0' => {:name => 'Trưởng bộ phận', :issue_status_id => 2, :position => 0},
            '1' => {:name => 'Giám đốc', :issue_status_id => 3, :position => 1}
          }
        }
      }
    end

    route = ApprovalRoute.order(:id).last
    assert_equal 'Lưu trình duyệt chi', route.name
    assert_equal [0, 1], route.steps.map(&:position)
    assert_equal [2, 3], route.steps.map(&:issue_status_id)
  end

  def test_top_menu_shows_the_reminder_with_a_count
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#top-menu a.pending-approvals-alert' do |links|
      assert_match(/\(\d+\)/, links.first.text, 'reminder must carry a count')
    end
  end

  def test_top_menu_hides_the_reminder_when_nothing_is_pending
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#top-menu a.pending-approvals-alert', 0
  end

  def test_reminder_can_be_switched_off_by_the_administrator
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    set_plugin_settings('show_pending_approvals' => '0')
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#top-menu a.pending-approvals-alert', 0
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

  def test_non_admin_cannot_manage_routes
    log_user('jsmith', 'jsmith')

    get '/approval_routes'

    assert_response :forbidden
  end
end

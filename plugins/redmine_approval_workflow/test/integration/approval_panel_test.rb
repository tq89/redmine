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

  # The bell and the footer credit are rendered on Redmine's stock body_bottom
  # hook and moved into place client-side, so the server-rendered markup sits
  # inside the hidden staging wrapper. These assertions check what the server
  # sends; the move itself is the script's job.
  def test_bell_is_rendered_on_the_stock_body_bottom_hook
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select 'div#approval-layout-additions[hidden]' do
      assert_select '#approval-bell a.approval-bell-trigger.has-items'
      assert_select '#approval-bell span.approval-bell-count'
      assert_select '#approval-bell .approval-bell-panel .approval-bell-item', :minimum => 1
      assert_select '#approval-footer-credit'
    end
  end

  def test_relocation_script_targets_the_profile_menu_and_footer
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    # The script only works if these selectors still exist in the layout, so
    # assert both the script's intent and the targets it depends on.
    assert_select '.profile-menu'
    assert_select '#footer'
    assert_include "document.querySelector('.profile-menu')", @response.body
    assert_include "document.getElementById('footer')", @response.body
    assert_include "document.getElementById('approval-bell')", @response.body
  end

  # nav.top-menu is a flex row but .profile-menu has no layout of its own in
  # core, so a block #account beside the bell drops to a second line and the
  # avatar is clipped out of the bar. The script tags the container for it.
  def test_relocation_gives_the_profile_menu_a_row_layout
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_include "profileMenu.classList.add('has-approval-bell')", @response.body
  end

  # An older deployment still carrying the patched core layout prints the credit
  # itself; two of them is worse than none.
  def test_credit_is_not_added_when_the_footer_already_says_it
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_include 'footer.textContent.indexOf', @response.body
    assert_include "root.getAttribute('data-approval-relocated')", @response.body
  end

  def test_footer_credit_is_shipped_by_the_plugin_not_the_layout
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#approval-footer-credit', :text => 'Vận Hành bởi Đỗ Quí'
  end

  # The Help entry is repointed from init.rb via MenuManager, not by editing
  # lib/redmine/preparation.rb.
  def test_top_menu_help_entry_points_at_the_contact_page
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#top-menu a[href=?]', 'https://trongqui.info', :text => 'Liên hệ'
    assert_select '#top-menu a[href*=?]', 'redmine.org/guide', 0
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

  # The user-visible answer to "does the reminder clear once I have signed":
  # sign through the real button, then look at the real bell on the next page.
  def test_bell_drops_the_issue_after_signing_it
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    # Core fixtures let role 1 move between every pair of statuses, so step 1
    # would still be jsmith's; take that away to isolate the clearing.
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => 1,
                             :old_status_id => 2, :new_status_id => 3).delete_all
    log_user('jsmith', 'jsmith')

    get '/'
    assert_select '#approval-bell a.approval-bell-trigger.has-items'
    assert_select "#approval-bell a[href=?]", "/issues/#{@issue.id}"
    before = css_select('#approval-bell span.approval-bell-count').first.text.to_i
    assert before > 0

    post "/issues/#{@issue.id}/approvals", :params => {:decision => 'approve'}
    assert_redirected_to "/issues/#{@issue.id}"

    get '/'
    assert_response :success
    # The signed issue is gone. Other issues on the same route legitimately
    # remain, so the count drops by one rather than to zero.
    assert_select "#approval-bell a[href=?]", "/issues/#{@issue.id}", 0
    after = css_select('#approval-bell span.approval-bell-count').first.text.to_i
    assert_equal before - 1, after, 'the count must drop by exactly the one signed'
  end

  def test_pending_page_drops_the_issue_after_an_ordinary_status_edit
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    WorkflowTransition.where(:tracker_id => @issue.tracker_id, :role_id => 1,
                             :old_status_id => 2, :new_status_id => 3).delete_all
    log_user('jsmith', 'jsmith')

    get '/pending_approvals'
    assert_select "table.issues a[href=?]", "/issues/#{@issue.id}"

    # Not the approval screen: the ordinary issue form.
    put "/issues/#{@issue.id}", :params => {:issue => {:status_id => 2}}

    get '/pending_approvals'
    assert_response :success
    assert_select "table.issues a[href=?]", "/issues/#{@issue.id}", 0
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

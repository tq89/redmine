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
          :tracker_ids => ['1'],
          :active => '1',
          :steps_attributes => {
            '0' => {:name => 'Trưởng bộ phận', :issue_status_id => 2, :position => 0,
                    :approver_tokens => ['role:1'], :button_label => 'Trình ký'},
            '1' => {:name => 'Giám đốc', :issue_status_id => 3, :position => 1,
                    :approver_tokens => ['user:2']}
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
    assert_equal ['role:1'], route.step_at(0).approver_tokens
    assert_equal 'Trình ký', route.step_at(0).action_label
    assert_equal ['user:2'], route.step_at(1).approver_tokens
    # An unlabelled step falls back to the generic wording.
    assert_equal ::I18n.t(:button_approve), route.step_at(1).action_label
  end

  def test_extension_routes_are_configured_from_the_same_settings_tab
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    get "/projects/#{identifier}/settings/approval_routes"
    assert_response :success
    assert_select "a[href=?]",
                  "/projects/#{identifier}/approval_routes/new?kind=extension"

    get "/projects/#{identifier}/approval_routes/new?kind=extension"
    assert_response :success
    # An extension step has no target status, so the column is not offered.
    assert_select 'select[name=?]', 'approval_route[steps_attributes][0][issue_status_id]', 0

    assert_difference 'ApprovalRoute.count', 1 do
      post "/projects/#{identifier}/approval_routes", :params => {
        :approval_route => {
          :name => 'Lưu trình duyệt gia hạn',
          :kind => 'extension',
          :tracker_ids => ['1'],
          :active => '1',
          :steps_attributes => {
            '0' => {:name => 'Trưởng bộ phận', :position => 0, :approver_tokens => ['role:1']},
            '1' => {:name => 'Giám đốc', :position => 1, :approver_tokens => ['user:2']}
          }
        }
      }
    end

    route = ApprovalRoute.order(:id).last
    assert route.extension?
    assert_equal [nil, nil], route.steps.map(&:issue_status_id)
    assert_equal ['role:1'], route.step_at(0).approver_tokens

    # It governs extension requests, and nothing else.
    assert_equal route.id, ApprovalRoute.extension_for_issue(@issue).id
    assert_nil ApprovalRoute.for_issue(@issue)
  end

  def test_an_extension_route_step_must_name_its_approver
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    assert_no_difference 'ApprovalRoute.count' do
      post "/projects/#{identifier}/approval_routes", :params => {
        :approval_route => {
          :name => 'Thiếu người ký',
          :kind => 'extension',
          :tracker_ids => ['1'],
          :active => '1',
          :steps_attributes => {'0' => {:name => 'Ai đó', :position => 0}}
        }
      }
    end

    assert_response :success
    assert_select '#errorExplanation'
  end

  # --- adding steps to a chain ----------------------------------------------

  def test_the_route_form_offers_an_add_step_button_and_a_row_template
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    get "/projects/#{identifier}/approval_routes/new"

    assert_response :success
    assert_select 'a#approval-add-step'
    assert_select 'tbody#approval-step-rows'
    assert_select 'template#approval-step-template'
    # The clone's field names come from this placeholder, so it has to be there.
    assert_include 'approval_route[steps_attributes][__INDEX__][name]', @response.body
    assert_include "tpl.innerHTML.split('__INDEX__')", @response.body
  end

  def test_a_step_added_at_a_generated_index_is_saved
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    # What the button generates: an index nowhere near the rendered rows. Rails
    # only treats the nested hash as a collection when every key is numeric,
    # so this is the assertion that the generated names actually work.
    assert_difference 'ApprovalRoute.count', 1 do
      post "/projects/#{identifier}/approval_routes", :params => {
        :approval_route => {
          :name => 'Lưu trình bốn bước', :tracker_ids => ['1'], :active => '1',
          :steps_attributes => {
            '0' => {:name => 'Giao việc', :issue_status_id => 2, :position => 0},
            '1' => {:name => 'Nhận việc', :issue_status_id => 3, :position => 1},
            '17570000' => {:name => 'Trình ký', :issue_status_id => 4, :position => 2},
            '17570001' => {:name => 'Duyệt', :issue_status_id => 5, :position => 3}
          }
        }
      }
    end

    route = ApprovalRoute.order(:id).last
    assert_equal %w[Giao\ việc Nhận\ việc Trình\ ký Duyệt], route.steps.map(&:name)
    # Positions are renumbered in form order, so the chain runs 0..3.
    assert_equal [0, 1, 2, 3], route.steps.map(&:position)
  end

  def test_the_approver_picker_offers_the_assignee
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    get "/projects/#{identifier}/approval_routes/new"

    assert_response :success
    # The chips carry the field name; the select beside them is only the
    # source you pick from, so it deliberately posts nothing of its own.
    assert_select '.chip-picker[data-chip-name=?]',
                  'approval_route[steps_attributes][0][approver_tokens][]' do
      assert_select 'select.chip-source' do
        assert_select 'option[value=?]', 'dynamic:assignee'
        assert_select 'option[value=?]', 'role:1'
        assert_select 'option[value=?]', 'user:2'
      end
    end
  end

  def test_choosing_the_assignee_in_the_form_saves_it
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    post "/projects/#{identifier}/approval_routes", :params => {
      :approval_route => {
        :name => 'Lưu trình giao việc', :tracker_ids => ['1'], :active => '1',
        :steps_attributes => {
          '0' => {:name => 'Nhận việc', :issue_status_id => 2, :position => 0,
                  :approver_tokens => ['dynamic:assignee']},
          '1' => {:name => 'Duyệt', :issue_status_id => 3, :position => 1,
                  :approver_tokens => ['role:1']}
        }
      }
    }

    route = ApprovalRoute.order(:id).last
    assert_equal ['dynamic:assignee'], route.step_at(0).approver_tokens
    assert_equal ['role:1'], route.step_at(1).approver_tokens
  end

  # --- the chip picker ------------------------------------------------------

  def test_the_chip_picker_keeps_what_was_chosen_in_order
    Role.find(1).add_permission!(:manage_approval_routes)
    route = build_route(:tracker_ids => [1, 2], :project_id => @issue.project_id,
                        :statuses => [2, 3])
    set_step_approvers(route.step_at(0), ['user:3', 'role:1'])
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    get "/projects/#{identifier}/approval_routes/#{route.id}/edit"

    assert_response :success
    # Trackers: chosen ones stay as chips carrying the field name.
    assert_select '.chip-picker[data-chip-name=?]', 'approval_route[tracker_ids][]' do
      assert_select 'li.chip', 2
      assert_select 'li.chip input[type=hidden][value=?]', '1'
      assert_select 'li.chip input[type=hidden][value=?]', '2'
      # Order carries no meaning for trackers, so they are not draggable.
      assert_select 'li.chip[draggable]', 0
    end
    # Approvers: order is the signing order, so the chips drag.
    assert_select '.chip-picker[data-chip-name=?]',
                  'approval_route[steps_attributes][0][approver_tokens][]' do
      assert_select 'li.chip[draggable=true]', 2
    end
    chips = css_select('.chip-picker[data-chip-name="approval_route[steps_attributes][0]' \
                       '[approver_tokens][]"] li.chip')
    assert_equal ['user:3', 'role:1'], chips.pluck('data-chip-value')
  end

  def test_the_chip_picker_ships_the_reorder_and_remove_script
    Role.find(1).add_permission!(:manage_approval_routes)
    log_user('jsmith', 'jsmith')

    get "/projects/#{@issue.project.identifier}/approval_routes/new"

    assert_response :success
    assert_select 'a.chip-add[data-chip-add]', :minimum => 1
    assert_include "event.target.closest('[data-chip-remove]')", @response.body
    assert_include "list.insertBefore(dragged", @response.body
  end

  # Every chip row posts a trailing blank, so emptying one submits an empty
  # list instead of leaving the previous selection in place.
  def test_clearing_every_chip_clears_the_list
    Role.find(1).add_permission!(:manage_approval_routes)
    route = build_route(:tracker_ids => [1], :project_id => @issue.project_id,
                        :statuses => [2, 3])
    set_step_approvers(route.step_at(0), ['user:3'])
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    put "/projects/#{identifier}/approval_routes/#{route.id}", :params => {
      :approval_route => {
        :name => route.name, :tracker_ids => ['1', ''],
        :steps_attributes => {
          '0' => {:id => route.step_at(0).id, :name => 'Bước 1', :issue_status_id => 2,
                  :position => 0, :approver_tokens => ['']}
        }
      }
    }

    assert_equal [], route.reload.step_at(0).approver_tokens
    assert_equal [1], route.tracker_ids
  end

  # --- several trackers per route -------------------------------------------

  def test_a_route_can_be_saved_against_several_trackers
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    assert_difference 'ApprovalRoute.count', 1 do
      post "/projects/#{identifier}/approval_routes", :params => {
        :approval_route => {
          :name => 'Lưu trình chung', :tracker_ids => ['1', '2', ''], :active => '1',
          :steps_attributes => {
            '0' => {:name => 'Duyệt', :issue_status_id => 2, :position => 0}
          }
        }
      }
    end

    route = ApprovalRoute.order(:id).last
    assert_equal [1, 2], route.tracker_ids.sort

    get "/projects/#{identifier}/settings/approval_routes"
    assert_response :success
    assert_select 'table.list td', :text => /#{Tracker.find(1).name}/
  end

  def test_a_route_with_no_tracker_is_refused
    Role.find(1).add_permission!(:manage_approval_routes)
    log_user('jsmith', 'jsmith')

    assert_no_difference 'ApprovalRoute.count' do
      post "/projects/#{@issue.project.identifier}/approval_routes", :params => {
        :approval_route => {
          :name => 'Không có kiểu vấn đề', :tracker_ids => [''], :active => '1',
          :steps_attributes => {'0' => {:name => 'Duyệt', :issue_status_id => 2, :position => 0}}
        }
      }
    end

    assert_response :success
    assert_select '#errorExplanation'
  end

  # --- signing modes on the page --------------------------------------------

  def test_the_panel_names_every_approver_of_a_step
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    set_step_approvers(route.step_at(0), ['user:2', 'user:3'],
                       :mode => ApprovalRouteStep::ALL_MODE)
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div.approval-workflow .approval-assignee',
                  :text => /#{User.find(2).name}.+#{User.find(3).name}/
  end

  # --- deployed without its migrations ---------------------------------------

  # Copying the plugin directory and forgetting the migrations leaves the code
  # asking for columns that are not there. That used to be a 500 on this tab
  # and a chain panel that silently stopped appearing.
  def test_the_settings_tab_says_so_when_the_migrations_are_pending
    Role.find(1).add_permission!(:manage_approval_routes)
    build_route(:tracker_id => @issue.tracker_id, :project_id => @issue.project_id,
                :statuses => [2, 3])
    RedmineApprovalWorkflow::SchemaCheck.stubs(:missing).
      returns(['approval_route_steps: assign_signer'])
    log_user('jsmith', 'jsmith')

    get "/projects/#{@issue.project.identifier}/settings/approval_routes"

    assert_response :success
    # Scoped to this tab: the settings page has other tabs with tables of
    # their own, and they are none of our business.
    assert_select '#tab-content-approval_routes' do
      assert_select 'p.warning'
      assert_select 'pre', :text => /redmine:plugins:migrate/
      # Naming the missing column turns "it is broken" into "run this".
      assert_select 'p.info', :text => /assign_signer/
      # And none of the markup that would have read the missing columns.
      assert_select 'table.list', 0
    end
  end

  def test_the_settings_tab_is_normal_when_the_schema_is_current
    Role.find(1).add_permission!(:manage_approval_routes)
    log_user('jsmith', 'jsmith')

    assert_equal [], RedmineApprovalWorkflow::SchemaCheck.missing,
                 'the test database is migrated, so nothing should be flagged'

    get "/projects/#{@issue.project.identifier}/settings/approval_routes"

    assert_response :success
    assert_select 'pre', :text => /redmine:plugins:migrate/, :count => 0
    assert_select "a[href=?]", "/projects/#{@issue.project.identifier}/approval_routes/new"
  end

  # --- signing out of turn ----------------------------------------------------

  def test_the_panel_offers_a_button_on_a_step_that_can_be_signed_out_of_turn
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(1).update!(:allow_skip => true)
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'form[action=?]',
                  "/issues/#{@issue.id}/approvals?decision=approve&step_id=#{route.step_at(1).id}"
    assert_select 'div.approval-workflow .approval-skip-button', 1
  end

  def test_no_such_button_when_the_step_is_not_skippable
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'form[action*=?]', "step_id=#{route.step_at(1).id}", 0
  end

  # A step jumped over reads "skipped", not "signed" -- the chain is an audit
  # trail before it is a progress bar.
  def test_a_jumped_step_shows_as_skipped_not_signed
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(1).update!(:allow_skip => true)
    log_user('jsmith', 'jsmith')

    post "/issues/#{@issue.id}/approvals",
         :params => {:decision => 'approve', :step_id => route.step_at(1).id}
    assert_redirected_to "/issues/#{@issue.id}"

    get "/issues/#{@issue.id}"
    assert_response :success
    assert_select 'div.approval-workflow li.approval-step-skipped', 1
    assert_select 'div.approval-workflow li.approval-step-done', 1
  end

  def test_the_route_form_offers_the_skip_checkbox
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    get "/projects/#{identifier}/approval_routes/new"
    assert_response :success
    assert_select 'input[type=checkbox][name=?]',
                  'approval_route[steps_attributes][0][allow_skip]'

    get "/projects/#{identifier}/approval_routes/new?kind=extension"
    assert_response :success
    assert_select 'input[type=checkbox][name=?]',
                  'approval_route[steps_attributes][0][allow_skip]', 0
  end

  def test_the_approver_picker_offers_the_author
    Role.find(1).add_permission!(:manage_approval_routes)
    log_user('jsmith', 'jsmith')

    get "/projects/#{@issue.project.identifier}/approval_routes/new"

    assert_response :success
    assert_select 'select.chip-source' do
      assert_select 'option[value=?]', 'dynamic:author'
      assert_select 'option[value=?]', 'dynamic:assignee'
    end
  end

  # --- where the panel sits on the page --------------------------------------

  # The point of the move: read the issue, write your note, then sign. So the
  # panel has to come after the history and after the note field, not under the
  # description where it used to be.
  def test_the_panel_sits_below_the_history_and_the_note_field
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    body = @response.body
    panel = body.index('class="approval-workflow box"')
    assert panel, 'the panel must be on the page'
    assert panel > body.index('id="history"'), 'the panel belongs below the history'
    assert panel > body.index('id="update"'), 'and below the note field'
    assert panel > body.index('id="issue_description_wiki"'),
           'not under the description, where it used to be'
  end

  def test_the_panel_is_inside_the_content_area
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div#content div#approval-issue-panel div.approval-workflow'
  end

  # The "other formats" line closes issues/show.html.erb, and the panel renders
  # after the whole page, so it lands below it. There is no hook between the
  # two; the script lifts the panel above that line. Pin both halves: the one
  # wrapper that gets moved, and the core element it is moved in front of.
  def test_the_panel_is_lifted_above_the_other_formats_line
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div#approval-issue-panel', 1
    assert_select '#content p.other-formats', 1, 'core still renders the line we move above'
    assert_include "document.querySelector('#content p.other-formats')", @response.body
    assert_include "formats.parentNode.insertBefore(panel, formats)", @response.body
  end

  def test_no_empty_wrapper_when_there_is_nothing_to_show
    Role.find(1).remove_permission!(:view_approval_workflow, :extend_issue_due_date)
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div#approval-issue-panel', 0
  end

  # The hook it now uses fires on every page, so the guard has to hold.
  def test_the_panel_stays_off_other_pages
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    ["/projects/#{@issue.project.identifier}",
     "/issues",
     "/issues/#{@issue.id}/time_entries/new",
     "/issues/#{@issue.id}/edit"].each do |path|
      get path
      assert_select 'div.approval-workflow', 0,
                    "the panel must not render on #{path}"
      assert_select 'div.issue-extensions', 0,
                    "nor the extension box on #{path}"
    end
  end

  # Everything this plugin renders comes from a layout hook, so anything it
  # raises would take the whole page down -- and for the bell, every page on
  # the instance. It must cost the panel, and nothing else.
  def test_a_broken_panel_does_not_take_the_issue_page_down
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    Issue.any_instance.stubs(:approval_route?).raises(StandardError, 'boom')
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div#content'
    assert_select 'div.approval-workflow', 0
  end

  # The bell renders on EVERY page. A failure there used to 500 the whole
  # instance for everybody, which is far worse than losing the bell.
  def test_a_broken_bell_does_not_take_every_page_down
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    RedmineApprovalWorkflow::PendingApprovals.stubs(:for_user).raises(StandardError, 'boom')
    log_user('jsmith', 'jsmith')

    ['/', "/projects/#{@issue.project.identifier}", "/issues/#{@issue.id}"].each do |path|
      get path
      assert_response :success, "#{path} must survive a broken bell"
    end
    assert_select '#approval-bell', 0
  end

  # --- handing the issue over ------------------------------------------------

  def test_the_form_offers_the_handover_checkboxes_on_an_issue_route
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    get "/projects/#{identifier}/approval_routes/new"
    assert_response :success
    assert_select 'input[type=checkbox][name=?]',
                  'approval_route[steps_attributes][0][assign_signer]'
    assert_select 'input[type=checkbox][name=?]',
                  'approval_route[steps_attributes][0][assign_author]'

    # An extension decides a date; it has no business moving the work or
    # rewriting who raised the issue, so neither is offered there.
    get "/projects/#{identifier}/approval_routes/new?kind=extension"
    assert_response :success
    assert_select 'input[type=checkbox][name=?]',
                  'approval_route[steps_attributes][0][assign_signer]', 0
    assert_select 'input[type=checkbox][name=?]',
                  'approval_route[steps_attributes][0][assign_author]', 0
  end

  def test_the_handover_option_is_saved_and_shown
    Role.find(1).add_permission!(:manage_approval_routes)
    identifier = @issue.project.identifier
    log_user('jsmith', 'jsmith')

    post "/projects/#{identifier}/approval_routes", :params => {
      :approval_route => {
        :name => 'Lưu trình giao việc', :tracker_ids => ['1'], :active => '1',
        :steps_attributes => {
          '0' => {:name => 'Giao việc', :issue_status_id => 2, :position => 0,
                  :assign_signer => '0', :assign_author => '1'},
          '1' => {:name => 'Nhận việc', :issue_status_id => 3, :position => 1,
                  :assign_signer => '1', :assign_author => '0'}
        }
      }
    }

    route = ApprovalRoute.order(:id).last
    assert route.step_at(0).assigns_author?
    assert_not route.step_at(0).assigns_signer?
    assert route.step_at(1).assigns_signer?
    assert_not route.step_at(1).assigns_author?

    get "/projects/#{identifier}/settings/approval_routes"
    assert_response :success
    # One badge per effect, so the listing says which step does what.
    assert_select 'span.approval-assign-badge', 2
  end

  def test_the_panel_marks_the_step_that_hands_the_issue_over
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(0).update!(:assign_signer => true)
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div.approval-workflow span.approval-assign-badge', 1
  end

  # The bell posts to the same action, so the handover happens there too.
  def test_quick_signing_from_the_bell_hands_the_issue_over
    route = build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    route.step_at(0).update!(:assign_signer => true)
    @issue.update_columns(:assigned_to_id => nil)
    log_user('jsmith', 'jsmith')

    post "/issues/#{@issue.id}/approvals?decision=approve"

    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal 2, @issue.reload.assigned_to_id
  end

  # --- the floating header --------------------------------------------------

  # Core renders #sticky-issue-header and shows it once the subject scrolls out
  # of view; the plugin appends the step and its buttons to it. If a later
  # Redmine drops or renames that element, this is what says so.
  def test_core_still_provides_the_sticky_issue_header
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div#sticky-issue-header'
  end

  def test_sticky_header_gets_the_step_and_its_sign_button
    build_route(:tracker_id => @issue.tracker_id, :statuses => [2, 3])
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div#approval-sticky-staging[hidden] .approval-sticky' do
      assert_select '.approval-sticky-step', :text => /#{@issue.approval_route.step_at(0).name}/
      assert_select 'form[action=?]', "/issues/#{@issue.id}/approvals?decision=approve"
    end
    assert_include "document.getElementById('sticky-issue-header')", @response.body
  end

  def test_sticky_header_offers_the_extend_button
    Role.find(1).add_permission!(:extend_issue_due_date)
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select ".approval-sticky a[href=?]", "/issues/#{@issue.id}/extensions/new"
  end

  def test_sticky_header_offers_a_pending_extension_instead_of_a_new_one
    build_extension_route(:approvers => ['user:2'])
    extension = create_pending_extension
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select '.approval-sticky form[action=?]',
                  "/issues/#{@issue.id}/extensions/#{extension.id}/approve"
    assert_select ".approval-sticky a[href=?]", "/issues/#{@issue.id}/extensions/new", 0
  end

  def test_sticky_header_carries_nothing_for_a_user_who_cannot_act
    Role.find(1).remove_permission!(:view_approval_workflow, :extend_issue_due_date)
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select '.approval-sticky', 0
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

  # --- extension chains -----------------------------------------------------

  def test_issue_page_shows_a_pending_extension_with_its_chain_and_buttons
    build_extension_route
    extension = create_pending_extension
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div.extension-request' do
      assert_select 'ol.extension-steps li', 2
      assert_select 'li.approval-step-current', 1
      assert_select '.extension-status-pending'
    end
    assert_select "form[action=?]",
                  "/issues/#{@issue.id}/extensions/#{extension.id}/approve"
    assert_select "form[action=?]",
                  "/issues/#{@issue.id}/extensions/#{extension.id}/reject"
  end

  def test_the_sign_buttons_are_hidden_from_somebody_else
    build_extension_route(:approvers => ['user:3'])
    extension = create_pending_extension
    log_user('jsmith', 'jsmith')

    get "/issues/#{@issue.id}"

    assert_response :success
    assert_select 'div.extension-request'
    assert_select "form[action=?]",
                  "/issues/#{@issue.id}/extensions/#{extension.id}/approve", 0
  end

  def test_bell_lists_extension_requests_waiting_on_the_user
    build_extension_route
    create_pending_extension
    log_user('jsmith', 'jsmith')

    get '/'

    assert_response :success
    assert_select '#approval-bell .approval-bell-extensions' do
      assert_select '.approval-bell-item', 1
    end
    assert_select '#approval-bell span.approval-bell-count', :text => '1'
  end

  def test_pending_page_lists_extension_requests
    build_extension_route
    extension = create_pending_extension
    log_user('jsmith', 'jsmith')

    get '/pending_approvals'

    assert_response :success
    assert_select "form[action=?]",
                  "/issues/#{@issue.id}/extensions/#{extension.id}/approve"
  end

  # The whole point of the chain, end to end: request, first signature, second
  # signature, and only then does the deadline move.
  def test_full_extension_round_trip
    build_extension_route
    due = @issue.start_date + 30
    @issue.update_columns(:due_date => due)
    set_plugin_settings('max_extension_days' => '30')
    log_user('jsmith', 'jsmith')

    post "/issues/#{@issue.id}/extensions",
         :params => {:issue_extension => {:new_due_date => (due + 10).to_s, :reason => 'Chờ vật tư'}}
    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal due, @issue.reload.due_date, 'requesting must not move the deadline'

    extension = IssueExtension.order(:id).last
    post "/issues/#{@issue.id}/extensions/#{extension.id}/approve"
    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal due, @issue.reload.due_date, 'one of two signatures is not enough'

    # The second step belongs to user 3, a Developer on this project.
    Role.find(2).add_permission!(:extend_issue_due_date)
    post '/logout'
    log_user('dlopper', 'foo')
    post "/issues/#{@issue.id}/extensions/#{extension.id}/approve"
    assert_redirected_to "/issues/#{@issue.id}"

    assert extension.reload.approved?
    assert_equal due + 10, @issue.reload.due_date
  end

  def test_bell_drops_the_extension_once_it_is_decided
    build_extension_route(:approvers => ['user:2'])
    extension = create_pending_extension
    log_user('jsmith', 'jsmith')

    get '/'
    assert_select '#approval-bell .approval-bell-extensions .approval-bell-item', 1

    post "/issues/#{@issue.id}/extensions/#{extension.id}/reject"

    get '/'
    assert_response :success
    assert_select '#approval-bell .approval-bell-extensions', 0
    assert_select '#approval-bell .approval-bell-empty'
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

  private

  def create_pending_extension(days: 10)
    due = @issue.start_date + 30
    @issue.update_columns(:due_date => due)
    @issue.reload
    IssueExtension.create!(:issue => @issue, :user_id => 2,
                           :approval_route => ApprovalRoute.extension_for_issue(@issue),
                           :status => IssueExtension::PENDING,
                           :previous_due_date => due,
                           :new_due_date => due + days,
                           :reason => 'Chờ vật tư')
  end
end

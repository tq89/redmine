# frozen_string_literal: true

require_relative '../test_helper'

class IssueExtensionTest < ActiveSupport::TestCase
  include RedmineApprovalWorkflow::TestFixtures

  def setup
    User.current = nil
    IssueExtension.delete_all
    @issue = Issue.find(1)
    @issue.update_columns(:due_date => Date.new(2026, 1, 10))
    @issue.reload
    set_plugin_settings('max_extension_days' => '30')
  end

  def build_extension(new_due_date, attrs = {})
    IssueExtension.new(
      {:issue => @issue, :user_id => 2,
       :previous_due_date => @issue.due_date,
       :new_due_date => new_due_date}.merge(attrs)
    )
  end

  def test_extension_within_limit_is_valid
    extension = build_extension(Date.new(2026, 1, 20))

    assert extension.valid?, extension.errors.full_messages.join(', ')
    assert_equal 10, extension.days
  end

  def test_extension_exactly_at_limit_is_valid
    assert build_extension(Date.new(2026, 2, 9)).valid?, 'exactly 30 days must pass'
  end

  def test_extension_beyond_limit_is_rejected
    extension = build_extension(Date.new(2026, 2, 10))

    assert_not extension.valid?
    assert_includes extension.errors.attribute_names, :new_due_date
  end

  def test_zero_limit_means_no_limit
    set_plugin_settings('max_extension_days' => '0')

    assert build_extension(Date.new(2027, 1, 1)).valid?
  end

  def test_new_due_date_must_be_after_current_due_date
    assert_not build_extension(Date.new(2026, 1, 10)).valid?
    assert_not build_extension(Date.new(2026, 1, 1)).valid?
  end

  def test_limit_is_measured_from_today_when_issue_has_no_due_date
    @issue.update_columns(:due_date => nil)
    extension = IssueExtension.new(
      :issue => @issue.reload, :user_id => 2,
      :previous_due_date => nil,
      :new_due_date => User.current.today + 10
    )

    assert extension.valid?, extension.errors.full_messages.join(', ')
    assert_equal 10, extension.days
  end

  def test_reason_can_be_required_by_setting
    set_plugin_settings('require_extension_reason' => '1')
    extension = build_extension(Date.new(2026, 1, 20))

    assert_not extension.valid?
    assert_includes extension.errors.attribute_names, :reason

    extension.reason = 'Chờ vật tư'
    assert extension.valid?
  end

  def test_max_count_blocks_further_extensions
    set_plugin_settings('max_extension_count' => '1')
    User.current = User.find(2)

    IssueExtension.create!(:issue => @issue, :user_id => 2,
                           :previous_due_date => @issue.due_date,
                           :new_due_date => @issue.due_date + 5)

    assert_equal 1, @issue.reload.extension_count
    assert_not @issue.extendable_by?(User.find(2))
  end
end

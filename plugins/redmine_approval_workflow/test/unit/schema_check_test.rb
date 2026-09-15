# frozen_string_literal: true

require_relative '../test_helper'

# The check that catches "plugin copied, migrations forgotten".
class SchemaCheckTest < ActiveSupport::TestCase
  Check = RedmineApprovalWorkflow::SchemaCheck
  FakeColumn = Struct.new(:name)

  # A connection that reports exactly the columns asked for. +overrides+ names
  # tables whose column list should differ from what the check expects.
  def fake_connection(overrides = {})
    connection = mock('connection')
    connection.stubs(:table_exists?).returns(true)
    Check::REQUIRED_COLUMNS.each_key do |table|
      present = overrides.fetch(table, Check::REQUIRED_COLUMNS[table])
      connection.stubs(:columns).with(table).returns(present.map {|name| FakeColumn.new(name)})
    end
    connection
  end

  # The list is hand-written, so this is what stops a typo in it from hiding
  # the settings tab on an install that is perfectly up to date.
  def test_every_required_column_exists_in_a_migrated_database
    assert_equal [], Check.missing,
                 'REQUIRED_COLUMNS names something this database does not have'
    assert_not Check.pending?
  end

  def test_nothing_is_missing_when_every_column_is_there
    ActiveRecord::Base.stubs(:connection).returns(fake_connection)

    assert_equal [], Check.missing
    assert_not Check.pending?
  end

  def test_it_reports_a_column_that_is_not_there
    ActiveRecord::Base.stubs(:connection).
      returns(fake_connection('approval_route_steps' => %w[approval_mode]))

    assert Check.pending?
    assert_equal 1, Check.missing.size
    assert_includes Check.missing.first, 'approval_route_steps'
    assert_includes Check.missing.first, 'assign_signer'
  end

  def test_it_reports_a_table_that_is_not_there
    connection = fake_connection
    connection.stubs(:table_exists?).with('approval_route_approvers').returns(false)
    ActiveRecord::Base.stubs(:connection).returns(connection)

    assert Check.pending?
    assert_includes Check.missing.join(' '), 'approval_route_approvers'
  end

  # The check runs inside a view; it must never be the thing that breaks it.
  def test_a_failing_check_reports_nothing_missing_rather_than_raising
    ActiveRecord::Base.stubs(:connection).raises(StandardError, 'no database')

    assert_equal [], Check.missing
    assert_not Check.pending?
  end
end

# frozen_string_literal: true

# One deadline extension ("gia hạn"). The number of days an extension may add
# is capped by the administrator through the plugin settings.
class IssueExtension < ApplicationRecord
  belongs_to :issue
  belongs_to :user
  belongs_to :journal, :optional => true

  attr_accessor :skip_limit_validation

  validates :issue_id, :user_id, :presence => true
  validates :new_due_date, :presence => true
  validate  :validate_new_due_date

  scope :sorted, lambda {order(:id)}

  class << self
    # Maximum number of days a single extension may add. 0 or blank means
    # "no limit".
    def max_days
      setting('max_extension_days').to_i
    end

    # Maximum number of extensions allowed per issue. 0 or blank means
    # "no limit".
    def max_count
      setting('max_extension_count').to_i
    end

    def reason_required?
      setting('require_extension_reason').to_s == '1'
    end

    def setting(key)
      values = Setting.plugin_redmine_approval_workflow
      values.is_a?(Hash) ? values[key] : nil
    end
  end

  # The date an extension is measured from: the current deadline, or today when
  # the issue has no deadline yet.
  def base_date
    previous_due_date || User.current.today
  end

  private

  def validate_new_due_date
    return if new_due_date.blank?

    if new_due_date <= base_date
      errors.add(:new_due_date, :must_be_after_base_date)
      return
    end

    self.days = (new_due_date - base_date).to_i

    limit = self.class.max_days
    if !skip_limit_validation && limit > 0 && days > limit
      errors.add(:new_due_date, :exceeds_max_extension_days, :count => limit)
    end

    if self.class.reason_required? && reason.blank?
      errors.add(:reason, :blank)
    end
  end
end

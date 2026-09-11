# frozen_string_literal: true

# One step of an approval chain. Approving it moves the issue into
# +issue_status+, which is also what decides who is allowed to sign it.
class ApprovalRouteStep < ApplicationRecord
  belongs_to :approval_route, :inverse_of => :steps
  belongs_to :issue_status

  validates :name, :presence => true, :length => {:maximum => 255}
  validates :issue_status_id, :presence => true
  validates :position, :numericality => {:only_integer => true, :greater_than_or_equal_to => 0}

  def to_s
    name.to_s
  end
end

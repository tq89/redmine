# frozen_string_literal: true

module RedmineApprovalWorkflow
  module ProjectPatch
    def self.included(base)
      base.class_eval do
        has_many :approval_routes, lambda {order(:name, :id)}, :dependent => :destroy
      end
    end
  end
end

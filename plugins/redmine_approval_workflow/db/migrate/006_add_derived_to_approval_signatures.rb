# frozen_string_literal: true

class AddDerivedToApprovalSignatures < ActiveRecord::Migration[8.1]
  def change
    # True when the row was reconciled from the issue's status history rather
    # than produced by somebody actually pressing the sign button. Keeping the
    # two apart matters: an approval chain is an audit trail, and a status
    # change made through the ordinary issue form is not a signature.
    add_column :approval_signatures, :derived, :boolean, :null => false, :default => false
  end
end

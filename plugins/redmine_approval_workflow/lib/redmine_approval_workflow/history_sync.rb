# frozen_string_literal: true

module RedmineApprovalWorkflow
  # Reconciles an approval chain with the status the issue is actually in.
  #
  # A chain records progress in approval_signatures, but an issue reaches a
  # status in other ways too: it was created before the route existed, somebody
  # used the ordinary issue form, an import set it. Left alone, such an issue
  # shows an untouched chain while sitting in a status the chain says it has not
  # reached yet.
  #
  # This walks the issue's status history -- the creation status, then every
  # journal that changed status_id -- and matches it against the steps in order,
  # recording who made each move and when. Entries it creates are flagged
  # derived: they are evidence of a status change, not of a signature, and the
  # interface says so.
  module HistorySync
    module_function

    def enabled?
      values = Setting.plugin_redmine_approval_workflow
      !values.is_a?(Hash) || values['sync_status_from_history'].to_s != '0'
    end

    # Fills the chain forward from where it currently stands. Idempotent: it
    # never touches a step that already has a signature, so running it twice, or
    # after somebody has signed for real, changes nothing.
    #
    # Returns the signatures it created.
    def backfill(issue, force: false)
      return [] unless force || enabled?
      return [] unless issue.approval_route?
      return [] if issue.approval_completed?

      route = issue.approval_route
      signatures = issue.approval_signatures.to_a
      position = issue.approval_position
      created = []

      # A journal that a signature already points at has been accounted for.
      # Matching on the id rather than on the timestamp matters: the controller
      # writes the journal and the signature within the same transaction, so
      # their times can be equal to the stored precision.
      claimed = signatures.filter_map(&:journal_id).to_set
      # Entries with no journal of their own (the creation status) are ruled out
      # by time instead.
      after = signatures.last&.created_at

      timeline(issue).each do |entry|
        break if position >= route.step_count
        next if entry[:journal] && claimed.include?(entry[:journal].id)
        next if entry[:journal].nil? && after && entry[:at] && entry[:at] <= after

        step = route.step_at(position)
        next unless step && entry[:status_id] == step.issue_status_id

        created << record(issue, route, step, position, entry)
        position += 1
      end

      # The association was read before these rows existed, so anything asking
      # the issue for its position again would still see the old answer.
      issue.approval_signatures.reset if created.any?
      created
    end

    # Every status the issue is known to have held, oldest first, each with who
    # put it there and when.
    def timeline(issue)
      journals = status_journals(issue)
      entries = []

      # The status the issue was created in leaves no journal of its own; it is
      # the old_value of the first status change, or the current status when
      # there has never been one.
      initial = journals.first ? status_detail(journals.first)&.old_value.to_i : issue.status_id
      if initial.to_i > 0
        entries << {:status_id => initial.to_i, :user_id => issue.author_id,
                    :at => issue.created_on, :journal => nil}
      end

      journals.each do |journal|
        detail = status_detail(journal)
        next if detail.nil?

        entries << {:status_id => detail.value.to_i,
                    :old_status_id => detail.old_value.to_i,
                    :user_id => journal.user_id,
                    :at => journal.created_on,
                    :journal => journal}
      end

      entries
    end

    def status_journals(issue)
      Journal.
        joins(:details).
        where(:journalized_type => 'Issue', :journalized_id => issue.id).
        where(:journal_details => {:property => 'attr', :prop_key => 'status_id'}).
        preload(:details).
        order(:created_on, :id).
        to_a
    end

    def status_detail(journal)
      journal.details.detect {|d| d.property == 'attr' && d.prop_key == 'status_id'}
    end

    def record(issue, route, step, position, entry)
      ApprovalSignature.create!(
        :issue_id => issue.id,
        :approval_route_id => route.id,
        :approval_route_step_id => step.id,
        :step_position => position,
        :step_name => step.name,
        :user_id => entry[:user_id] || issue.author_id,
        :action => ApprovalSignature::APPROVED,
        :from_status_id => entry[:old_status_id],
        :to_status_id => entry[:status_id],
        :journal_id => entry[:journal]&.id,
        :derived => true,
        :created_at => entry[:at] || issue.created_on
      )
    end
  end
end

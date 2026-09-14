# frozen_string_literal: true

# Loaded automatically: lib/tasks/redmine.rake globs plugins/*/lib/tasks/**/*.rake.
namespace :redmine do
  namespace :approval_workflow do
    desc <<~DESC
      Reconcile approval chains with the status issues are actually in.

      Walks each issue's status history and fills the chain forward, recording
      who made each move and when. Rows it creates are marked as derived from
      history, never as signatures. Safe to re-run: steps that already have an
      entry are left alone.

      Options:
        PROJECT=identifier   limit to one project
        DRY_RUN=1            report what would be filled, write nothing

      Example:
        bundle exec rake redmine:approval_workflow:backfill RAILS_ENV=production
    DESC
    task :backfill => :environment do
      dry_run = ENV['DRY_RUN'].present?
      # select rather than pluck: one query with a subselect, not two.
      scope = Issue.where(
        :tracker_id => ApprovalRoute.active.of_kind(ApprovalRoute::ISSUE_KIND).select(:tracker_id)
      )
      if ENV['PROJECT'].present?
        project = Project.find_by_identifier(ENV['PROJECT']) || Project.find_by_id(ENV['PROJECT'])
        abort "Unknown project #{ENV['PROJECT']}" if project.nil?

        scope = scope.where(:project_id => project.id)
      end

      issues = 0
      rows = 0
      scope.includes(:approval_signatures).find_each do |issue|
        next unless issue.approval_route?

        created = []
        if dry_run
          # Assigned before the rollback, so the report survives while the rows
          # themselves are discarded.
          ApprovalSignature.transaction do
            created = RedmineApprovalWorkflow::HistorySync.backfill(issue, :force => true)
            raise ActiveRecord::Rollback
          end
        else
          created = RedmineApprovalWorkflow::HistorySync.backfill(issue, :force => true)
        end
        next if created.empty?

        issues += 1
        rows += created.size
        puts "  ##{issue.id} #{issue.subject.to_s.truncate(60)} -> " \
             "#{created.map(&:step_name).join(', ')}"
      end

      if dry_run
        puts "Would fill #{rows} step(s) across #{issues} issue(s)."
      else
        puts "Filled #{rows} step(s) across #{issues} issue(s)."
      end
    end
  end
end

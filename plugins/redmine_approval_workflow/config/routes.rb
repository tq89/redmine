# frozen_string_literal: true

get 'pending_approvals', :to => 'pending_approvals#index', :as => 'pending_approvals'

resources :projects, :only => [] do
  resources :approval_routes
end

resources :issues, :only => [] do
  resources :approvals, :only => [:index, :new, :create]
  resources :issue_extensions, :only => [:new, :create], :path => 'extensions'
end

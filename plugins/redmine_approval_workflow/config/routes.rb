# frozen_string_literal: true

get 'pending_approvals', :to => 'pending_approvals#index', :as => 'pending_approvals'

resources :approval_routes do
  member do
    post :move_step
  end
end

resources :issues, :only => [] do
  resources :approvals, :only => [:index, :new, :create]
  resources :issue_extensions, :only => [:new, :create], :path => 'extensions'
end

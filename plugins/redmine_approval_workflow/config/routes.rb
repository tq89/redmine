# frozen_string_literal: true

resources :approval_routes do
  member do
    post :move_step
  end
end

resources :issues, :only => [] do
  resources :approvals, :only => [:index, :new, :create]
  resources :issue_extensions, :only => [:new, :create], :path => 'extensions'
end

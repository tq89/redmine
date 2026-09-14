# frozen_string_literal: true

# Redmine evaluates this inside Rails.application.routes.draw, after every core
# route and with no catch-all in between, so a plugin route resolves normally.

get 'sw.:format', :to => 'service_worker#show', :constraints => {:format => 'js'}

get 'pending_approvals', :to => 'pending_approvals#index', :as => 'pending_approvals'

resources :projects, :only => [] do
  resources :approval_routes
end

resources :issues, :only => [] do
  resources :approvals, :only => [:index, :new, :create] do
    collection do
      post :sync
    end
  end
  resources :issue_extensions, :only => [:new, :create], :path => 'extensions' do
    member do
      post :approve
      post :reject
    end
  end
end

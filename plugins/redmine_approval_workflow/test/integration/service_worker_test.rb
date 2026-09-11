# frozen_string_literal: true

require_relative '../test_helper'

# /sw.js is served entirely from the plugin: a plugin route, a plugin
# controller and a plugin view. Nothing in Redmine core is patched for it.
class ServiceWorkerTest < Redmine::IntegrationTest
  def test_service_worker_unregisters_itself
    get '/sw.js'

    assert_response :success
    assert_equal 'text/javascript', @response.media_type
    assert_equal 'no-store', @response.headers['Cache-Control']
    assert_include 'self.registration.unregister()', @response.body
    assert_include 'caches.delete', @response.body
  end

  # Fetched before anyone signs in, and a browser reads a login redirect as a
  # broken worker script.
  def test_service_worker_is_served_when_login_is_required
    with_settings :login_required => '1' do
      get '/sw.js'

      assert_response :success
      assert_equal 'text/javascript', @response.media_type
    end
  end

  # protect_from_forgery's verify_same_origin_request rejects a text/javascript
  # response to a plain GET; without the skip this returns 422, not 200.
  def test_service_worker_survives_the_cross_origin_javascript_guard
    get '/sw.js', :headers => {'Sec-Fetch-Dest' => 'serviceworker',
                               'Sec-Fetch-Mode' => 'same-origin'}

    assert_response :success
    assert_not_equal 422, @response.status
  end

  def test_service_worker_does_not_respond_to_other_formats
    %w(sw.json sw).each do |path|
      get "/#{path}"
      assert_response :not_found
    end
  end
end

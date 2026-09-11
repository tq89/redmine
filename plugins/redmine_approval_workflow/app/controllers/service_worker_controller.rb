# frozen_string_literal: true

# Serves a self-destructing service worker at /sw.js.
#
# Redmine ships no service worker, but a browser that registered one under a
# previous deployment of the same origin keeps requesting /sw.js on every
# navigation. A 404 does not unregister it, so it stays in control of the site
# and may keep serving assets from its own caches. Answering with a worker that
# drops those caches and unregisters itself lets such clients recover on their
# own, without their users having to clear anything by hand.
class ServiceWorkerController < ApplicationController
  # A service worker is fetched before anyone is signed in, and the browser
  # follows no redirects for it: a login redirect would be read as a broken
  # worker script.
  skip_before_action :check_if_login_required, :check_password_change,
                     :check_twofa_activation
  # protect_from_forgery appends verify_same_origin_request, which rejects any
  # text/javascript response to a GET without X-Requested-With. That is exactly
  # how a service worker is fetched, so the guard has to let this one through.
  skip_after_action :verify_same_origin_request

  def show
    response.headers['Cache-Control'] = 'no-store'
    render :layout => false, :content_type => 'text/javascript'
  end
end

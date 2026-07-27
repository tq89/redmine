# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class WelcomeController < ApplicationController
  self.main_menu = false

  skip_before_action :check_if_login_required, only: [:robots, :service_worker]
  skip_before_action :check_password_change, :check_twofa_activation, only: [:service_worker]
  # A service worker is fetched as a plain GET with no X-Requested-With header,
  # which the guard against cross-origin <script> embedding would reject.
  skip_after_action :verify_same_origin_request, only: [:service_worker]

  def index
    @news = News.latest User.current
  end

  def robots
    @projects = Project.visible(User.anonymous) unless Setting.login_required?
    render :layout => false, :content_type => 'text/plain'
  end

  # Redmine ships no service worker, but a browser that registered one under a
  # previous deployment of the same origin keeps requesting /sw.js on every
  # navigation. A 404 does not unregister it, so it stays in control of the site
  # and may keep serving assets from its own caches. Answering with a worker that
  # drops those caches and unregisters itself lets such clients recover on their
  # own, without the users having to clear anything by hand.
  def service_worker
    response.headers['Cache-Control'] = 'no-store'
    render :layout => false, :content_type => 'text/javascript'
  end
end

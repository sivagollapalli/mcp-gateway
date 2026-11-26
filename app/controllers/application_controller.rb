class ApplicationController < ActionController::Base
  allow_browser versions: :modern if respond_to?(:allow_browser)
  before_action :require_login
  helper_method :current_user

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id]
  end

  def require_login
    redirect_to new_session_path, alert: "Please sign in." unless current_user
  end

  # Simple offset pagination. Returns [records, page, total_pages].
  def paginate(scope, per: 25)
    page = [ params[:page].to_i, 1 ].max
    total_pages = [ (scope.count / per.to_f).ceil, 1 ].max
    page = [ page, total_pages ].min
    [ scope.limit(per).offset((page - 1) * per), page, total_pages ]
  end
end

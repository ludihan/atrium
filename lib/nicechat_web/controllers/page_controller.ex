defmodule NicechatWeb.PageController do
  use NicechatWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

defmodule BeamWatchWeb.PageController do
  use BeamWatchWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

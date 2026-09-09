defmodule AtriumWeb.ChatLiveTest do
  use AtriumWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Atrium.Chat

  setup do
    {:ok, general} = Chat.get_or_create_channel("general")
    %{general: general}
  end

  test "prompts for a nick before talking", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "form[phx-submit=set_nick]")
    assert has_element?(view, "input#chat-body[disabled]")
  end

  test "setting a nick unlocks the composer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=set_nick]", join: %{nick: "trinity"})
    |> render_submit()

    refute has_element?(view, "form[phx-submit=set_nick]")
    assert has_element?(view, "input#chat-body:not([disabled])")
  end

  test "messages are broadcast to other clients in the channel", %{conn: conn} do
    {:ok, one, _} = live(conn, ~p"/")
    {:ok, two, _} = live(build_conn(), ~p"/")

    for {view, nick} <- [{one, "neo"}, {two, "morpheus"}] do
      view
      |> form("form[phx-submit=set_nick]", join: %{nick: nick})
      |> render_submit()
    end

    one
    |> form("form[phx-submit=send]", chat: %{body: "there is no spoon"})
    |> render_submit()

    assert render(two) =~ "there is no spoon"
    assert render(one) =~ "there is no spoon"
  end

  test "/join creates and switches to a new channel", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=set_nick]", join: %{nick: "cypher"})
    |> render_submit()

    view
    |> form("form[phx-submit=send]", chat: %{body: "/join #zion"})
    |> render_submit()

    assert has_element?(view, "section header", "#zion")
    assert Chat.get_channel_by_name("zion")
  end

  test "/me posts an emote", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=set_nick]", join: %{nick: "tank"})
    |> render_submit()

    view
    |> form("form[phx-submit=send]", chat: %{body: "/me reloads"})
    |> render_submit()

    assert render(view) =~ "* tank reloads"
  end
end

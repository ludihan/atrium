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

  test "mentioning a nick renders a styled token and highlights the message for them", %{
    conn: conn
  } do
    {:ok, sender, _} = live(conn, ~p"/")

    sender
    |> form("form[phx-submit=set_nick]", join: %{nick: "neo"})
    |> render_submit()

    sender
    |> form("form[phx-submit=send]", chat: %{body: "hey @trinity, catch"})
    |> render_submit()

    assert render(sender) =~ "@trinity"
    refute render(sender) =~ "bg-primary/10 px-2"

    {:ok, viewer, _} = live(conn, ~p"/")

    viewer
    |> form("form[phx-submit=set_nick]", join: %{nick: "trinity"})
    |> render_submit()

    assert render(viewer) =~ "bg-primary/10 px-2"
  end

  test "replying to a message quotes it and links the reply", %{conn: conn, general: general} do
    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=set_nick]", join: %{nick: "neo"})
    |> render_submit()

    view
    |> form("form[phx-submit=send]", chat: %{body: "what is the matrix?"})
    |> render_submit()

    [original] = Chat.list_recent_messages(general)

    view
    |> element("button[phx-click=reply][phx-value-id='#{original.id}']")
    |> render_click()

    assert has_element?(view, "[phx-click=cancel_reply]")
    assert render(view) =~ "replying to"

    view
    |> form("form[phx-submit=send]", chat: %{body: "let me show you"})
    |> render_submit()

    refute has_element?(view, "[phx-click=cancel_reply]")
    assert render(view) =~ "what is the matrix?"

    [_original, reply] = Chat.list_recent_messages(general)
    assert reply.reply_to_id == original.id

    assert has_element?(
             view,
             "button[phx-hook='AtriumWeb.ChatLive.JumpToReply'][data-target-id='messages-#{original.id}']"
           )
  end

  test "lists who's online in the channel you're currently viewing", %{conn: conn} do
    {:ok, one, _} = live(conn, ~p"/")
    {:ok, two, _} = live(build_conn(), ~p"/")

    assert element(one, "#online-users") |> render() =~ "nobody here yet"

    one |> form("form[phx-submit=set_nick]", join: %{nick: "neo"}) |> render_submit()
    _ = :sys.get_state(one.pid)

    assert element(one, "#online-users") |> render() =~ "neo"
    refute element(one, "#online-users") |> render() =~ "trinity"

    two |> form("form[phx-submit=set_nick]", join: %{nick: "trinity"}) |> render_submit()
    _ = :sys.get_state(one.pid)

    online = element(one, "#online-users") |> render()
    assert online =~ "neo"
    assert online =~ "trinity"

    two
    |> form("form[phx-submit=send]", chat: %{body: "/join #zion"})
    |> render_submit()

    _ = :sys.get_state(one.pid)

    online = element(one, "#online-users") |> render()
    assert online =~ "neo"
    refute online =~ "trinity"
  end

  test "blocked-message notices queue newest-first and cap how many render", %{conn: conn} do
    Application.put_env(:atrium, :moderation,
      jev_api_key: "test-key",
      rules: "no spam",
      plug: {Req.Test, AtriumWeb.ModerationStub}
    )

    on_exit(fn -> Application.delete_env(:atrium, :moderation) end)

    Req.Test.stub(AtriumWeb.ModerationStub, fn conn ->
      Req.Test.json(conn, %{
        "answers" => %{
          "breaks_rules" => %{"noul" => 1.0},
          "category" => %{"choice" => "spam"},
          "severity" => %{
            "score" => 2.0,
            "legend" => %{"0" => "mild", "1" => "moderate", "2" => "severe"}
          }
        }
      })
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=set_nick]", join: %{nick: "smith"})
    |> render_submit()

    for n <- 1..6 do
      view |> form("form[phx-submit=send]", chat: %{body: "spam #{n}"}) |> render_submit()
    end

    html = render(view)
    assert Regex.scan(~r/Message blocked/, html) |> length() == 4
    assert html =~ "+2 more waiting"
  end

  test "a mild rule violation is posted anyway with a warning notice", %{conn: conn} do
    Application.put_env(:atrium, :moderation,
      jev_api_key: "test-key",
      rules: "stay on topic",
      plug: {Req.Test, AtriumWeb.ModerationStub}
    )

    on_exit(fn -> Application.delete_env(:atrium, :moderation) end)

    Req.Test.stub(AtriumWeb.ModerationStub, fn conn ->
      Req.Test.json(conn, %{
        "answers" => %{
          "breaks_rules" => %{"noul" => 0.9},
          "category" => %{"choice" => "off_topic"},
          "severity" => %{
            "score" => 0.2,
            "legend" => %{"0" => "mild", "1" => "moderate", "2" => "severe"}
          }
        }
      })
    end)

    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=set_nick]", join: %{nick: "smith"})
    |> render_submit()

    view
    |> form("form[phx-submit=send]", chat: %{body: "totally off topic"})
    |> render_submit()

    html = render(view)
    assert html =~ "totally off topic"
    assert html =~ "Sent, but this message might break the channel rules (off_topic, mild)."
  end

  test "sending a message tells the browser to clear the composer", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    view
    |> form("form[phx-submit=set_nick]", join: %{nick: "neo"})
    |> render_submit()

    view
    |> form("form[phx-submit=send]", chat: %{body: "hello"})
    |> render_submit()

    assert_push_event(view, "clear-input", %{id: "chat-body"})
  end
end

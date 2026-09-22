defmodule Atrium.ChatTest do
  use Atrium.DataCase, async: false

  alias Atrium.Chat

  describe "channels" do
    test "get_or_create_channel normalizes the name and is idempotent" do
      {:ok, a} = Chat.get_or_create_channel("#General")
      {:ok, b} = Chat.get_or_create_channel("general")

      assert a.id == b.id
      assert a.name == "general"
    end

    test "get_or_create_channel rejects invalid names" do
      assert {:error, %Ecto.Changeset{}} = Chat.get_or_create_channel("has spaces!")
    end
  end

  describe "messages" do
    setup do
      {:ok, channel} = Chat.get_or_create_channel("general")
      %{channel: channel}
    end

    test "post_message stores and returns the line", %{channel: channel} do
      assert {:ok, message} = Chat.post_message(channel, "neo", "hello")
      assert message.body == "hello"
      assert message.kind == "said"
      assert [^message] = Chat.list_recent_messages(channel)
    end

    test "list_recent_messages returns oldest first and honours the limit", %{channel: channel} do
      for n <- 1..5, do: {:ok, _} = Chat.post_message(channel, "neo", "m#{n}")

      bodies = channel |> Chat.list_recent_messages(3) |> Enum.map(& &1.body)
      assert bodies == ["m3", "m4", "m5"]
    end

    test "post_message can reply to an earlier message in the same channel", %{channel: channel} do
      {:ok, original} = Chat.post_message(channel, "neo", "what is the matrix?")
      {:ok, reply} = Chat.post_message(channel, "morpheus", "let me show you", "said", original)

      assert reply.reply_to_id == original.id
      assert reply.reply_to.body == "what is the matrix?"
    end

    test "post_message drops a reply_to from a different channel", %{channel: channel} do
      {:ok, other} = Chat.get_or_create_channel("other")
      {:ok, foreign} = Chat.post_message(other, "neo", "wrong room")

      assert {:ok, reply} = Chat.post_message(channel, "morpheus", "huh?", "said", foreign)
      assert reply.reply_to_id == nil
    end

    test "concurrent writers all get their messages persisted", %{channel: channel} do
      parent = self()
      Ecto.Adapters.SQL.Sandbox.mode(Atrium.Repo, {:shared, parent})

      1..25
      |> Task.async_stream(
        fn n -> Chat.post_message(channel, "user#{rem(n, 5)}", "line #{n}") end,
        max_concurrency: 10,
        timeout: :infinity
      )
      |> Enum.each(fn {:ok, result} -> assert {:ok, _message} = result end)

      assert channel |> Chat.list_recent_messages(100) |> length() == 25
    end
  end
end

defmodule EngramWeb.McpController do
  @moduledoc """
  MCP (Model Context Protocol) server — JSON-RPC 2.0 over HTTP POST.
  Dispatches initialize, tools/list, and tools/call to the tool registry.
  """
  use EngramWeb, :controller

  alias Engram.MCP.Tools

  @server_info %{"name" => "engram", "version" => "0.1.0"}
  @capabilities %{"tools" => %{"listChanged" => false}}
  @protocol_version "2025-03-26"

  def handle(conn, %{"jsonrpc" => "2.0", "id" => id, "method" => method} = params) do
    result = dispatch(conn.assigns.current_user, method, params["params"] || %{})
    send_jsonrpc(conn, id, result)
  end

  # Notification (no id) — acknowledge
  def handle(conn, %{"jsonrpc" => "2.0", "method" => _method}) do
    send_resp(conn, 202, "")
  end

  def handle(conn, _params) do
    send_jsonrpc_error(conn, nil, -32600, "Invalid Request")
  end

  # -- Method dispatch --

  defp dispatch(_user, "initialize", _params) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "serverInfo" => @server_info,
       "capabilities" => @capabilities
     }}
  end

  defp dispatch(_user, "tools/list", _params) do
    tools =
      Enum.map(Tools.list(), fn t ->
        %{"name" => t.name, "description" => t.description, "inputSchema" => t.inputSchema}
      end)

    {:ok, %{"tools" => tools}}
  end

  defp dispatch(user, "tools/call", %{"name" => name, "arguments" => args}) do
    case Tools.get(name) do
      {:ok, tool} ->
        try do
          text = tool.handler.(user, args)
          {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}}
        catch
          kind, reason ->
            message =
              case kind do
                :error -> Exception.message(reason)
                :exit -> "Process exited: #{inspect(reason)}"
                :throw -> "Unexpected throw: #{inspect(reason)}"
              end

            {:ok,
             %{
               "content" => [%{"type" => "text", "text" => "Error: #{message}"}],
               "isError" => true
             }}
        end

      :error ->
        {:error, -32602, "Unknown tool: #{name}"}
    end
  end

  defp dispatch(_user, "tools/call", _params) do
    {:error, -32602, "Invalid params: name and arguments required"}
  end

  defp dispatch(_user, _method, _params) do
    {:error, -32601, "Method not found"}
  end

  # -- Response helpers --

  defp send_jsonrpc(conn, id, {:ok, result}) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp send_jsonrpc(conn, id, {:error, code, message}) do
    send_jsonrpc_error(conn, id, code, message)
  end

  defp send_jsonrpc_error(conn, id, code, message) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end
end

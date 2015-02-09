defmodule Tds.Protocol do
  require Logger

  import Tds.Utils
  import Tds.Messages

  alias Tds.Parameter

  def prelogin(%{sock: sock, opts: opts} = s) do

    msg = msg_prelogin(params: opts)
    case msg_send(msg, s) do
      :ok ->
        {:noreply,  %{s | state: :prelogin}}
      {:error, reason} ->
        {:stop, :normal, %Tds.Error{message: "tcp send: #{reason}"}, s}
    end
  end

  def login(%{sock: sock, opts: opts} = s) do
    msg = msg_login(params: opts)
    case msg_send(msg, s) do
      :ok ->
        #Logger.debug "Set State: Login"
        {:noreply,  %{s | state: :login}}
      {:error, reason} ->
        {:stop, :normal, %Tds.Error{message: "tcp send: #{reason}"}, s}
    end
  end

  def send_query(statement, s) do
    msg = msg_sql(query: statement)
    Logger.info statement
    case send_to_result(msg, s) do
      {:ok, s} ->
        #Logger.debug "Send Query"
        {:ok, %{s | statement: nil, state: :executing}}
      err ->
        err
    end
  end

  def send_param_query(statement, params, s) do
    
    Logger.info "#{IO.inspect(statement)}"
    IO.inspect params
    param_desc = params |> Enum.map(fn(%Parameter{} = param) -> 
      #Logger.debug "Parameter @#{param.name}, VALUE: #{IO.inspect(param.value)}"
      Tds.Types.encode_param_descriptor(param)
    end)
    param_desc = param_desc
      |> Enum.join(", ")

    msg = msg_rpc(proc: :sp_executesql, params: [%Parameter{value: statement}, %Parameter{value: param_desc}] ++ params)
    case send_to_result(msg, s) do
      {:ok, s} ->
        #Logger.debug "Send Query"
        {:ok, %{s | statement: nil, state: :executing}}
      err ->
        err
    end
  end

  def send_proc(proc, params, s) do
    msg = msg_rpc(proc: proc, params: params)
    case send_to_result(msg, s) do
      {:ok, s} ->
        #Logger.debug "Send Query"
        {:ok, %{s | statement: nil, state: :executing}}
      err ->
        err
    end
  end

  ## SERVER Packet Responses

  def message(:prelogin, _state) do

  end

  def message(:login, msg_login_ack(), %{opts: opts, tail: _tail, queue: queue, opts: opts} = s) do
    #Logger.debug "Protocol Message"
    opts = clean_opts(opts)
    queue = :queue.drop(queue)

    #TODO: Bootstrap Query
    #s = %{s | bootstrap: true, opts: opts}
    #Connection.new_query(Types.bootstrap_query, [], s)
    reply(:ok, s)
    {:ok, %{s | state: :ready, opts: opts, queue: queue}}
  end

  ## executing

  def message(:executing, msg_sql_result(columns: columns, rows: rows, done: done), %{queue: queue} = s) do
    if columns != nil do
      columns = Enum.reduce(columns, [], fn (col, acc) -> [col[:name]|acc] end) |> Enum.reverse
    end
    num_rows = done.rows;
    if rows != nil do
      rows = Enum.reverse rows
    end
    if num_rows == 0 && rows == nil do
      rows = []
    end
    result = %Tds.Result{columns: columns, rows: rows, num_rows: num_rows}
    reply(result, s)
    queue = :queue.drop(queue)
    {:ok, %{s | queue: queue, statement: "", state: :ready}}
  end

  def message(:executing, msg_trans(trans: trans), %{queue: queue} = s) do
    #Logger.info "Protocol Transaction: #{Tds.Utils.to_hex_string trans}"
    result = %Tds.Result{columns: [], rows: [], num_rows: 0}
    reply(result, s)
    queue = :queue.drop(queue)
    {:ok, %{s | queue: queue, statement: "", state: :ready, env: %{trans: trans}}}
  end

  # def message(:executing, msg_empty_query(), s) do
  #   reply(%Postgrex.Result{}, s)
  #   {:ok, s}
  # end

  # ## Async
  # def message(_, msg_ready(), %{queue: queue} = s) do
  #   queue = :queue.drop(queue)
  #   Connection.next(%{s | queue: queue, state: :ready})
  # end

  ## Error
  def message(_, msg_error(e: e), %{queue: queue} = s) do
    reply(%Tds.Error{mssql: e}, s)
    queue = :queue.drop(queue)
    {:ok, %{s | queue: queue, statement: "", state: :ready}}
  end

  defp msg_send(msg, %{sock: {mod, sock}, env: env}) do 
    data = encode_msg(msg, env)
    Logger.info "MSG: #{Tds.Utils.to_hex_string data}"
    mod.send(sock, data)
  end

  defp send_to_result(msg, s) do
    case msg_send(msg, s) do
      :ok ->
        {:ok, s}
      {:error, reason} ->
        {:error, %Tds.Error{message: "tcp send: #{reason}"} , s}
    end
  end

  defp clean_opts(opts) do
    Keyword.put(opts, :password, :REDACTED)
  end

end

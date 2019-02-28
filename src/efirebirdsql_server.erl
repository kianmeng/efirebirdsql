%%% The MIT License (MIT)

%%% Copyright (c) 2016-2019 Hajime Nakagami<nakagami@gmail.com>

-module(efirebirdsql_server).

-behavior(gen_server).

-export([start_link/0, get_parameter/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([init/1, code_change/3, terminate/2]).

-include("efirebirdsql.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% -- client interface --
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

get_parameter(C, Name) when is_list(Name) ->
    gen_server:call(C, {get_parameter, list_to_binary(Name)}, infinity);
get_parameter(C, Name) when is_list(Name) ->
    gen_server:call(C, {get_parameter, Name}, infinity).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% -- gen_server implementation --

init([]) ->
    {ok, #state{}}.

handle_call({connect, Host, Username, Password, Database, Options}, _From, State) ->
    case efirebirdsql_protocol:connect(Host, Username, Password, Database, Options) of
    {ok, Conn} ->
        {ok, C2, Stmt} = efirebirdsql_protocol:allocate_statement(Conn),
        {reply, ok, State#state{connection=C2,statement=Stmt}};
    {error, Reason, Conn} ->
        {reply, {error, Reason}, State#state{connection=Conn}}
    end;
handle_call({transaction, Options}, _From, State) ->
    Conn = State#state.connection,
    AutoCommit = proplists:get_value(auto_commit, Options, true),
    case efirebirdsql_protocol:begin_transaction(AutoCommit, Conn) of
    {ok, C2} -> {reply, ok, State#state{connection=C2}};
    {error, Reason, C2} -> {reply, Reason, State#state{connection=C2}}
    end;
handle_call(commit, _From, State) ->
    Conn = State#state.connection,
    case efirebirdsql_protocol:commit(Conn) of
    {ok, C2} -> {reply, ok, State#state{connection=C2}};
    {error, Reason, C2} -> {reply, Reason, State#state{connection=C2}}
    end;
handle_call(rollback, _From, State) ->
    Conn = State#state.connection,
    case efirebirdsql_protocol:rollback(Conn) of
    {ok, C2} -> {reply, ok, State#state{connection=C2}};
    {error, Reason, C2} -> {reply, Reason, State#state{connection=C2}}
    end;
handle_call(close, _From, State) ->
    Conn = State#state.connection,
    case efirebirdsql_protocol:close(Conn) of
    {ok, C2} -> {reply, ok, State#state{connection=C2}};
    {error, Reason, C2} -> {reply, Reason, State#state{connection=C2}}
    end;
handle_call({prepare, Sql}, _From, State) ->
    case efirebirdsql_protocol:prepare_statement(Sql,
        State#state.connection, State#state.statement) of
    {ok, C2, Stmt} -> {reply, ok, State#state{connection=C2, statement=Stmt}};
    {error, Reason, C2} -> {reply, Reason, State#state{connection=C2}}
    end;
handle_call({execute, Params}, _From, State) ->
    case efirebirdsql_protocol:execute(State#state.connection, State#state.statement, Params) of
    {ok, C2, Stmt} -> {reply, ok, State#state{connection=C2,statement=Stmt}};
    {error, Reason, C2} -> {reply, Reason, State#state{connection=C2}}
    end;
handle_call(fetchone, _From, State) ->
    case efirebirdsql_protocol:fetchone(State#state.connection, State#state.statement) of
    {ConvertedRow, C2, Stmt} ->
        {reply, {ok, ConvertedRow}, State#state{connection=C2, statement=Stmt}};
    nil ->
        {reply, {ok, nil}, State}
    end;
handle_call(fetchall, _From, State) ->
    {ok, Rows, C2, S2} = efirebirdsql_protocol:fetchall(
        State#state.connection, State#state.statement),
    {reply, {ok, Rows}, State#state{connection=C2, statement=S2}};
handle_call(description, _From, State) ->
    case State#state.statement#stmt.stmt_type of
    isc_info_sql_stmt_select
        -> {reply, efirebirdsql_protocol:description(State#state.statement), State};
    _
        -> {reply, no_result, State}
    end;
handle_call({get_parameter, Name}, _From, State) ->
    Value1 = case lists:keysearch(Name, 1, State#state.parameters) of
        {value, {Name, Value}} -> Value;
        false                  -> undefined
        end,
    {reply, {ok, Value1}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({inet_reply, _, ok}, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% The MIT License (MIT)
%%% Copyright (c) 2016-2018 Hajime Nakagami<nakagami@gmail.com>

-module(efirebirdsql_op).
%-include_lib("eunit/include/eunit.hrl").
-define(debugFmt(X,Y), ok).

-export([op_connect/6, op_attach/4, op_detach/1, op_create/5, op_transaction/2,
    op_allocate_statement/1, op_prepare_statement/3, op_free_statement/1, op_execute/3,
    op_execute2/4, op_fetch/2, op_info_sql/2, op_commit_retaining/1, op_rollback_retaining/1,
    convert_row/5, get_response/2, get_fetch_response/3, get_sql_response/3,
    get_prepare_statement_response/3]).

-include("efirebirdsql.hrl").

-define(CHARSET, "UTF8").
-define(BUFSIZE, 1024).
-define(INFO_SQL_SELECT_DESCRIBE_VARS, [
        4,      %% isc_info_sql_select
        7,      %% isc_info_sql_describe_vars
        9,      %% isc_info_sql_sqlda_seq
        11,     %% isc_info_sql_type
        12,     %% isc_info_sql_sub_type
        13,     %% isc_info_sql_scale
        14,     %% isc_info_sql_length
        15,     %% isc_info_sql_null_ind,
        16,     %% isc_info_sql_field,
        17,     %% isc_info_sql_relation,
        18,     %% isc_info_sql_owner,
        19,     %% isc_info_sql_alias,
        8       %% isc_info_sql_describe_end
        ]).

%%% skip 4 byte alignment socket stream
skip4(TcpMod, Sock, Len) ->
    case Len rem 4 of
        0 -> {ok};
        1 -> TcpMod:recv(Sock, 3);
        2 -> TcpMod:recv(Sock, 2);
        3 -> TcpMod:recv(Sock, 1)
    end.


pack_cnct_param(K, V) when is_list(V) ->
    lists:flatten([K, length(V), V]);
pack_cnct_param(K, V) when is_binary(V) ->
    pack_cnct_param(K, binary_to_list(V)).

%%% parameters separate per 254 bytes
pack_specific_data_cnct_param(Acc, _, []) ->
    lists:flatten(lists:reverse(Acc));
pack_specific_data_cnct_param(Acc, K, V) ->
    pack_specific_data_cnct_param(
        [pack_cnct_param(K, lists:sublist(V, 1, 254)) | Acc],
        K,
        if length(V) > 254 -> lists:nthtail(254, V); length(V) =< 254 -> [] end).

pack_specific_data_cnct_param(K, V) ->
    pack_specific_data_cnct_param([], K, V).

uid(Host, Username, PublicKey, WireCrypt) ->
    SpecificData = efirebirdsql_srp:to_hex(PublicKey),
    Data = lists:flatten([
        pack_cnct_param(9, Username),                   %% CNCT_login
        pack_cnct_param(8, "Srp"),                      %% CNCT_plugin_name
        pack_cnct_param(10, "Srp,Legacy_Atuh"),         %% CNCT_plugin_list
        pack_specific_data_cnct_param(7, SpecificData), %% CNCT_specific_data
        % TODO: support WireCrypt
        pack_cnct_param(11, [0, 0, 0, 0]),
        pack_cnct_param(11,
            [if WireCrypt=:=true -> 1; WireCrypt =/= true -> 0 end, 0, 0, 0]
        ),  %% CNCT_client_crypt
        pack_cnct_param(1, Username),                   %% CNCT_user
        pack_cnct_param(4, Host),                       %% CNCT_host
        pack_cnct_param(6, "")                          %% CNCT_user_verification
    ]),
    efirebirdsql_conv:list_to_xdr_bytes(Data).

convert_scale(Scale) ->
    if Scale < 0 -> 256 + Scale;
        Scale >= 0 -> Scale
    end.

calc_blr_item(XSqlVar) ->
    case XSqlVar#column.type of
        varying -> [37 | efirebirdsql_conv:byte2(XSqlVar#column.length)] ++ [7, 0];
        text -> [14 | efirebirdsql_conv:byte2(XSqlVar#column.length)] ++ [7, 0];
        long -> [8, convert_scale(XSqlVar#column.scale), 7, 0];
        short -> [7, convert_scale(XSqlVar#column.scale), 7, 0];
        int64 -> [16,  convert_scale(XSqlVar#column.scale), 7, 0];
        quad -> [9, convert_scale(XSqlVar#column.scale), 7, 0];
        double -> [27, 7, 0];
        float -> [10, 7, 0];
        d_float -> [11, 7, 0];
        date -> [12, 7, 0];
        time -> [13, 7, 0];
        timestamp -> [35, 7, 0];
        decimal_fixed -> [26, convert_scale(XSqlVar#column.scale), 7, 0];
        decimal64 -> [24, 7, 0];
        decimal128 -> [25, 7, 0];
        blob -> [9, 0, 7, 0];
        array -> [9, 0, 7, 0];
        boolean -> [23, 7, 0]
    end.

calc_blr_items([], Blr) ->
    Blr;
calc_blr_items(XSqlVars, Blr) ->
    [H | T] = XSqlVars,
    calc_blr_items(T, Blr ++ calc_blr_item(H)).

calc_blr(XSqlVars) ->
    L = length(XSqlVars) * 2,
    lists:flatten([[5, 2, 4, 0],
        efirebirdsql_conv:byte2(L),
        calc_blr_items(XSqlVars, []),
        [255, 76]]).

%%% create op_connect binary
op_connect(Host, Username, _Password, Database, PublicKey, WireCrypt) ->
    ?debugFmt("op_connect~n", []),
    %% PROTOCOL_VERSION,ArchType(Generic),MinAcceptType,MaxAcceptType,Weight
    %Protocols = [
    %    [  0,   0,   0, 10, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2],
    %    [255, 255, 128, 11, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 4],
    %    [255, 255, 128, 12, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 6],
    %    [255, 255, 128, 13, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 8]
    %],
    Protocols = [
        [  0,   0,   0, 10, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 2],
        [255, 255, 128, 11, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 4],
        [255, 255, 128, 12, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 6]
    ],
    Buf = [
        efirebirdsql_conv:byte4(op_val(op_connect)),
        efirebirdsql_conv:byte4(op_val(op_attach)),
        efirebirdsql_conv:byte4(3),  %% CONNECT_VERSION
        efirebirdsql_conv:byte4(1),  %% arch_generic,
        efirebirdsql_conv:list_to_xdr_string(Database),
        efirebirdsql_conv:byte4(length(Protocols)),
        uid(Host, Username, PublicKey, WireCrypt)],
    list_to_binary([Buf, lists:flatten(Protocols)]).

%%% create op_attach binary
op_attach(Username, Password, Database, AcceptVersion) ->
    ?debugFmt("op_attach~n", []),

    Dpb = case AcceptVersion of
        13 ->
            lists:flatten([
                1,                              %% isc_dpb_version = 1
                48, length(?CHARSET), ?CHARSET, %% isc_dpb_lc_ctype = 48
                28, length(Username), Username  %% isc_dpb_user_name 28
            ]);
        _ ->
            lists:flatten([
                1,                              %% isc_dpb_version = 1
                48, length(?CHARSET), ?CHARSET, %% isc_dpb_lc_ctype = 48
                28, length(Username), Username, %% isc_dpb_user_name 28
                29, length(Password), Password  %% isc_dpb_password = 29
            ])
        end,
    list_to_binary(lists:flatten([
        efirebirdsql_conv:byte4(op_val(op_attach)),
        efirebirdsql_conv:byte4(0),
        efirebirdsql_conv:list_to_xdr_string(Database),
        efirebirdsql_conv:list_to_xdr_bytes(Dpb)])).

op_detach(DbHandle) ->
    ?debugFmt("op_detatch~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_detach)),
        efirebirdsql_conv:byte4(DbHandle)]).

%%% create op_connect binary
op_create(Username, Password, Database, PageSize, AcceptVersion) ->
    ?debugFmt("op_create~n", []),
    Dpb = case AcceptVersion of
        13 ->
            lists:flatten([
                1,
                68, length(?CHARSET), ?CHARSET,   %% isc_dpb_set_db_charset = 68
                48, length(?CHARSET), ?CHARSET,   %% isc_dpb_lc_ctype = 48
                28, length(Username), Username, %% isc_dpb_user_name 28
                63, 4, efirebirdsql_conv:byte4(3, little),        %% isc_dpb_sql_dialect = 63
                24, 4, efirebirdsql_conv:byte4(1, little),        %% isc_dpb_force_write = 24
                54, 4, efirebirdsql_conv:byte4(1, little),        %% isc_dpb_overwrite = 54
                4, 4, efirebirdsql_conv:byte4(PageSize, little)   %% isc_dpb_page_size = 4
            ]);
        _ ->
            lists:flatten([
                1,
                68, length(?CHARSET), ?CHARSET,   %% isc_dpb_set_db_charset = 68
                48, length(?CHARSET), ?CHARSET,   %% isc_dpb_lc_ctype = 48
                28, length(Username), Username, %% isc_dpb_user_name 28
                29, length(Password), Password, %% isc_dpb_password = 29
                63, 4, efirebirdsql_conv:byte4(3, little),        %% isc_dpb_sql_dialect = 63
                24, 4, efirebirdsql_conv:byte4(1, little),        %% isc_dpb_force_write = 24
                54, 4, efirebirdsql_conv:byte4(1, little),        %% isc_dpb_overwrite = 54
                4, 4, efirebirdsql_conv:byte4(PageSize, little)   %% isc_dpb_page_size = 4
            ])
        end,
    list_to_binary(lists:flatten([
        efirebirdsql_conv:byte4(op_val(op_create)),
        efirebirdsql_conv:byte4(0),
        efirebirdsql_conv:list_to_xdr_string(Database),
        efirebirdsql_conv:list_to_xdr_bytes(Dpb)])).


%%% begin transaction
op_transaction(DbHandle, Tpb) ->
    ?debugFmt("op_transaction~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_transaction)),
        efirebirdsql_conv:byte4(DbHandle),
        efirebirdsql_conv:list_to_xdr_bytes(Tpb)]).

%%% allocate statement
op_allocate_statement(DbHandle) ->
    ?debugFmt("op_allocate_statement~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_allocate_statement)),
        efirebirdsql_conv:byte4(DbHandle)]).

%%% prepare statement
op_prepare_statement(TransHandle, StmtHandle, Sql) ->
    ?debugFmt("op_prepare_statement~n", []),
    DescItems = [21 | ?INFO_SQL_SELECT_DESCRIBE_VARS], %% isc_info_sql_stmt_type
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_prepare_statement)),
        efirebirdsql_conv:byte4(TransHandle),
        efirebirdsql_conv:byte4(StmtHandle),
        efirebirdsql_conv:byte4(3),
        efirebirdsql_conv:list_to_xdr_string(binary_to_list(Sql)),
        efirebirdsql_conv:list_to_xdr_bytes(DescItems),
        efirebirdsql_conv:byte4(?BUFSIZE)]).

%%% free statement
op_free_statement(StmtHandle) ->
    ?debugFmt("op_free_statement~n", []),
    %% DSQL_close = 1
    %% DSQL_drop = 2
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_free_statement)),
        efirebirdsql_conv:byte4(StmtHandle),
        efirebirdsql_conv:byte4(1)]).

op_execute(TransHandle, StmtHandle, Params) ->
    if length(Params) == 0 ->
            list_to_binary([
                efirebirdsql_conv:byte4(op_val(op_execute)),
                efirebirdsql_conv:byte4(StmtHandle),
                efirebirdsql_conv:byte4(TransHandle),
                efirebirdsql_conv:list_to_xdr_bytes([]),
                efirebirdsql_conv:byte4(0),
                efirebirdsql_conv:byte4(0)]);
        length(Params) > 0 ->
            {Blr, Value} = efirebirdsql_conv:params_to_blr(Params),
            list_to_binary([
                efirebirdsql_conv:byte4(op_val(op_execute)),
                efirebirdsql_conv:byte4(StmtHandle),
                efirebirdsql_conv:byte4(TransHandle),
                efirebirdsql_conv:list_to_xdr_bytes(Blr),
                efirebirdsql_conv:byte4(0),
                efirebirdsql_conv:byte4(1),
                Value])
    end.

op_execute2(TransHandle, StmtHandle, Params, XSqlVars) ->
    ?debugFmt("op_execute2~n", []),
    OutputBlr = efirebirdsql_conv:list_to_xdr_bytes(calc_blr(XSqlVars)),
    if length(Params) == 0 ->
            list_to_binary([
                efirebirdsql_conv:byte4(op_val(op_execute2)),
                efirebirdsql_conv:byte4(StmtHandle),
                efirebirdsql_conv:byte4(TransHandle),
                efirebirdsql_conv:list_to_xdr_bytes([]),
                efirebirdsql_conv:byte4(0),
                efirebirdsql_conv:byte4(0),
                OutputBlr,
                efirebirdsql_conv:byte4(0)]);
        length(Params) > 0 ->
            {Blr, Value} = efirebirdsql_conv:params_to_blr(Params),
            list_to_binary([
                efirebirdsql_conv:byte4(op_val(op_execute2)),
                efirebirdsql_conv:byte4(StmtHandle),
                efirebirdsql_conv:byte4(TransHandle),
                efirebirdsql_conv:list_to_xdr_bytes(Blr),
                efirebirdsql_conv:byte4(0),
                efirebirdsql_conv:byte4(1),
                Value,
                OutputBlr,
                efirebirdsql_conv:byte4(0)])
    end.

op_info_sql(StmtHandle, V) ->
    ?debugFmt("op_info_sql~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_info_sql)),
        efirebirdsql_conv:byte4(StmtHandle),
        efirebirdsql_conv:byte4(0),
        efirebirdsql_conv:list_to_xdr_bytes(V),
        efirebirdsql_conv:byte4(?BUFSIZE)]).

op_fetch(StmtHandle, XSqlVars) ->
    ?debugFmt("op_fetch~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_fetch)),
        efirebirdsql_conv:byte4(StmtHandle),
        efirebirdsql_conv:list_to_xdr_bytes(calc_blr(XSqlVars)),
        efirebirdsql_conv:byte4(0),
        efirebirdsql_conv:byte4(400)]).

%%% commit
op_commit_retaining(TransHandle) ->
    ?debugFmt("op_commit_retaining~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_commit_retaining)),
        efirebirdsql_conv:byte4(TransHandle)]).

%%% rollback
op_rollback_retaining(TransHandle) ->
    ?debugFmt("op_rollback_retaining~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_rollback_retaining)),
        efirebirdsql_conv:byte4(TransHandle)]).


%%% blob
op_open_blob(BlobId, TransHandle) ->
    ?debugFmt("op_open_blob~n", []),
    H = list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_open_blob)),
        efirebirdsql_conv:byte4(TransHandle)]),
    <<H/binary, BlobId/binary>>.

op_get_segment(BlobHandle) ->
    ?debugFmt("op_get_segment~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_get_segment)),
        efirebirdsql_conv:byte4(BlobHandle),
        efirebirdsql_conv:byte4(?BUFSIZE),
        efirebirdsql_conv:byte4(0)]).

op_close_blob(BlobHandle) ->
    ?debugFmt("op_close_blob~n", []),
    list_to_binary([
        efirebirdsql_conv:byte4(op_val(op_close_blob)),
        efirebirdsql_conv:byte4(BlobHandle)]).

%%% parse status vector
parse_status_vector_integer(TcpMod, Sock) ->
    {ok, <<NumArg:32>>} = TcpMod:recv(Sock, 4),
    NumArg.

parse_status_vector_string(TcpMod, Sock) ->
    Len = parse_status_vector_integer(TcpMod, Sock),
    {ok, Bin} = TcpMod:recv(Sock, Len),
    skip4(TcpMod, Sock, Len),
    binary_to_list(Bin).

parse_status_vector_args(TcpMod, Sock, Template, Args) ->
    {ok, <<IscArg:32>>} = TcpMod:recv(Sock, 4),
    case IscArg of
    0 ->    %% isc_arg_end
        {Template, Args};
    1 ->    %% isc_arg_gds
        V = efirebirdsql_errmsgs:get_error_msg(parse_status_vector_integer(TcpMod, Sock)),
        parse_status_vector_args(TcpMod, Sock, [V | Template], Args);
    2 ->    %% isc_arg_string
        V = parse_status_vector_string(TcpMod, Sock),
        parse_status_vector_args(TcpMod, Sock, Template, [V | Args]);
    4 ->    %% isc_arg_number
        V = parse_status_vector_integer(TcpMod, Sock),
        parse_status_vector_args(TcpMod, Sock, Template, [integer_to_list(V) | Args]);
    5 ->    %% isc_arg_interpreted
        V = parse_status_vector_string(TcpMod, Sock),
        parse_status_vector_args(TcpMod, Sock, [V | Template], Args);
    19 ->   %% isc_arg_sql_state
        _V = parse_status_vector_string(TcpMod, Sock),
        parse_status_vector_args(TcpMod, Sock, Template, Args)
    end.

get_error_message(TcpMod, Sock) ->
    {S, A} = parse_status_vector_args(TcpMod, Sock, [], []),
    iolist_to_binary(io_lib:format(lists:flatten(lists:reverse(S)), lists:reverse(A))).

%% recieve and parse response
get_response(TcpMod, Sock) ->
    ?debugFmt("get_response()~n", []),
    {ok, <<OpCode:32>>} = TcpMod:recv(Sock, 4),
    Op = op_name(OpCode),
    if Op == op_response ->
            {ok, <<Handle:32, _ObjectID:64, Len:32>>} = TcpMod:recv(Sock, 16),
            Buf = if
                Len =/= 0 ->
                    {ok, RecvBuf} = TcpMod:recv(Sock, Len),
                    skip4(TcpMod, Sock, Len),
                    RecvBuf;
                true -> <<>>
            end,
            case S = get_error_message(TcpMod, Sock) of
                <<>> -> {Op, {ok, Handle, Buf}};
                _ -> {Op, {error, S}}
            end;
        Op == op_fetch_response ->
            {ok, <<Status:32, Count:32>>} = TcpMod:recv(Sock, 8),
            {Op, {Status, Count}};
        Op == op_sql_response ->
            {ok, <<Count:32>>} = TcpMod:recv(Sock, 4),
            {Op, Count};
        (Op == op_accept) or (Op == op_cond_accept) or (Op == op_accept_data) ->
            {ok, <<_AcceptVersionMasks:24, AcceptVersion:8,
                    _AcceptArchtecture:32, _AcceptType:32>>} = TcpMod:recv(Sock, 12),
            AcceptType = case _AcceptType of
                3 -> ptype_batch_send;
                4 -> ptype_out_of_band;
                5 -> ptype_lazy_send
            end,
            {Op, {AcceptVersion, AcceptType}};
        Op == op_reject ->
            {Op, {}};
        Op == op_dummy ->
            get_response(TcpMod, Sock);
        true ->
            {error, "response error"}
    end.

%% parse select items.
more_select_describe_vars(TcpMod, Sock, StmtHandle, Start) ->
    %% isc_info_sql_sqlda_start + INFO_SQL_SELECT_DESCRIBE_VARS
    V = lists:flatten(
        [20, 2, Start rem 256, Start div 256, ?INFO_SQL_SELECT_DESCRIBE_VARS]),
    TcpMod:send(Sock, op_info_sql(StmtHandle, V)),
    {op_response, {ok, _, Buf}} = get_response(TcpMod, Sock),
    <<_:8/binary, DescVars/binary>> = Buf,
    DescVars.

parse_select_item_elem_binary(DescVars) ->
    <<L:16/little, V:L/binary, Rest/binary>> = DescVars,
    {V, Rest}.

parse_select_item_elem_int(DescVars) ->
    {V, Rest} = parse_select_item_elem_binary(DescVars),
    L = size(V) * 8,
    <<Num:L/signed-little>> = V,
    {Num, Rest}.

parse_select_column(TcpMod, Sock, StmtHandle, Column, DescVars) ->
    %% Parse DescVars and return items info and rest DescVars
    <<IscInfoNum:8, Rest/binary>> = DescVars,
    case isc_info_sql_name(IscInfoNum) of
        isc_info_sql_sqlda_seq ->
            {Num, Rest2} = parse_select_item_elem_int(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column#column{seq=Num}, Rest2);
        isc_info_sql_type ->
            {Num, Rest2} = parse_select_item_elem_int(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column#column{type=sql_type(Num)}, Rest2);
        isc_info_sql_sub_type ->
            {_Num, Rest2} = parse_select_item_elem_int(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column, Rest2);
        isc_info_sql_scale ->
            {Num, Rest2} = parse_select_item_elem_int(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column#column{scale=Num}, Rest2);
        isc_info_sql_length ->
            {Num, Rest2} = parse_select_item_elem_int(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column#column{length=Num}, Rest2);
        isc_info_sql_null_ind ->
            {Num, Rest2} = parse_select_item_elem_int(Rest),
            NullInd = if Num =/= 0 -> true; Num =:= 0 -> false end,
            parse_select_column(TcpMod, Sock, StmtHandle, Column#column{null_ind=NullInd}, Rest2);
        isc_info_sql_field ->
            {_S, Rest2} = parse_select_item_elem_binary(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column, Rest2);
        isc_info_sql_relation ->
            {_S, Rest2} = parse_select_item_elem_binary(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column, Rest2);
        isc_info_sql_owner ->
            {_S, Rest2} = parse_select_item_elem_binary(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column, Rest2);
        isc_info_sql_alias ->
            {S, Rest2} = parse_select_item_elem_binary(Rest),
            parse_select_column(TcpMod, Sock, StmtHandle, Column#column{name=S}, Rest2);
        isc_info_truncated ->
            Rest2 = more_select_describe_vars(TcpMod, Sock, StmtHandle, Column#column.seq),
            parse_select_column(TcpMod, Sock, StmtHandle, Column, Rest2);
        isc_info_sql_describe_end ->
            {Column, Rest};
        isc_info_end ->
            no_more_column
    end.

parse_select_columns(TcpMod, Sock, StmtHandle, XSqlVars, DescVars) ->
    case parse_select_column(TcpMod, Sock, StmtHandle, #column{}, DescVars) of
        {XSqlVar, Rest} -> parse_select_columns(
            TcpMod, Sock, StmtHandle, [XSqlVar | XSqlVars], Rest);
        no_more_column -> lists:reverse(XSqlVars)
    end.

get_prepare_statement_response(TcpMod, Sock, StmtHandle) ->
    {op_response, R} = get_response(TcpMod, Sock),
    case R of
        {ok, _, Buf} ->
            << _21:8, _Len:16, StmtType:32/little, Rest/binary>> = Buf,
            XSqlVars = case StmtName = isc_info_sql_stmt_name(StmtType) of
                isc_info_sql_stmt_select ->
                    << _Skip:8/binary, DescVars/binary >> = Rest,
                    parse_select_columns(TcpMod, Sock, StmtHandle, [], DescVars);
                isc_info_sql_stmt_exec_procedure ->
                    << _Skip:8/binary, DescVars/binary >> = Rest,
                    parse_select_columns(TcpMod, Sock, StmtHandle, [], DescVars);
                _ -> []
            end,
            {ok, StmtName, XSqlVars};
        {error, _} -> R
    end.

get_blob_segment_list(<<>>, SegmentList) ->
    lists:reverse(SegmentList);
get_blob_segment_list(Buf, SegmentList) ->
    <<L:16/little, V:L/binary, Rest/binary>> = Buf,
    get_blob_segment_list(Rest, [V| SegmentList]).

get_blob_segment(TcpMod, Sock, BlobHandle, SegmentList) ->
    TcpMod:send(Sock, op_get_segment(BlobHandle)),
    {op_response,  {ok, F, Buf}} = get_response(TcpMod, Sock),
    NewList = lists:flatten([SegmentList, get_blob_segment_list(Buf, [])]),
    case F of
        2 -> NewList;
        _ -> get_blob_segment(TcpMod, Sock, BlobHandle, NewList)
    end.

get_blob_data(TcpMod, Sock, TransHandle, BlobId) ->
    TcpMod:send(Sock, op_open_blob(BlobId, TransHandle)),
    {op_response,  {ok, BlobHandle, _}} = get_response(TcpMod, Sock),
    SegmentList = get_blob_segment(TcpMod, Sock, BlobHandle, []),
    TcpMod:send(Sock, op_close_blob(BlobHandle)),
    {op_response,  {ok, 0, _}} = get_response(TcpMod, Sock),
    R = list_to_binary(SegmentList),
    {ok, R}.

convert_raw_value(_Mod, _Sock, _TransHandle, _XSqlVar, null) ->
    null;
convert_raw_value(TcpMod, Sock, TransHandle, XSqlVar, RawValue) ->
    ?debugFmt("convert_raw_value() start~n", []),
    CookedValue = case XSqlVar#column.type of
            long -> efirebirdsql_conv:parse_number(
                RawValue, XSqlVar#column.scale);
            short -> efirebirdsql_conv:parse_number(
                RawValue, XSqlVar#column.scale);
            int64 -> efirebirdsql_conv:parse_number(
                RawValue, XSqlVar#column.scale);
            quad -> efirebirdsql_conv:parse_number(
                RawValue, XSqlVar#column.scale);
            double -> L = size(RawValue) * 8, <<V:L/float>> = RawValue, V;
            float -> L = size(RawValue) * 8, <<V:L/float>> = RawValue, V;
            date -> efirebirdsql_conv:parse_date(RawValue);
            time -> efirebirdsql_conv:parse_time(RawValue);
            timestamp -> efirebirdsql_conv:parse_timestamp(RawValue);
            decimal_fixed -> efirebirdsql_decfloat:decimal_fixed_to_decimal(
                RawValue, XSqlVar#column.scale);
            decimal64 -> efirebirdsql_decfloat:decimal64_to_decimal(RawValue);
            decimal128 -> efirebirdsql_decfloat:decimal128_to_decimal(RawValue);
            blob ->
                {ok, B} = get_blob_data(TcpMod, Sock, TransHandle, RawValue),
                B;
            boolean -> if RawValue =/= <<0,0,0,0>> -> true; true -> false end;
            _ -> RawValue
        end,
    ?debugFmt("convert_raw_value() end ~p~n", [CookedValue]),
    CookedValue.

convert_row(_Mod, _Sock, _TransHandle, [], [], Converted) ->
    ?debugFmt("convert_row()~n", []),
    lists:reverse(Converted);
convert_row(TcpMod, Sock, TransHandle, XSqlVars, Row, Converted) ->
    [X | XRest] = XSqlVars,
    [R | RRest] = Row,
    convert_row(TcpMod, Sock, TransHandle, XRest, RRest,
        [{X#column.name, convert_raw_value(TcpMod, Sock, TransHandle, X, R)} | Converted]).

convert_row(TcpMod, Sock, TransHandle, XSqlVars, Row) ->
    convert_row(TcpMod, Sock, TransHandle, XSqlVars, Row, []).

get_raw_value(TcpMod, Sock, XSqlVar) ->
    ?debugFmt("get_raw_value() start~n", []),
    L = case XSqlVar#column.type of
            varying -> {ok, <<Num:32>>} = TcpMod:recv(Sock, 4), Num;
            text -> XSqlVar#column.length;
            long -> 4;
            short -> 4;
            int64 -> 8;
            quad -> 8;
            double -> 8;
            float -> 4;
            date -> 4;
            time -> 4;
            timestamp -> 8;
            decimal_fixed -> 16;
            decimal64 -> 8;
            decimal128 ->  16;
            blob -> 8;
            array -> 8;
            boolean -> 1
        end,
    if L =:= 0 -> V = ""; L > 0 -> {ok, V} = TcpMod:recv(Sock, L) end,
    ?debugFmt("get_raw_value() V=~p~n", [V]),
    skip4(TcpMod, Sock, L),
    {ok, NullFlag} = TcpMod:recv(Sock, 4),
    ?debugFmt("get_raw_value() NullFlag=~p~n", [NullFlag]),
    case NullFlag of
        <<0,0,0,0>> -> V;
        _ -> null
    end.

get_row(_Mod, _Sock, [], Columns) ->
    lists:reverse(Columns);
get_row(TcpMod, Sock, XSqlVars, Columns) ->
    [X | RestVars] = XSqlVars,
    V = get_raw_value(TcpMod, Sock, X),
    get_row(TcpMod, Sock, RestVars, [V | Columns]).

get_fetch_response(_Mod, _Sock, Status, 0, _XSqlVars, Results) ->
    %% {list_of_response, more_data}
    {lists:reverse(Results),
        if Status =/= 100 -> true; Status =:= 100 -> false end};
get_fetch_response(TcpMod, Sock, _Status, _Count, XSqlVars, Results) ->
    Row = get_row(TcpMod, Sock, XSqlVars, []),
    NewResults = [Row | Results],
    {ok, <<_:32, NewStatus:32, NewCount:32>>} = TcpMod:recv(Sock, 12),
    get_fetch_response(TcpMod, Sock, NewStatus, NewCount, XSqlVars, NewResults).

get_fetch_response(TcpMod, Sock, XSqlVars) ->
    case get_response(TcpMod, Sock) of
        {op_response, R} ->
            {op_response, R};
        {op_fetch_response, {Status, Count}} ->
            {op_fetch_response, get_fetch_response(TcpMod, Sock, Status, Count, XSqlVars, [])}
    end.

get_sql_response(TcpMod, Sock, XSqlVars) ->
    {op_sql_response, _Count} = get_response(TcpMod, Sock),
    get_row(TcpMod, Sock, XSqlVars, []).

op_name(1) -> op_connect;
op_name(2) -> op_exit;
op_name(3) -> op_accept;
op_name(4) -> op_reject;
op_name(5) -> op_protocol;
op_name(6) -> op_disconnect;
op_name(9) -> op_response;
op_name(19) -> op_attach;
op_name(20) -> op_create;
op_name(21) -> op_detach;
op_name(29) -> op_transaction;
op_name(30) -> op_commit;
op_name(31) -> op_rollback;
op_name(35) -> op_open_blob;
op_name(36) -> op_get_segment;
op_name(37) -> op_put_segment;
op_name(39) -> op_close_blob;
op_name(40) -> op_info_database;
op_name(42) -> op_info_transaction;
op_name(44) -> op_batch_segments;
op_name(48) -> op_que_events;
op_name(49) -> op_cancel_events;
op_name(50) -> op_commit_retaining;
op_name(52) -> op_event;
op_name(53) -> op_connect_request;
op_name(57) -> op_create_blob2;
op_name(62) -> op_allocate_statement;
op_name(63) -> op_execute;
op_name(64) -> op_exec_immediate;
op_name(65) -> op_fetch;
op_name(66) -> op_fetch_response;
op_name(67) -> op_free_statement;
op_name(68) -> op_prepare_statement;
op_name(70) -> op_info_sql;
op_name(71) -> op_dummy;
op_name(76) -> op_execute2;
op_name(78) -> op_sql_response;
op_name(81) -> op_drop_database;
op_name(82) -> op_service_attach;
op_name(83) -> op_service_detach;
op_name(84) -> op_service_info;
op_name(85) -> op_service_start;
op_name(86) -> op_rollback_retaining;
%% FB3
op_name(87) -> op_update_account_info;
op_name(88) -> op_authenticate_user;
op_name(89) -> op_partial;
op_name(90) -> op_trusted_auth;
op_name(91) -> op_cancel;
op_name(92) -> op_cont_auth;
op_name(93) -> op_ping;
op_name(94) -> op_accept_data;
op_name(95) -> op_abort_aux_connection;
op_name(96) -> op_crypt;
op_name(97) -> op_crypt_key_callback;
op_name(98) -> op_cond_accept.

op_val(op_connect) -> 1;
op_val(op_exit) -> 2;
op_val(op_accept) -> 3;
op_val(op_reject) -> 4;
op_val(op_protocol) -> 5;
op_val(op_disconnect) -> 6;
op_val(op_response) -> 9;
op_val(op_attach) -> 19;
op_val(op_create) -> 20;
op_val(op_detach) -> 21;
op_val(op_transaction) -> 29;
op_val(op_commit) -> 30;
op_val(op_rollback) -> 31;
op_val(op_open_blob) -> 35;
op_val(op_get_segment) -> 36;
op_val(op_put_segment) -> 37;
op_val(op_close_blob) -> 39;
op_val(op_info_database) -> 40;
op_val(op_info_transaction) -> 42;
op_val(op_batch_segments) -> 44;
op_val(op_que_events) -> 48;
op_val(op_cancel_events) -> 49;
op_val(op_commit_retaining) -> 50;
op_val(op_event) -> 52;
op_val(op_connect_request) -> 53;
op_val(op_create_blob2) -> 57;
op_val(op_allocate_statement) -> 62;
op_val(op_execute) -> 63;
op_val(op_exec_immediate) -> 64;
op_val(op_fetch) -> 65;
op_val(op_fetch_response) -> 66;
op_val(op_free_statement) -> 67;
op_val(op_prepare_statement) -> 68;
op_val(op_info_sql) -> 70;
op_val(op_dummy) -> 71;
op_val(op_execute2) -> 76;
op_val(op_sql_response) -> 78;
op_val(op_drop_database) -> 81;
op_val(op_service_attach) -> 82;
op_val(op_service_detach) -> 83;
op_val(op_service_info) -> 84;
op_val(op_service_start) -> 85;
op_val(op_rollback_retaining) -> 86;
%% FB3
op_val(op_update_account_info) -> 87;
op_val(op_authenticate_user) -> 88;
op_val(op_partial) -> 89;
op_val(op_trusted_auth) -> 90;
op_val(op_cancel) -> 91;
op_val(op_cont_auth) -> 92;
op_val(op_ping) -> 93;
op_val(op_accept_data) -> 94;
op_val(op_abort_aux_connection) -> 95;
op_val(op_crypt) -> 96;
op_val(op_crypt_key_callback) -> 97;
op_val(op_cond_accept) -> 98.

sql_type(X) when X rem 2 == 1 -> sql_type(X band 16#FFFE);
sql_type(452) -> text;
sql_type(448) -> varying;
sql_type(500) -> short;
sql_type(496) -> long;
sql_type(482) -> float;
sql_type(480) -> double;
sql_type(530) -> d_float;
sql_type(510) -> timestamp;
sql_type(520) -> blob;
sql_type(540) -> array;
sql_type(550) -> quad;
sql_type(560) -> time;
sql_type(570) -> date;
sql_type(580) -> int64;
sql_type(32758) -> decimal_fixed;
sql_type(32760) -> decimal64;
sql_type(32762) -> decimal128;
sql_type(32764) -> boolean;
sql_type(32766) -> null.

isc_info_sql_name(Num) ->
    lists:nth(Num, [
    isc_info_end, isc_info_truncated, isc_info_error, isc_info_sql_select,
    isc_info_sql_bind, isc_info_sql_num_variables, isc_info_sql_describe_vars,
    isc_info_sql_describe_end, isc_info_sql_sqlda_seq, isc_info_sql_message_seq,
    isc_info_sql_type, isc_info_sql_sub_type, isc_info_sql_scale,
    isc_info_sql_length, isc_info_sql_null_ind, isc_info_sql_field,
    isc_info_sql_relation, isc_info_sql_owner, isc_info_sql_alias,
    isc_info_sql_sqlda_start, isc_info_sql_stmt_type, isc_info_sql_get_plan,
    isc_info_sql_records, isc_info_sql_batch_fetch,
    isc_info_sql_relation_alias]).

isc_info_sql_stmt_name(Num) ->
    lists:nth(Num, [
    isc_info_sql_stmt_select, isc_info_sql_stmt_insert,
    isc_info_sql_stmt_update, isc_info_sql_stmt_delete, isc_info_sql_stmt_ddl,
    isc_info_sql_stmt_get_segment, isc_info_sql_stmt_put_segment,
    isc_info_sql_stmt_exec_procedure, isc_info_sql_stmt_start_trans,
    isc_info_sql_stmt_commit, isc_info_sql_stmt_rollback,
    isc_info_sql_stmt_select_for_upd, isc_info_sql_stmt_set_generator,
    isc_info_sql_stmt_savepoint]).


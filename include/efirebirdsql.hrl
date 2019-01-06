%%% The MIT License (MIT)
%%% Copyright (c) 2016 Hajime Nakagami<nakagami@gmail.com>

-record(column, {
    name :: binary(),
    seq :: pos_integer(),
    type :: atom(),
    scale :: -1 | pos_integer(),
    length :: -1 | pos_integer(),
    null_ind :: true | false
}).

-record(state, {sock,
                user,
                password,
                client_private,
                client_public,
                auth_data,
                auth_plugin,
                wire_crypt,
                db_handle,
                trans_handle,
                stmt_handle,
                parameters = [],
                stmt_type,
                xsqlvars = [],
                rows = [],
                accept_version
                }).


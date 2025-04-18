-module(emqx_persistence_pgsql_cli).

-behaviour(ecpool_worker).

-include_lib("emqx/include/emqx.hrl").

-include_lib("emqx/include/logger.hrl").
-include("emqx_persistence_pgsql.hrl").

-export([connect/1]).
-export([parse_query/2]).
-export([ equery/4
        , equery/3
        , insert/3
        , insert/2
        ]).

-type client_info() :: #{username := _,
                         clientid := _,
                         peerhost := _,
                         _ => _}.

%%--------------------------------------------------------------------
%% Avoid SQL Injection: Parse SQL to Parameter Query.
%%--------------------------------------------------------------------

parse_query(_Par, undefined) ->
    undefined;
parse_query(Par, Sql) ->
    case re:run(Sql, "'%[ucCad]'", [global, {capture, all, list}]) of
        {match, Variables} ->
            Params = [Var || [Var] <- Variables],
            {atom_to_list(Par), Params};
        nomatch ->
            {atom_to_list(Par), []}
    end.

%%--------------------------------------------------------------------
%% PostgreSQL Connect/Query
%%--------------------------------------------------------------------

%% Due to a bug in epgsql the caluse for `econnrefused` is not recognised by
%% dialyzer, result in this error:
%% The pattern {'error', Reason = 'econnrefused'} can never match the type ...
%% https://github.com/epgsql/epgsql/issues/246
-dialyzer([{nowarn_function, [connect/1]}]).
connect(Opts) ->
    Host     = proplists:get_value(host, Opts),
    Username = proplists:get_value(username, Opts),
    Password = proplists:get_value(password, Opts),
    case epgsql:connect(Host, Username, Password, conn_opts(Opts)) of
        {ok, C} ->
            ?LOG(info, "[Postgres] Connect to Postgres server[~p] success.", [Host]),
            {ok, C};
        {error, Reason = econnrefused} ->
            ?LOG(error, "[Postgres] Can't connect to Postgres server: Connection refused."),
            {error, Reason};
        {error, Reason = invalid_authorization_specification} ->
            ?LOG(error, "[Postgres] Can't connect to Postgres server: Invalid authorization specification."),
            {error, Reason};
        {error, Reason = invalid_password} ->
            ?LOG(error, "[Postgres] Can't connect to Postgres server: Invalid password."),
            {error, Reason};
        {error, Reason} ->
            ?LOG(error, "[Postgres] Can't connect to Postgres server: ~p", [Reason]),
            {error, Reason}
    end.


conn_opts(Opts) ->
    conn_opts(Opts, []).
conn_opts([], Acc) ->
    Acc;
conn_opts([Opt = {database1, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([Opt = {ssl, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([Opt = {port, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([Opt = {timeout, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([Opt = {ssl_opts, _}|Opts], Acc) ->
    conn_opts(Opts, [Opt|Acc]);
conn_opts([_Opt|Opts], Acc) ->
    conn_opts(Opts, Acc).

-spec(equery(atom(), string() | epgsql:statement(), Parameters::[any()]) -> {ok, ColumnsDescription :: [any()], RowsValues :: [any()]} | {error, any()} ).
equery(Pool, Sql, Params) ->
    ecpool:with_client(Pool, fun(C) -> epgsql:equery(C, Sql, Params) end).

-spec(equery(atom(), string() | epgsql:statement(), Parameters::[any()], client_info()) ->  {ok, ColumnsDescription :: [any()], RowsValues :: [any()]} | {error, any()} ).
equery(Pool, Sql, Params, ClientInfo) ->
    ecpool:with_client(Pool, fun(C) -> epgsql:equery(C, Sql, replvar(Params, ClientInfo)) end).

replvar(Params, ClientInfo) ->
    replvar(Params, ClientInfo, []).

replvar([], _ClientInfo, Acc) ->
    lists:reverse(Acc);

replvar(["'%u'" | Params], ClientInfo = #{username := Username}, Acc) ->
    replvar(Params, ClientInfo, [Username | Acc]);
replvar(["'%c'" | Params], ClientInfo = #{clientid := ClientId}, Acc) ->
    replvar(Params, ClientInfo, [ClientId | Acc]);
replvar(["'%a'" | Params], ClientInfo = #{peerhost := IpAddr}, Acc) ->
    replvar(Params, ClientInfo, [inet_parse:ntoa(IpAddr) | Acc]);
replvar(["'%C'" | Params], ClientInfo, Acc) ->
    replvar(Params, ClientInfo, [safe_get(cn, ClientInfo)| Acc]);
replvar(["'%d'" | Params], ClientInfo, Acc) ->
    replvar(Params, ClientInfo, [safe_get(dn, ClientInfo)| Acc]);
replvar([Param | Params], ClientInfo, Acc) ->
    replvar(Params, ClientInfo, [Param | Acc]).

safe_get(K, ClientInfo) ->
    bin(maps:get(K, ClientInfo, undefined)).

bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B;
bin(X) -> X.

insert(Sql, Params, ConnInfo) ->
    case equery(?APP, Sql, Params, ConnInfo) of
        {ok, _, []} ->
            ?LOG(info, "[PostgreSQL] execute the sql[~p~n] success", Sql),
            ok;
        {ok, _, Rows} ->
            ?LOG(warning, "[PostgreSQL] the insert sql conflict,the Rows:~p~n", [Rows]),
            ok;
        {error, Reason} ->
            ?LOG(error, "[PostgreSQL] insert error: ~p~n", [Reason]),
            ok;
        Other -> 
            Other,
            ?LOG(error, "[PostgreSQL] Unknown error")
    end.
insert(Sql, Params) ->
    case equery(?APP, Sql, Params) of
        {ok, _, []} ->
            ?LOG(info, "[PostgreSQL] execute the sql[~p~n] success", Sql),
            ok;
        {ok, _, Rows} ->
            ?LOG(warning, "[PostgreSQL] the insert sql conflict,the Rows:~p~n", [Rows]),
            ok;
        {error, Reason} ->
            ?LOG(error, "[PostgreSQL] insert error: ~p~n", [Reason]),
            ok;
        Other -> 
            Other,
            ?LOG(error, "[PostgreSQL] Unknown error")
    end.

%%%-------------------------------------------------------------------
%% @doc emqx_persistence_pgsql top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(emqx_persistence_pgsql_sup).

-include("emqx_persistence_pgsql.hrl").

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).


start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% PgSQL Connection Pool
    {ok, Opts} = application:get_env(?APP, server),
    PoolSpec = ecpool:pool_spec(?APP, ?APP, emqx_persistence_pgsql_cli, Opts),
    {ok, {{one_for_one, 10, 100}, [PoolSpec]}}.